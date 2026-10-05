#!/usr/bin/env python3
"""Offline Trustee 1.2 resource transformations. Never reads credentials or calls oc."""
import argparse
import base64
import copy
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tomllib

MIGRATION = "kbs.confidentialcontainers.org/migrated-from-v1.1.0"
VERSIONS = "kbs.confidentialcontainers.org/configmap-versions"
FIELDS = {
    "config": ("kbsConfigMapName", "kbs-config.toml"),
    "resource": ("kbsResourcePolicyConfigMapName", "resource-policy.rego"),
    "cpu": ("kbsAttestationPolicyConfigMapName", "default_cpu.rego"),
    "gpu": ("kbsGpuAttestationPolicyConfigMapName", "default_gpu.rego"),
    "rvps": ("kbsRvpsRefValuesConfigMapName", "reference_value"),
}


def name(value):
    if not re.fullmatch(r"[a-z0-9](?:[-a-z0-9]*[a-z0-9])?", value) or len(value) > 63:
        raise ValueError(f"invalid Kubernetes resource name: {value!r}")
    return value


def trustee_manifest():
    profile = os.getenv("TRUSTEE_PROFILE", "Restricted")
    if profile not in ("Restricted", "Permissive"):
        raise ValueError("TRUSTEE_PROFILE must be Restricted or Permissive")
    if profile == "Permissive" and os.getenv("TRUSTEE_LAB") != "1":
        raise ValueError("Permissive requires TRUSTEE_LAB=1 for a disposable lab")
    spec = {"profileType": profile, "kbsServiceType": "ClusterIP"}
    if profile == "Restricted":
        spec["httpsSpec"] = {"tlsSecretName": name(os.getenv("TRUSTEE_HTTPS_SECRET", "kbs-https-cert"))}
        spec["attestationTokenVerificationSpec"] = {"tlsSecretName": name(os.getenv("TRUSTEE_TOKEN_SECRET", "kbs-token-cert"))}
    return {"apiVersion": "confidentialcontainers.org/v1alpha1", "kind": "TrusteeConfig",
            "metadata": {"name": name(os.getenv("TRUSTEE_NAME", "trustee-config")),
                         "namespace": name(os.getenv("NS", "trustee-operator-system"))}, "spec": spec}


def selected_kbs(payload):
    tc, items = payload["trustee"], payload["kbsconfigs"]["items"]
    if len(items) != 1:
        raise ValueError("expected exactly one generated KbsConfig; do not mix independent deployments")
    kbs = items[0]
    owners = kbs["metadata"].get("ownerReferences", [])
    if not any(o.get("controller") and o.get("kind") == "TrusteeConfig" and
               o.get("uid") == tc["metadata"]["uid"] for o in owners):
        raise ValueError("existing KbsConfig is not owned by the selected TrusteeConfig; rehearse an explicit migration before proceeding")
    for field, _ in FIELDS.values():
        name(kbs["spec"][field])
    return kbs


def ready_configmaps(payload):
    tc, kbs, maps = payload["trustee"], payload["kbs"], payload["maps"]
    for field, key in FIELDS.values():
        cm = maps[kbs["spec"][field]]
        if cm["metadata"].get("annotations", {}).get(MIGRATION) != "v1.2.0":
            raise ValueError(f"Operator migration is not complete for {cm['metadata']['name']}")
        if not any(o.get("controller") and o.get("kind") == "TrusteeConfig" and o.get("uid") == tc["metadata"]["uid"] for o in cm["metadata"].get("ownerReferences", [])):
            raise ValueError(f"unexpected owner for {cm['metadata']['name']}")
        if key not in cm.get("data", {}):
            raise ValueError(f"missing target 1.2 key {key} in {cm['metadata']['name']}")
    return kbs


