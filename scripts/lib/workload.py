"""Canonical initdata and proof-pod rendering, with no cluster side effects."""
from __future__ import annotations
import base64
import gzip
import json
from pathlib import Path
import re
import tomllib
from urllib.parse import urlparse

import yaml

REPO = Path(__file__).resolve().parents[2]



def quoted(text):
    # JSON basic strings are also valid TOML for these Unicode values.
    return json.dumps(text, ensure_ascii=False)


def initdata(env, rung):
    permissive_lab = env.get("TRUSTEE_LAB") == "1" and env.get("TRUSTEE_PROFILE") == "Permissive"
    policy_uri = env.get("IMAGE_SECURITY_POLICY_URI") or env.get(
        "RUNG_SIGNED_POLICY_URI" if rung == "signed" else "RUNG_ENCRYPTED_POLICY_URI"
    ) or ("kbs:///default/security-policy/rung-signed" if rung == "signed" else "kbs:///default/security-policy/test")
    if env.get("INITDATA_FILE"):
        raw = Path(env["INITDATA_FILE"]).read_bytes()
    else:
        url = env.get("KBS_URL") or "http://kbs-service.trustee-operator-system.svc:8080"
        cert = Path(env["KBS_CA_FILE"]).read_text() if env.get("KBS_CA_FILE") else ""
        aa = "[token_configs.kbs]\nurl = " + quoted(url) + "\n"
        cdh = 'socket = "unix:///run/confidential-containers/cdh.sock"\ncredentials = []\n[kbc]\nname = "cc_kbc"\nurl = ' + quoted(url) + "\n"
        if cert:
            aa += "cert = " + quoted(cert) + "\n"
            cdh += "kbs_cert = " + quoted(cert) + "\n"
        cdh += "[image]\n"
        for key, value in {
            "authenticated_registry_credentials_uri": env.get("REGISTRY_CREDENTIAL_URI", "kbs:///default/credential/test"),
            "image_security_policy_uri": policy_uri,
            "registry_configuration_uri": env.get("REGISTRY_CONFIGURATION_URI", "kbs:///default/registry-configuration/test"),
        }.items():
            cdh += f"{key} = {quoted(value)}\n"
        if env.get("MIRROR_CA"):
            chain = Path(env["MIRROR_CA"]).read_text()
            certs = re.findall(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", chain, re.S)
            residue = re.sub(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", "", chain, flags=re.S)
            if not certs or residue.strip():
                raise ValueError("MIRROR_CA must contain only PEM certificates")
            cdh += "extra_root_certificates = [" + ", ".join(quoted(c + "\n") for c in certs) + "]\n"
        data = {"aa.toml": aa, "cdh.toml": cdh}
        if env.get("AGENT_POLICY_FILE"):
            data["policy.rego"] = Path(env["AGENT_POLICY_FILE"]).read_text()
        raw = ('algorithm = "sha256"\nversion = "0.1.0"\n\n[data]\n' +
               "".join(f"{quoted(k)} = {quoted(v)}\n" for k, v in data.items())).encode()
    doc = tomllib.loads(raw.decode())
    if doc.get("algorithm") != "sha256" or doc.get("version") != "0.1.0":
        raise ValueError("proof initdata requires algorithm=sha256 and version=0.1.0")
    data = doc["data"]
    aa = tomllib.loads(data["aa.toml"])["token_configs"]["kbs"]
    cdh = tomllib.loads(data["cdh.toml"])
    if aa["url"] != cdh["kbc"]["url"]:
        raise ValueError("AA and CDH must use the same Trustee URL")
    url = urlparse(aa["url"])
    if url.scheme not in ("http", "https") or not url.hostname or url.username or url.password:
        raise ValueError("KBS_URL must be an HTTP(S) endpoint without credentials")
    if url.scheme == "http" and not permissive_lab:
        raise ValueError("HTTP Trustee requires TRUSTEE_LAB=1 and TRUSTEE_PROFILE=Permissive; configure HTTPS for Restricted")
    if url.scheme == "https" and aa.get("cert") != cdh["kbc"].get("kbs_cert"):
        raise ValueError("AA and CDH must trust the same KBS certificate")
    if not permissive_lab and not data.get("policy.rego", "").strip():
        raise ValueError("supply reviewed AGENT_POLICY_FILE or INITDATA_FILE with a restrictive agent policy")
    if cdh.get("image", {}).get("image_security_policy_uri") != policy_uri:
        raise ValueError("approved initdata image policy URI differs from the selected rung policy")
    if env.get("TAMPER_INITDATA") == "1":
        raw += b"\n# isolated proof: change measured bytes without changing parsed configuration\n"
    return raw


def render(env, rung):
    raw = initdata(env, rung)
    file = {"kbs": "rung-a-secret-pod.yaml", "signed": "rung-signed-pod.yaml", "encrypted": "rung-encrypted-pod.yaml"}[rung]
    pod = yaml.safe_load((REPO / "gitops/base/workloads" / file).read_text())
    default_image = json.loads(Path(env.get("RELEASE_MANIFEST") or REPO / "install/release-manifest.json").read_text())["images"]["ubiMinimal"]["ref"]
    image = env.get({"kbs": "RUNG_KBS_IMAGE", "signed": "RUNG_SIGNED_IMAGE", "encrypted": "RUNG_ENCRYPTED_IMAGE"}[rung]) or (default_image if rung == "kbs" else "")
    if not re.search(r"@sha256:[a-f0-9]{64}$", image):
        raise ValueError(f"RUNG_{rung.upper()}_IMAGE must be an immutable sha256 image reference")
    meta, spec = pod["metadata"], pod["spec"]
    meta["namespace"] = env.get("NS") or "coco-validation"
    meta["name"] = env.get("POD_NAME") or {"kbs": "rung-a-secret", "signed": "rung-signed", "encrypted": "rung-encrypted"}[rung]
    meta["labels"]["coco.openshift.io/managed-by"] = "rung-renderer"
    meta["annotations"]["io.katacontainers.config.hypervisor.cc_init_data"] = base64.b64encode(gzip.compress(raw, mtime=0)).decode()
    spec["containers"][0]["image"] = image
    spec["containers"][0]["imagePullPolicy"] = "Always"
    if env.get("PROOF_NODE"):
        spec["nodeSelector"] = {"kubernetes.io/hostname": env["PROOF_NODE"]}
    if rung == "kbs":
        path = env.get("ATTESTATION_RESOURCE_PATH", "attestation-status/status")
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", path):
            raise ValueError("ATTESTATION_RESOURCE_PATH must have exactly two safe path segments")
        spec["initContainers"][0].update(image=image, imagePullPolicy="Always", command=["/bin/sh", "-c",
            f"set -e\ncurl --connect-timeout 10 --max-time 60 -fsS -o /dev/null http://127.0.0.1:8006/cdh/resource/default/{path}\necho 'attestation: ok'\n"])
    if env.get("CONFIDENTIAL") == "0":
        spec.pop("runtimeClassName", None)
        meta["labels"].pop("coco-resource-default", None)
    return pod
