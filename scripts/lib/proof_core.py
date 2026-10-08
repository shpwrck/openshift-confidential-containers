"""Hardware-proof boundaries: explicit identities, conservative oracles, verified restore.

No cluster action occurs on import. The small pure functions are also used by offline tests.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time
from typing import Any


class Incomplete(RuntimeError):
    """The required evidence or prerequisite is absent; this is never a pass."""


class ProofFailure(RuntimeError):
    """The tested contract was violated, including inability to restore test state."""


def digest(value: Any) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def atomic_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, name = tempfile.mkstemp(dir=path.parent, prefix=".result-")
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(value, stream, indent=2, sort_keys=True)
            stream.write("\n")
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def state_directory(repo: Path) -> Path:
    default = Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state"))) / "openshift-confidential-containers"
    path = Path(os.environ.get("COCO_STATE_DIR", str(default))).expanduser().resolve()
    if path == repo or repo in path.parents:
        raise Incomplete("COCO_STATE_DIR must be outside the checkout; it holds protected recovery material")
    # This checkout can be used from Homelab, whose credential policy is stricter than gitignore.
    if str(path).lower() == "/mnt/c/homelab" or str(path).lower().startswith("/mnt/c/homelab/"):
        raise Incomplete("COCO_STATE_DIR must be outside /mnt/c/Homelab")
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.chmod(0o700)
    return path


def application_started(pod: dict) -> bool:
    """A crash or short-lived run also violates a before-start denial contract."""
    if pod.get("status", {}).get("phase") in ("Running", "Succeeded"):
        return True
    for status in pod.get("status", {}).get("containerStatuses", []):
        for state in (status.get("state", {}), status.get("lastState", {})):
            if state.get("running") or state.get("terminated", {}).get("startedAt"):
                return True
    return False


def resource_released(pod: dict) -> bool:
    for status in pod.get("status", {}).get("initContainerStatuses", []):
        if status.get("name") == "attestation-gate":
            return status.get("state", {}).get("terminated", {}).get("exitCode") == 0
    return False


def application_ready(pod: dict) -> bool:
    statuses = pod.get("status", {}).get("containerStatuses", [])
    return bool(statuses) and all(s.get("ready") and s.get("state", {}).get("running") for s in statuses)


class ProofLock:
    """Namespace lock prevents proof runners from changing a shared Trustee concurrently.

    A killed controller leaves the lock for an operator to inspect alongside recovery files;
    expiry must not allow a second controller to race an unfinished restoration.
    """
    def __init__(self, cluster, namespace, run_id):
        self.cluster, self.namespace, self.run_id = cluster, namespace, run_id
        self.uid = None

    def acquire(self):
        self.cluster.call("create", "-f", "-", data={
            "apiVersion": "v1", "kind": "ConfigMap",
            "metadata": {"name": "coco-proof-lock", "namespace": self.namespace},
            "data": {"runID": self.run_id},
        })
        current = self.cluster.get("configmap", "coco-proof-lock", self.namespace)
        if current.get("data", {}).get("runID") != self.run_id:
            raise Incomplete("proof lock ownership changed; inspect coco-proof-lock")
        self.uid = current["metadata"]["uid"]

    def release(self):
        if self.uid is None:
            return
        current = self.cluster.get("configmap", "coco-proof-lock", self.namespace)
        if current["metadata"]["uid"] != self.uid or current.get("data", {}).get("runID") != self.run_id:
            raise ProofFailure("proof lock was replaced; it was left untouched")
        self.cluster.call("delete", "configmap", "coco-proof-lock", "-n", self.namespace, "--wait=true")
        self.uid = None


DENIALS = {
    "rung-kbs": re.compile(r"(?i)(?:failed to connect|connection refused|ECONNREFUSED).*?(?:127\.0\.0\.1|8006)|curl: \(7\)"),
    "rung-initdata": re.compile(r"(?i)\bPolicyDeny\b|(?:resource|policy|request|attest)[^\n]*(?:\b403\b|forbidden|denied)|returned error: 403"),
    "rung-rvps": re.compile(r"(?i)\bPolicyDeny\b|(?:resource|policy|request|attest)[^\n]*(?:\b403\b|forbidden|denied)|returned error: 403"),
    "rung-signed": re.compile(r"(?i)(?:signature|sigstore)[^\n]*(?:verification failed|not found|missing|invalid|rejected|mismatch)|(?:no signatures|no matching signatures|signature verification failed)"),
    "air-gap": re.compile(r"(?i)(?:certificate chain|VCEK|TEE evidence|endorsement)[^\n]*(?:failed|invalid|reject|does not sign)|attestation[^\n]*(?:failed|denied|\b401\b)"),
}


def denial_matches(case: str, text: str) -> bool:
    # These messages are prerequisite/transport failures, even if they mention a signature URI.
    unrelated = re.compile(r"(?i)InvalidImageName|no such host|connection timed out|manifest unknown|unauthorized: authentication required")
    return not unrelated.search(text) and bool(DENIALS[case].search(text))


def trustee_denial_matches(case: str, text: str, peer: str) -> bool:
    """Bind an adjacent verifier/policy failure to this guest's HTTP denial.

    Use only logs fetched since the negative pod's creation. An error from another
    peer, a successful request or a bare HTTP denial is insufficient. Each access
    record ends a frame, preventing an older failure from matching a later peer.
    """
    import ipaddress
    try:
        ipaddress.ip_address(peer)
    except ValueError:
        return False
    access = re.compile(r'actix_web::middleware::logger:\s+(\S+)\s+"(GET|POST) (/kbs/v0/[^\s]+) HTTP/[^\"]+"\s+(\d{3})\b')
    frame = []
    for line in re.sub(r"\x1b\[[0-9;]*m", "", text).splitlines():
        frame.append(line)
        match = access.search(line)
        if match:
            address, method, path, status = match.groups()
            endpoint = method == "POST" and path == "/kbs/v0/attest" if case == "air-gap" else method == "GET" and path.startswith("/kbs/v0/resource/")
            if address == peer and endpoint and status in ("401", "403") and denial_matches(case, "\n".join(frame)):
                return True
            frame = []
    return False


def bind_initdata_policy(base: str, expected: str) -> str:
    """Add a monotonic configuration gate without discarding vendor TCB/launch checks.

    Recognize one explicit trust-vector mapping. Unknown policy structures require review;
    they must never fall back to an all-affirming demonstration policy.
    """
    if not re.fullmatch(r"[0-9a-f]{64}", expected):
        raise ValueError("expected initdata must be a SHA-256 hex digest")
    mapping = re.compile(r'(?m)^(\s*"configuration"\s*:\s*)configuration(\s*,?\s*)$')
    if len(mapping.findall(base)) != 1 or "coco_bound_configuration" in base:
        raise Incomplete("CPU policy has no unique, unmodified configuration mapping; review it before adding initdata binding")
    result = mapping.sub(r"\1coco_bound_configuration\2", base)
    return result.rstrip() + f'''\n\n# Added by the isolated initdata proof; all original appraisals remain in force.
default coco_bound_configuration := 36
coco_bound_configuration := configuration if {{
  input.init_data == "{expected}"
}}
'''


class Cluster:
    def __init__(self, context: str):
        if not context:
            raise Incomplete("explicit WORKER_CONTEXT and TRUSTEE_CONTEXT are required")
        self.context = context

    def call(self, *args: str, data: Any = None, optional: bool = False) -> str:
        command = ["oc", f"--context={self.context}", "--request-timeout=30s", *args]
        try:
            result = subprocess.run(command, input=None if data is None else json.dumps(data),
                                    capture_output=True, text=True, timeout=180)
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise Incomplete(f"oc {args[0] if args else ''} unavailable or timed out") from exc
        if result.returncode and not optional:
            # Never echo serialized Secret objects or unrestricted stderr into the report.
            raise Incomplete(f"oc {args[0] if args else ''} failed in context {self.context}; inspect the selected resource")
        return result.stdout if result.returncode == 0 else ""

    def get(self, kind: str, name: str = "", namespace: str = "") -> dict:
        args = ["get", kind]
        if name:
            args.append(name)
        if namespace:
            args.extend(["-n", namespace])
        args.extend(["-o", "json"])
        try:
            return json.loads(self.call(*args))
        except json.JSONDecodeError as exc:
            raise Incomplete(f"invalid JSON returned for {kind}") from exc

    def apply(self, value: dict) -> None:
        self.call("apply", "-f", "-", data=value)


class ResourceEdit:
    """Change only a resource's data with concurrency checks, retaining recovery evidence."""
    def __init__(self, cluster: Cluster, kind: str, name: str, namespace: str, state: Path):
        self.cluster, self.kind, self.name, self.namespace = cluster, kind, name, namespace
        self.original = cluster.get(kind, name, namespace)
        self.original_data = self.original.get("data", {})
        self.modified: dict | None = None
        self.backup = state / f"restore-{kind}-{name}.json"
        atomic_json(self.backup, self.original)

    def _patch(self, current: dict, expected: dict, replacement: dict) -> None:
        if current["metadata"]["uid"] != self.original["metadata"]["uid"] or current.get("data", {}) != expected:
            raise ProofFailure(f"concurrent change to {self.kind}/{self.name}; preserved recovery file: {self.backup}")
        ops = [
            {"op": "test", "path": "/metadata/uid", "value": self.original["metadata"]["uid"]},
            {"op": "test", "path": "/metadata/resourceVersion", "value": current["metadata"]["resourceVersion"]},
            {"op": "add", "path": "/data", "value": replacement},
        ]
        self.cluster.call("patch", self.kind, self.name, "-n", self.namespace, "--type=json", "--patch-file=/dev/stdin", data=ops)
        observed = self.cluster.get(self.kind, self.name, self.namespace)
        if observed.get("data", {}) != replacement:
            raise ProofFailure(f"{self.kind}/{self.name} did not retain the requested data; recovery file: {self.backup}")

    def change(self, replacement: dict) -> None:
        self.modified = replacement  # Arm restoration before a possibly ambiguous API response.
        self._patch(self.cluster.get(self.kind, self.name, self.namespace), self.original_data, replacement)

    def restore(self) -> None:
        if self.modified is None:
            return
        current = self.cluster.get(self.kind, self.name, self.namespace)
        if current.get("data", {}) == self.original_data and current["metadata"]["uid"] == self.original["metadata"]["uid"]:
            self.modified = None
            return
        self._patch(current, self.modified, self.original_data)
        self.modified = None