def restricted_cpu_features(cpu, tee):
    require_snp(tee)
    cpu = re.sub(r"(?m)#.*$", "", cpu)
    for claim, expected in (("hardware", 97), ("executables", 33), ("configuration", 36)):
        if not re.search(r"(?m)^default\s+" + claim + r"\s*:?=\s*" + str(expected) + r"\s*$", cpu):
            raise ValueError(f"unrecognized Restricted CPU default for {claim}; review custom policy")
    # Core values consulted by the target CPU policy for the selected platform.
    required = {"snp_launch_measurement", "snp_bootloader", "snp_microcode", "snp_snp_svn", "snp_tee_svn"}
    queried = set(re.findall(r'query_reference_value\("([^"\n]+)"\)', cpu))
    if not required.issubset(queried):
        raise ValueError("CPU policy is missing the selected platform's hardware/launch checks")
    return required


def restricted_features(payload, tee, references=None):
    """Structural preflight, not Rego execution or evidence appraisal."""
    tc, kbs, maps = payload["trustee"], payload["kbs"], payload["maps"]
    if tc["spec"].get("profileType") != "Restricted":
        raise ValueError("expected the Restricted TrusteeConfig profile")
    config = tomllib.loads(maps[kbs["spec"][FIELDS["config"][0]]]["data"]["kbs-config.toml"])
    token = config.get("attestation_token", {})
    signer = config.get("attestation_service", {}).get("attestation_token_broker", {}).get("signer", {})
    if config.get("http_server", {}).get("insecure_http") is not False or token.get("insecure_header_jwk") is not False:
        raise ValueError("Restricted mode requires HTTPS and trusted token verification")
    if not token.get("trusted_certs_paths") or not signer.get("key_path") or not signer.get("cert_path"):
        raise ValueError("Restricted token trust/signer references are absent")
    for field in ("kbsHttpsKeySecretName", "kbsHttpsCertSecretName", "kbsAttestationKeySecretName", "kbsAttestationCertSecretName"):
        name(kbs["spec"].get(field, ""))
    cpu = maps[kbs["spec"][FIELDS["cpu"][0]]]["data"]["default_cpu.rego"]
    required = restricted_cpu_features(cpu, tee)
    if references is not None:
        values = rvps_values(references)
        if not required.issubset(values):
            raise ValueError("Restricted RVPS is missing core platform references: " + ", ".join(sorted(required - set(values))))
    return {"restrictedFeaturesPresent": True, "policyAppraisalVerified": False}


def serving_ready(payload):
    """Require observed config versions and resource mounts on the new serving pods."""
    kbs, maps, dep, pods = (payload[k] for k in ("kbs", "maps", "deployment", "pods"))
    versions = {kbs["spec"][field]: maps[kbs["spec"][field]]["metadata"]["resourceVersion"]
                for field, _ in FIELDS.values()}
    expected_secrets = set(kbs["spec"].get("kbsSecretResources", []))
    collateral = kbs["spec"].get("kbsLocalCertCacheSpec", {}).get("secrets", [])
    expected_secrets.update(m["secretName"] for m in collateral)

    def check_template(template):
        annotation = template["metadata"].get("annotations", {}).get(VERSIONS, "")
        observed = dict(part.split(":", 1) for part in annotation.split(",") if ":" in part)
        if observed != versions:
            raise ValueError("serving configuration versions have not converged")
        spec = template["spec"]
        volumes = {v["name"]: v.get("secret", {}).get("secretName") for v in spec.get("volumes", [])}
        if not expected_secrets.issubset(set(volumes.values())):
            raise ValueError("serving resource Secret references have not converged")
        mounted = {(volumes.get(m["name"]), m["mountPath"])
                   for c in spec.get("containers", []) for m in c.get("volumeMounts", [])}
        if any((m["secretName"], m["mountPath"]) not in mounted for m in collateral):
            raise ValueError("serving collateral mounts have not converged")

    replicas = dep["spec"].get("replicas", 1)
    status = dep.get("status", {})
    if replicas < 1 or status.get("observedGeneration", 0) < dep["metadata"]["generation"] or any(
            status.get(key, 0) != replicas for key in ("updatedReplicas", "availableReplicas")):
        raise ValueError("Trustee deployment has not converged")
    check_template(dep["spec"]["template"])
    active = [p for p in pods["items"] if not p["metadata"].get("deletionTimestamp")]
    if len(active) != replicas:
        raise ValueError("waiting for the intended number of serving pods")
    for pod in active:
        if pod["metadata"]["uid"] in payload["old_uids"] or not any(
                c.get("type") == "Ready" and c.get("status") == "True" for c in pod.get("status", {}).get("conditions", [])):
            raise ValueError("waiting for a new Ready serving pod")
        check_template(pod)
    return {"ready": True}


