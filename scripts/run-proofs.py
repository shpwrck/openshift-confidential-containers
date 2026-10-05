#!/usr/bin/env python3
"""Run isolated CoCo allow/deny/recovery experiments; never reuse a previous proof."""
from __future__ import annotations
import argparse
import base64
import copy
from datetime import datetime, timezone
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from proof_core import (Cluster, Incomplete, ProofFailure, ResourceEdit, application_started,
                        atomic_json, bind_initdata_policy, denial_matches, digest,
                        resource_released, restart_trustee, state_directory, application_ready, ProofLock)

REPO = Path(__file__).resolve().parent.parent
CASES = {
    "rung-kbs": "Secret release; non-confidential pod lacks the guest data hub",
    "rung-initdata": "Measured initdata binding, retaining the installed CPU policy",
    "rung-rvps": "Guest launch reference enforcement through RVPS",
    "rung-signed": "Signed-image acceptance and unsigned/wrong-key rejection",
    "air-gap": "Offline SNP endorsement enforcement (egress is a separate preflight)",
    "rung-encrypted": "Experimental encrypted-image execution and policy key withholding",
}
DEFAULT_CASES = ["rung-kbs", "rung-initdata", "rung-rvps", "rung-signed", "air-gap"]


def now():
    return datetime.now(timezone.utc).isoformat()