def restart_trustee(cluster: Cluster, namespace: str, timeout: int = 180, trustee_name: str = "") -> None:
    from trustee_config import FIELDS, ready_configmaps, selected_kbs, serving_ready
    trustees = cluster.get("trusteeconfigs", namespace=namespace).get("items", [])
    if len(trustees) != 1:
        raise Incomplete("Trustee rotation requires exactly one owning TrusteeConfig")
    tc = trustees[0]
    if trustee_name and tc["metadata"]["name"] != trustee_name:
        raise Incomplete("Trustee rotation target differs from the selected TrusteeConfig")
    try:
        selected = selected_kbs({"trustee": tc, "kbsconfigs": cluster.get("kbsconfigs", namespace=namespace)})
    except (ValueError, KeyError, TypeError) as exc:
        raise Incomplete("Trustee rotation requires an Operator-owned KbsConfig") from exc
    deployment = cluster.get("deployment", "trustee-deployment", namespace)
    dep_uid = deployment["metadata"]["uid"]

    def owned_by(obj, kind, uid):
        return any(o.get("controller") and o.get("kind") == kind and o.get("uid") == uid
                   for o in obj.get("metadata", {}).get("ownerReferences", []))

    if not owned_by(deployment, "KbsConfig", selected["metadata"]["uid"]):
        raise Incomplete("Trustee deployment is not owned by the selected KbsConfig")
    replicasets = {rs["metadata"]["uid"] for rs in cluster.get("replicasets", namespace=namespace).get("items", [])
                   if owned_by(rs, "Deployment", dep_uid)}
    previous = [p for p in cluster.get("pods", namespace=namespace).get("items", [])
                if p.get("metadata", {}).get("labels", {}).get("app") == "kbs"]
    if any(not any(owned_by(p, "ReplicaSet", uid) for uid in replicasets) for p in previous):
        raise Incomplete("an app=kbs pod is outside the selected deployment; no pods were replaced")
    old = [p["metadata"]["uid"] for p in previous]
    # The Operator replaces the complete pod template and removes rollout-restart
    # annotations. Replace only identified pods, using API UID preconditions, so
    # the Secret converter reruns even when ConfigMap versions are unchanged.
    from urllib.parse import quote
    for pod in previous:
        if pod["metadata"].get("deletionTimestamp"):
            continue
        path = f"/api/v1/namespaces/{quote(namespace, safe='')}/pods/{quote(pod['metadata']['name'], safe='')}"
        cluster.call("delete", "--raw=" + path, "-f", "-", data={
            "apiVersion": "v1", "kind": "DeleteOptions",
            "preconditions": {"uid": pod["metadata"]["uid"]},
        })
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        deployment = cluster.get("deployment", "trustee-deployment", namespace)
        if deployment["metadata"]["uid"] != dep_uid or not owned_by(deployment, "KbsConfig", selected["metadata"]["uid"]):
            raise Incomplete("Trustee deployment identity changed during rotation")
        pods = {"items": [item for item in cluster.get("pods", namespace=namespace).get("items", [])
                          if item.get("metadata", {}).get("labels", {}).get("app") == "kbs"]}
        try:
            current_tc = cluster.get("trusteeconfig", tc["metadata"]["name"], namespace)
            kbs = selected_kbs({"trustee": current_tc, "kbsconfigs": cluster.get("kbsconfigs", namespace=namespace)})
            if current_tc["metadata"]["uid"] != tc["metadata"]["uid"] or kbs["metadata"]["uid"] != selected["metadata"]["uid"] or kbs["spec"] != selected["spec"]:
                raise Incomplete("Trustee configuration identity changed during rotation")
            maps = {kbs["spec"][field]: cluster.get("configmap", kbs["spec"][field], namespace) for field, _ in FIELDS.values()}
            ready_configmaps({"trustee": current_tc, "kbs": kbs, "maps": maps})
            serving_ready({"kbs": kbs, "maps": maps, "deployment": deployment, "pods": pods, "old_uids": old})
            return
        except (ValueError, KeyError, TypeError):
            # ConfigMap watches and subPath remounts can converge after the rollout event.
            time.sleep(3)
    raise Incomplete("Trustee serving pods did not converge to the current configuration; no proof was accepted")
