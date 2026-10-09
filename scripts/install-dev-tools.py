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

# SHA-256 asset identities from the publishers' GitHub releases, checked 2026-10-05.
OPA = {
    "linux_amd64": ("opa_linux_amd64_static", "66fa66f3b730b2fb086003863428b382b2898d343adb4b5dfab5598b4d739eed"),
    "darwin_amd64": ("opa_darwin_amd64", "1122d0176604cd055d8f88b2b4d4019c469891d37e0bce9c1306e001e656ad2e"),
    "darwin_arm64": ("opa_darwin_arm64_static", "0134337a52bd255a2202eac4b4b85348fd4a77f94e8dab8ebcb2399ec018f4c0"),
}
KUSTOMIZE = {
    "linux_amd64": "ea375e7372f9aa029129d4b2d16c66b7750b7f1213c4f66f910d981c895818d8",
    "darwin_amd64": "4a0dff80c5644df6bc8f51b342842969004cb6ba5f94dddaabbea7483493273d",
    "darwin_arm64": "073e9d16d5a235e2ff83e62d6b76edb5d962adbc33be1e4860c4b3f1f39b33b9",
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
    opa = download("https://github.com/open-policy-agent/opa/releases/download/v1.9.0/" + asset, sha)
    archive = download(f"https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize/v5.7.1/kustomize_v5.7.1_{key}.tar.gz", KUSTOMIZE[key])
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
    print(f"Installed OPA 1.9.0 and Kustomize 5.7.1. Add {dest} to PATH.")


if __name__ == "__main__":
    main()