class Runner:
    def __init__(self, env, state):
        self.env, self.state = env, state
        self.worker = Cluster(env.get("WORKER_CONTEXT", ""))
        context = env.get("TRUSTEE_CONTEXT") or (env.get("WORKER_CONTEXT") if env.get("TRUSTEE_LAB") == "1" else "")
        self.trustee = Cluster(context)
        self.ns, self.tns = env.get("NS", "coco-validation"), env.get("TRUSTEE_NS", "trustee-operator-system")
        self.timeout = int(env.get("TIMEOUT") or "180")
        if self.timeout < 30:
            raise Incomplete("TIMEOUT must allow at least 30 seconds for an observable proof")
        self.id, self.pods, self.evidence = uuid.uuid4().hex[:10], {}, {}
        self.negative_name = None

    def preflight(self):
        from trustee_config import FIELDS, ready_configmaps, restricted_features, selected_kbs
        if self.env.get("COCO_DISPOSABLE_TEST") != "1":
            raise Incomplete("set COCO_DISPOSABLE_TEST=1 only for an isolated validation environment")
        manifest = Path(self.env.get("RELEASE_MANIFEST") or REPO / "install/release-manifest.json")
        check = subprocess.run([sys.executable, str(REPO / "scripts/verify-release.py"), "--manifest", str(manifest),
                                "--tee", self.env.get("TEE", "snp"), "--require-resolved"], env=self.env,
                               capture_output=True, text=True, timeout=30)
        if check.returncode:
            raise Incomplete("release identities are unresolved or inconsistent; run make preflight before proofs")
        bom = json.loads(manifest.read_text())
        for cluster, ns in ((self.worker, self.ns), (self.trustee, self.tns)):
            labels = cluster.get("namespace", ns).get("metadata", {}).get("labels", {})
            if labels.get("coco.openshift.io/disposable") != "true":
                raise Incomplete(f"namespace {ns} must be explicitly labeled coco.openshift.io/disposable=true")
        cv = self.worker.get("clusterversion", "version")
        desired = cv.get("status", {}).get("desired", {})
        if desired.get("version") != bom["platform"]["version"] or desired.get("image", "").split("@")[-1] != bom["platform"]["releaseImage"].split("@")[-1]:
            raise Incomplete("worker cluster version/payload differs from the selected release manifest")
        conditions = {c["type"]: c["status"] for c in cv.get("status", {}).get("conditions", [])}
        if conditions.get("Available") != "True" or conditions.get("Progressing") != "False" or conditions.get("Failing") != "False":
            raise Incomplete("worker release has not finished converging")
        operator_evidence = {}
        for key, cluster, ns in (("osc", self.worker, "openshift-sandboxed-containers-operator"), ("trustee", self.trustee, self.tns)):
            expected = bom["operators"][key]
            csv = cluster.get("csv", expected["startingCSV"], ns)
            if csv.get("status", {}).get("phase") != "Succeeded" or csv.get("spec", {}).get("version") != expected["version"]:
                raise Incomplete(f"{key} operator does not match the selected successful CSV")
            operator_evidence[key] = {"csv": csv["metadata"]["name"], "uid": csv["metadata"]["uid"], "version": csv["spec"]["version"]}
        runtime = self.worker.get("runtimeclass", "kata-cc")
        tee = self.env.get("TEE", "snp")
        if runtime.get("handler") != {"snp": "kata-snp", "tdx": "kata-tdx"}.get(tee):
            raise Incomplete(f"runtime handler does not match TEE={tee}")
        trustees = self.trustee.get("trusteeconfigs", namespace=self.tns).get("items", [])
        profile = self.env.get("TRUSTEE_PROFILE", "Restricted")
        if profile not in ("Restricted", "Permissive") or (profile == "Permissive" and self.env.get("TRUSTEE_LAB") != "1"):
            raise Incomplete("Permissive proofs require explicit TRUSTEE_PROFILE=Permissive TRUSTEE_LAB=1")
        if len(trustees) != 1 or trustees[0]["metadata"]["name"] != self.env.get("TRUSTEE_NAME", "trustee-config") or trustees[0].get("spec", {}).get("profileType") != profile:
            raise Incomplete("TrusteeConfig count, identity or profile differs from the explicit proof target")
        tc = trustees[0]
        try:
            kbs = selected_kbs({"trustee": tc, "kbsconfigs": self.trustee.get("kbsconfigs", namespace=self.tns)})
            maps = {kbs["spec"][field]: self.trustee.get("configmap", kbs["spec"][field], self.tns) for field, _ in FIELDS.values()}
            payload = {"trustee": tc, "kbs": kbs, "maps": maps}
            ready_configmaps(payload)
            if profile == "Restricted":
                rvps = maps[kbs["spec"][FIELDS["rvps"][0]]]
                restricted_features(payload, tee, rvps)
        except (ValueError, KeyError, TypeError) as exc:
            raise Incomplete(f"Trustee configuration is not ready for isolated proofs: {exc}") from exc
        self.refs = kbs["spec"]
        return {"workerContext": self.worker.context, "trusteeContext": self.trustee.context,
                "clusterID": cv.get("spec", {}).get("clusterID"), "release": cv.get("status", {}).get("desired", {}),
                "tee": tee, "runtimeHandler": runtime.get("handler"), "kbsConfigUID": kbs["metadata"]["uid"],
                "trusteeConfigUID": tc["metadata"]["uid"], "trusteeProfile": profile,
                "operators": operator_evidence,
                "configMaps": {n: {"uid": cm["metadata"]["uid"], "resourceVersion": cm["metadata"]["resourceVersion"], "dataSHA256": digest(cm.get("data", {}))} for n, cm in maps.items()}}

    def render(self, case, suffix, **overrides):
        try:
            import yaml
        except ImportError as exc:
            raise Incomplete("install requirements-dev.txt before rendering proofs") from exc
        script = {"rung-signed": "apply-rung-signed.sh", "rung-encrypted": "apply-rung-encrypted.sh"}.get(case, "apply-rung-kbs.sh")
        name = f"proof-{self.id}-{suffix}"
        env = {**self.env, "NS": self.ns, "POD_NAME": name, "RENDER_ONLY": "1", **overrides}
        proc = subprocess.run(["bash", str(REPO / "scripts" / script)], env=env, capture_output=True, text=True, timeout=120)
        if proc.returncode:
            raise Incomplete(f"{script} could not render; verify image, CA and initdata inputs")
        pod = yaml.safe_load(proc.stdout)
        if not isinstance(pod, dict) or pod.get("kind") != "Pod":
            raise Incomplete("renderer must return exactly one Pod")
        pod.setdefault("metadata", {}).setdefault("labels", {})["coco.openshift.io/proof-run"] = self.id
        pod["metadata"].update(name=name, namespace=self.ns)
        self.evidence.setdefault("manifestHashes", {})[suffix] = digest(pod)
        return pod

    def start(self, pod):
        name = pod["metadata"]["name"]
        self.pods[name] = {"uid": None, "runID": self.id}
        self.worker.call("create", "-f", "-", data=pod)
        observed = self.worker.get("pod", name, self.ns)
        self.pods[name]["uid"] = observed["metadata"]["uid"]
        self.evidence.setdefault("pods", {})[name] = {"uid": observed["metadata"]["uid"]}
        return name

    def positive(self, case, suffix):
        pod = self.render(case, suffix)
        name, deadline = self.start(pod), time.monotonic() + self.timeout
        while time.monotonic() < deadline:
            live = self.worker.get("pod", name, self.ns)
            if application_ready(live) and (case in ("rung-signed", "rung-encrypted") or resource_released(live)):
                self.evidence.setdefault("controls", []).append({"name": suffix, "status": "PASS"})
                self.evidence["pods"][name]["node"] = live.get("spec", {}).get("nodeName", "")
                return pod
            if live.get("status", {}).get("phase") == "Failed":
                break
            time.sleep(3)
        raise Incomplete(f"positive control {suffix} did not run; no attributable negative proof is possible")

    def negative(self, case, pod):
        self.negative_name = pod["metadata"]["name"]
        name, deadline = self.start(pod), time.monotonic() + self.timeout
        while True:
            live = self.worker.get("pod", name, self.ns)
            if application_started(live) or resource_released(live):
                raise ProofFailure(f"{case}: protected application started or gated resource was released")
            if time.monotonic() >= deadline:
                break
            time.sleep(3)
        uid = live["metadata"]["uid"]
        events = self.worker.call("get", "events", "-n", self.ns, f"--field-selector=involvedObject.uid={uid}", "-o", "json", optional=True)
        container = "app" if case in ("rung-signed", "rung-encrypted") else "attestation-gate"
        logs = self.worker.call("logs", name, "-n", self.ns, "-c", container, "--tail=80", optional=True)
        corpus = json.dumps(live.get("status", {})) + "\n" + events + "\n" + logs
        oracle = "rung-initdata" if case == "rung-encrypted" else case
        if not denial_matches(oracle, corpus):
            raise Incomplete(f"{case}: pod did not start, but no attributable denial was observed")
        self.evidence["negative"] = {"status": "PASS", "podUID": uid, "corpusSHA256": hashlib.sha256(corpus.encode()).hexdigest()}

    def config_edit(self, field):
        name = self.refs.get(field)
        if not name:
            raise Incomplete(f"KbsConfig is missing {field}")
        return ResourceEdit(self.trustee, "configmap", name, self.tns, self.state)

    def run(self, case):
        self.id, self.evidence = uuid.uuid4().hex[:10], {}
        self.negative_name = None
        if case in ("rung-signed", "rung-encrypted"):
            key = "RUNG_SIGNED_IMAGE" if case == "rung-signed" else "RUNG_ENCRYPTED_IMAGE"
            if not re.search(r"@sha256:[a-f0-9]{64}$", self.env.get(key, "")):
                raise Incomplete(f"{key} must identify an immutable image digest")
        if case == "rung-encrypted" and self.env.get("EXPERIMENTAL_ENCRYPTED_IMAGES") != "1":
            raise Incomplete("selected payload encryption is unverified; use EXPERIMENTAL_ENCRYPTED_IMAGES=1 for a disposable experiment")
        self.evidence["supportStatus"] = "experimental" if case == "rung-encrypted" else "candidate"
        edit = None
        try:
            if case in ("rung-initdata", "rung-encrypted"):
                edit = self.config_edit("kbsAttestationPolicyConfigMapName")
                control = self.render(case, "binding-input")
                annotation = control["metadata"]["annotations"]["io.katacontainers.config.hypervisor.cc_init_data"]
                raw = gzip.decompress(base64.b64decode(annotation, validate=True))
                cpu = bind_initdata_policy(edit.original_data.get("default_cpu.rego", ""), hashlib.sha256(raw).hexdigest())
                edit.change({**edit.original_data, "default_cpu.rego": cpu})
                restart_trustee(self.trustee, self.tns)
            self.positive(case, "control")
            if case == "rung-kbs":
                negative = self.render(case, "negative", CONFIDENTIAL="0")
            elif case in ("rung-initdata", "rung-encrypted"):
                negative = self.render(case, "negative", TAMPER_INITDATA="1")
            elif case == "rung-signed":
                image = self.env.get("RUNG_SIGNED_UNSIGNED_IMAGE", "")
                if not re.search(r"@sha256:[a-f0-9]{64}$", image) or image == self.env.get("RUNG_SIGNED_IMAGE"):
                    raise Incomplete("RUNG_SIGNED_UNSIGNED_IMAGE must be a distinct accessible immutable unsigned/wrong-key image")
                negative = self.render(case, "negative", RUNG_SIGNED_IMAGE=image)
            elif case == "rung-rvps":
                edit = self.config_edit("kbsRvpsRefValuesConfigMapName")
                try:
                    records = json.loads(edit.original_data["reference_value"])
                except (KeyError, ValueError) as exc:
                    raise Incomplete("RVPS must use validated Trustee 1.2 reference_value records") from exc
                key = "snp_launch_measurement" if self.env.get("TEE", "snp") == "snp" else "mr_td"
                if not isinstance(records, dict) or key not in records:
                    raise Incomplete(f"approved RVPS must contain {key}")
                self.evidence["referenceChange"] = {"removedName": key, "beforeSHA256": digest(records)}
                changed = dict(records)
                del changed[key]
                edit.change({**edit.original_data, "reference_value": json.dumps(changed, sort_keys=True)})
                restart_trustee(self.trustee, self.tns)
                negative = self.render(case, "negative")
            elif case == "air-gap":
                if self.env.get("TEE", "snp") != "snp":
                    raise Incomplete("TDX expiry proof requires matching collateral fixtures; SNP VCEK corruption is not a TDX test")
                name = self.env.get("VCEK_SECRET_NAME", "")
                if not name:
                    raise Incomplete("set VCEK_SECRET_NAME for the selected node; other VCEKs will not be mutated")
                if not self.env.get("PROOF_NODE"):
                    raise Incomplete("set PROOF_NODE to bind all VCEK controls to the intended worker")
                edit = ResourceEdit(self.trustee, "secret", name, self.tns, self.state)
                if "vcek.der" not in edit.original_data:
                    raise Incomplete("selected Secret has no vcek.der")
                wrong = self.state / "wrong-vcek.pem"
                subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-keyout", "/dev/null", "-out", str(wrong), "-days", "1", "-nodes", "-subj", "/CN=wrong-vcek"], capture_output=True, timeout=30, check=True)
                der = subprocess.run(["openssl", "x509", "-in", str(wrong), "-outform", "der"], capture_output=True, timeout=30, check=True).stdout
                edit.change({**edit.original_data, "vcek.der": base64.b64encode(der).decode()})
                restart_trustee(self.trustee, self.tns)
                negative = self.render(case, "negative")
            else:
                raise Incomplete(f"unknown case {case}")
            self.negative(case, negative)
        finally:
            # A denied pod may retry as soon as policy is restored. Remove it first.
            if self.negative_name is not None:
                try:
                    self.delete_pod(self.negative_name)
                    self.evidence["negativeCleanup"] = "PASS"
                except BaseException as exc:
                    self.evidence["restoration"] = "FAIL"
                    raise ProofFailure("negative pod cleanup failed; restore shared policy only after removing the pod; recovery files and lock retained") from exc
            if edit is not None:
                try:
                    edit.restore()
                    restart_trustee(self.trustee, self.tns)
                    self.evidence["restoration"] = "PASS"
                except BaseException as exc:
                    self.evidence["restoration"] = "FAIL"
                    raise ProofFailure(f"restoration failed; protected recovery file: {edit.backup}") from exc
        self.positive(case, "recovery")

    def delete_pod(self, name):
        expected = self.pods[name]
        raw = self.worker.call("get", "pod", name, "-n", self.ns, "--ignore-not-found", "-o", "json")
        if raw.strip():
            live = json.loads(raw)
            if ((expected["uid"] is not None and live["metadata"]["uid"] != expected["uid"])
                    or live["metadata"].get("labels", {}).get("coco.openshift.io/proof-run") != expected["runID"]):
                raise ProofFailure(f"refusing cleanup of changed or foreign pod {name}")
            self.worker.call("delete", "pod", name, "-n", self.ns, "--wait=true", "--timeout=60s")
            if self.worker.call("get", "pod", name, "-n", self.ns, "--ignore-not-found", "-o", "json").strip():
                raise ProofFailure(f"pod {name} remains after deletion")
        del self.pods[name]

    def cleanup(self):
        for name in list(self.pods):
            self.delete_pod(name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("case", nargs="?", default="all", choices=["all", *CASES])
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--fresh", action="store_true", help="compatibility flag; proofs always rerun")
    args = parser.parse_args()
    selected = DEFAULT_CASES if args.case == "all" else [args.case]
    if args.list or args.dry_run:
        print(json.dumps({"cases": {name: CASES[name] for name in (CASES if args.list else selected)}, "controls": ["positive", "attributable negative", "verified restore", "recovery"], "reusePastProofs": False}, indent=2))
        return 0
    state = state_directory(REPO) / "proofs" / (datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ-") + uuid.uuid4().hex[:8])
    state.mkdir(parents=True, mode=0o700)
    report = {"schemaVersion": 1, "startedAt": now(), "cases": [], "status": "INCOMPLETE"}
    runner = None
    lock = None
    try:
        runner = Runner(dict(os.environ), state)
        report["provenance"] = runner.preflight()
        lock = ProofLock(runner.trustee, runner.tns, str(state.name))
        lock.acquire()
        report["sourceRevision"] = subprocess.run(["git", "rev-parse", "HEAD"], cwd=REPO, capture_output=True, text=True, check=True).stdout.strip()
        report["implementationSHA256"] = digest({str(p.relative_to(REPO)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted((REPO / "scripts").rglob("*")) if p.suffix in (".py", ".sh")})
        report["releaseManifestSHA256"] = hashlib.sha256(Path(os.environ.get("RELEASE_MANIFEST") or REPO / "install/release-manifest.json").read_bytes()).hexdigest()
        for case in selected:
            result = {"case": case, "startedAt": now(), "status": "INCOMPLETE"}
            print(f"[{case}] positive → negative → restore → recovery", flush=True)
            try:
                runner.run(case)
                result["status"] = "PASS"
            except Incomplete as exc:
                result["reason"] = str(exc)
            except (ProofFailure, subprocess.SubprocessError, OSError, ValueError, KeyError) as exc:
                result.update(status="FAIL", reason=str(exc))
            result.update(finishedAt=now(), evidence=copy.deepcopy(runner.evidence))
            report["cases"].append(result)
            atomic_json(state / "results.json", report)
            print(f"[{case}] {result['status']}: {result.get('reason', 'all controls completed')}", flush=True)
            if result["status"] != "PASS":
                break
        report["status"] = "PASS" if len(report["cases"]) == len(selected) and all(r["status"] == "PASS" for r in report["cases"]) else "FAIL" if any(r["status"] == "FAIL" for r in report["cases"]) else "INCOMPLETE"
    except (Incomplete, OSError, subprocess.SubprocessError, ValueError) as exc:
        report["reason"] = str(exc)
    finally:
        try:
            if runner is not None and report["status"] == "PASS":
                runner.cleanup()
            restore_failed = runner is not None and runner.evidence.get("restoration") == "FAIL"
            if restore_failed:
                report["retainedLock"] = "coco-proof-lock; verify recovery before manually removing it"
            elif lock is not None:
                lock.release()
        except (Incomplete, ProofFailure, OSError) as exc:
            report.update(status="FAIL", reason=f"cleanup or lock release failed: {exc}")
        report["finishedAt"] = now()
        report["notExecuted"] = [name for name in selected if name not in {r["case"] for r in report["cases"]}]
        atomic_json(state / "results.json", report)
        print(f"Proof run {report['status']}; report: {state / 'results.json'}")
        if report.get("reason"):
            print(report["reason"], file=sys.stderr)
    return {"PASS": 0, "FAIL": 1, "INCOMPLETE": 3}[report["status"]]


if __name__ == "__main__":
    def interrupted(signum, frame):
        raise KeyboardInterrupt(f"interrupted by signal {signum}")
    signal.signal(signal.SIGTERM, interrupted)
    try:
        raise SystemExit(main())
    except Incomplete as exc:
        print(f"INCOMPLETE: {exc}", file=sys.stderr)
        raise SystemExit(3)