def require_snp(tee):
    if tee != "snp":
        raise ValueError("this workflow targets AMD SEV-SNP; set TEE=snp")


def patch_toml(text, tee):
    require_snp(tee)
    original = tomllib.loads(text)
    if original.get("admin", {}).get("authorization_mode") != "DenyAll":
        raise ValueError("expected native Trustee 1.2 DenyAll configuration")
    if not any(p.get("name") == "resource" and p.get("storage_backend_type") == "kvstorage" for p in original.get("plugins", [])):
        raise ValueError("expected native Trustee 1.2 kvstorage configuration")
    if "storage_backend" not in original:
        raise ValueError("missing Trustee 1.2 storage_backend")
    section = "attestation_service.verifier_config.snp_verifier"
    key = "vcek_sources"
    value = '[{ type = "OfflineStore" }]'
    block = re.search(r"(?ms)^\[" + re.escape(section) + r"\][^\n]*\n(.*?)(?=^\[|\Z)", text)
    expected = copy.deepcopy(original)
    verifier = expected.setdefault("attestation_service", {}).setdefault("verifier_config", {}).setdefault(section.rsplit(".", 1)[1], {})
    verifier[key] = [{"type": "OfflineStore"}]
    if block:
        body = block.group(1)
        pattern = r"(?ms)^vcek_sources\s*=\s*\[.*?\]"
        body, count = re.subn(pattern, f"{key} = {value}", body)
        if not count:
            body += f"\n{key} = {value}\n"
        text = text[:block.start(1)] + body + text[block.end(1):]
    else:
        text += f"\n[{section}]\n{key} = {value}\n"
    if tomllib.loads(text) != expected:
        raise ValueError("refusing TOML edit that changes unrelated configuration")
    return text


def vcek_mounts(hwids):
    mounts = []
    for hwid in sorted(set(hwids)):
        if not re.fullmatch(r"[0-9a-f]{128}", hwid):
            raise ValueError("VCEK HWID must be 128 lowercase hex characters")
        short = hashlib.sha256(hwid.encode()).hexdigest()[:16]
        mounts.append({"secretName": f"vcek-snp-{hwid[:16]}-{short}", "mountPath": f"/opt/confidential-containers/attestation-service/kds-store/vcek/{hwid}"})
    return mounts


def kbs_patch(kbs, tee, hwids, resources):
    require_snp(tee)
    spec = kbs["spec"]
    incoming = vcek_mounts(hwids)
    if not incoming:
        raise ValueError("no offline attestation collateral selected")
    mounts = copy.deepcopy(spec.get("kbsLocalCertCacheSpec", {}).get("secrets", []))
    for new in incoming:
        conflicts = [m for m in mounts if m["mountPath"] == new["mountPath"] and m != new]
        if conflicts:
            raise ValueError(f"existing collateral mount conflicts with {new['mountPath']}")
        if new not in mounts:
            mounts.append(new)
    # Omission never removes an existing resource; pruning is a separate reviewed operation.
    names = sorted(set(spec.get("kbsSecretResources", [])) | {name(x) for x in resources})
    return {"metadata": {"resourceVersion": kbs["metadata"]["resourceVersion"]},
            "spec": {"kbsLocalCertCacheSpec": {"secrets": mounts}, "kbsSecretResources": names}}


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate document key: {key}")
        result[key] = value
    return result


def strict_json(text):
    return json.loads(text, object_pairs_hook=unique_object)


