#!/usr/bin/env python3
"""Install pinned offline-validation tools; no cluster or registry credentials needed."""
import hashlib
import io
import os
from pathlib import Path
import platform
import sys
import tarfile
import tempfile
from urllib.request import urlopen

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from proof_core import state_directory

# SHA-256 asset identities from the publishers' GitHub releases, checked 2026-10-20.
OPA_VERSION = "1.21.3"
KUSTOMIZE_VERSION = "5.8.3"
OPA = {
    "linux_amd64": ("opa_linux_amd64_static", "add7c9dcf56e1ce1538426a6ee595ea1cc7ee830bbedd4c23219825b02b19a79"),
    "linux_arm64": ("opa_linux_arm64_static", "45c8734a41436bf21d82453c2aa7b0ad47c150e8237310b8665e8b5a01305fc0"),
    "darwin_amd64": ("opa_darwin_amd64", "3ef285e7e2cf57e6cb05142c33002e07d6791580a4ac14bac0a4e0880dfe073d"),
    "darwin_arm64": ("opa_darwin_arm64_static", "ee96aae344f45dd63044be2bedcba6391ca78402760b204a747331f421db74fe"),
}
KUSTOMIZE = {
    "linux_amd64": "cb9e31198d3f63b44848bd0afc4c8efc56e6cfef9c93a4a39a211940e6decd61",
    "linux_arm64": "9867b76482cfc6d25b546abc1d2b5a32bd137505aba640649b4b378f64f6d68f",
    "darwin_amd64": "d08fb85846c3d977f0e2a66e7ff45f1b5264c294685e5e726e1a8bdfe0da8dee",
    "darwin_arm64": "4cbb08e209d8fff47cd60bfb6407daaf5ee699f9b9295849a1065024fac2d1ef",
}


def download(url, expected):
    with urlopen(url, timeout=120) as response:
        data = response.read()
    if hashlib.sha256(data).hexdigest() != expected:
        raise ValueError("publisher asset checksum mismatch: " + url)
    return data


def main():
    key = platform.system().lower() + "_" + {"x86_64": "amd64", "aarch64": "arm64", "arm64": "arm64"}.get(platform.machine(), platform.machine())
    if key not in OPA:
        sys.exit("Unsupported controller platform: " + key)
    root = Path(__file__).resolve().parent.parent
    dest = state_directory(root) / "dev-bin"
    dest.mkdir(exist_ok=True)
    asset, sha = OPA[key]
    opa = download(f"https://github.com/open-policy-agent/opa/releases/download/v{OPA_VERSION}/" + asset, sha)
    archive = download(f"https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize/v{KUSTOMIZE_VERSION}/kustomize_v{KUSTOMIZE_VERSION}_{key}.tar.gz", KUSTOMIZE[key])
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz") as tar:
        member = tar.getmember("kustomize")
        if not member.isfile():
            raise ValueError("kustomize archive has no regular binary")
        kustomize = tar.extractfile(member).read()
    for name, data in (("opa", opa), ("kustomize", kustomize)):
        fd, path = tempfile.mkstemp(dir=dest)
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
        os.chmod(path, 0o755)
        os.replace(path, dest / name)
    print(f"Installed OPA {OPA_VERSION} and Kustomize {KUSTOMIZE_VERSION}. Add {dest} to PATH.")


if __name__ == "__main__":
    main()