def load_document(path):
    text = Path(path).read_text()
    try:
        return strict_json(text)
    except json.JSONDecodeError:
        try:
            import yaml
        except ImportError as exc:
            raise ValueError("YAML input requires PyYAML; install requirements-dev.txt") from exc
        class UniqueLoader(yaml.SafeLoader):
            pass

        def mapping(loader, node):
            loader.flatten_mapping(node)
            return unique_object((loader.construct_object(k), loader.construct_object(v)) for k, v in node.value)

        UniqueLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, mapping)
        try:
            return yaml.load(text, Loader=UniqueLoader)
        except yaml.YAMLError as exc:
            raise ValueError(f"invalid YAML reference document: {exc}") from exc


def rvps_values(document, allow_empty=False):
    if isinstance(document, dict) and document.get("kind") == "ConfigMap":
        data = document.get("data", {})
        keys = set(data) & {"reference_value", "reference-values.json"}
        if len(keys) != 1:
            raise ValueError("RVPS ConfigMap must contain exactly one known reference-data key")
        document = strict_json(data[keys.pop()])
    records = []
    if isinstance(document, list):
        records = document
    elif isinstance(document, dict):
        for key, value in document.items():
            record = strict_json(base64.b64decode(value, validate=True))
            if not isinstance(record, dict):
                raise ValueError("RVPS record must be an object")
            if record.get("name") != key:
                raise ValueError(f"RVPS record name differs from object key: {key}")
            records.append(record)
    else:
        raise ValueError("RVPS data must be an array of records or encoded named object")
    if not records and not allow_empty:
        raise ValueError("empty RVPS reference set cannot validate a workload")
    result = {}
    now = dt.datetime.now(dt.timezone.utc)
    for record in records:
        if not isinstance(record, dict):
            raise ValueError("RVPS record must be an object")
        key = record.get("name")
        if not isinstance(key, str) or not key or key in result:
            raise ValueError("RVPS record has an empty or duplicate name")
        if not isinstance(record.get("expiration"), str):
            raise ValueError(f"RVPS record lacks a string expiration: {key}")
        expiry = dt.datetime.fromisoformat(record["expiration"].replace("Z", "+00:00"))
        if expiry.tzinfo is None or expiry <= now:
            raise ValueError(f"RVPS record is expired or lacks a timezone: {key}")
        if "value" not in record or record["value"] is None or record["value"] == "" or record["value"] == [] or record["value"] == {}:
            raise ValueError(f"RVPS record lacks a nonempty value: {key}")
        if not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", record["expiration"]):
            raise ValueError(f"RVPS expiration must use Trustee UTC seconds format: {key}")
        result[key] = base64.b64encode(json.dumps(record, separators=(",", ":")).encode()).decode()
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["render", "select", "ready", "restricted", "serving", "offline-config", "mounts", "kbs-patch", "rvps"])
    parser.add_argument("--tee", choices=["snp"], default="snp")
    parser.add_argument("--hwids", default="")
    parser.add_argument("--resources", default="")
    parser.add_argument("--file")
    parser.add_argument("--name", default="trustee-config-rvps-reference-values")
    parser.add_argument("--namespace", default="trustee-operator-system")
    args = parser.parse_args()
    if args.command == "render":
        result = trustee_manifest()
    elif args.command == "mounts":
        result = vcek_mounts(args.hwids.replace(",", " ").split())
    elif args.command == "rvps":
        values = rvps_values(load_document(args.file))
        result = {"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": name(args.name), "namespace": name(args.namespace)}, "data": {"reference_value": json.dumps(values, sort_keys=True)}}
    else:
        payload = json.load(sys.stdin)
        if args.command == "select":
            result = selected_kbs(payload)
        elif args.command == "ready":
            result = ready_configmaps(payload)
        elif args.command == "restricted":
            result = restricted_features(payload, args.tee, load_document(args.file) if args.file else None)
        elif args.command == "serving":
            result = serving_ready(payload)
        elif args.command == "offline-config":
            text = patch_toml(payload["data"]["kbs-config.toml"], args.tee)
            result = {"metadata": {"resourceVersion": payload["metadata"]["resourceVersion"]}, "data": {"kbs-config.toml": text}}
        else:
            result = kbs_patch(payload, args.tee, args.hwids.replace(",", " ").split(), args.resources.replace(",", " ").split())
    json.dump(result, sys.stdout, indent=2)
    print()


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, TypeError, OSError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(2)
