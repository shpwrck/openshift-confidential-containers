#!/usr/bin/env python3
"""External VCEK cache with source/content provenance; never accesses a cluster.

Certificate parsing and dates are checked here. Trustee still must verify the AMD
chain, hardware identity and quote TCB; this cache does not establish attestation.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import shutil
import sys
import tempfile


def digest(data):
    return hashlib.sha256(data).hexdigest()


def atomic(path, data):
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as handle:
        temp = Path(handle.name)
        handle.write(data)
    temp.replace(path)


def validate_certificate(data):
    from cryptography import x509
    cert = x509.load_der_x509_certificate(data)
    now = datetime.now(timezone.utc)
    if not cert.not_valid_before_utc <= now < cert.not_valid_after_utc:
        raise ValueError("VCEK certificate is expired or not yet valid")


def archive(directory):
    cert = directory / "vcek.der"
    if not cert.is_file():
        return
    dest = directory / "history" / digest(cert.read_bytes())
    dest.mkdir(parents=True, exist_ok=True)
    for filename in ("vcek.der", "vcek.source.json", "vcek.url", "report.bin"):
        src = directory / filename
        if src.is_file() and not (dest / filename).exists():
            shutil.copyfile(src, dest / filename)


def request(directory, kind, source):
    directory.mkdir(parents=True, exist_ok=True)
    data = source.read_bytes()
    if kind == "url":
        data = data.strip() + b"\n"
    source_hash = digest(data)
    name = "vcek.url" if kind == "url" else "report.bin"
    archive(directory)  # Preserve the last input before replacing it.
    atomic(directory / name, data)
    record = {"kind":kind, "sourceFile":name, "sourceSha256":source_hash}
    atomic(directory / "vcek.request.json", (json.dumps(record, sort_keys=True)+"\n").encode())
    return source_hash


def current_request(directory):
    req = json.loads((directory / "vcek.request.json").read_text())
    expected = {"url":"vcek.url", "report":"report.bin"}.get(req["kind"])
    if not expected or req["sourceFile"] != expected:
        raise ValueError("invalid VCEK source provenance")
    if digest((directory / expected).read_bytes()) != req["sourceSha256"]:
        raise ValueError("VCEK request input changed after collection")
    return req


def current(directory):
    req = current_request(directory)
    source = json.loads((directory / "vcek.source.json").read_text())
    data = (directory / "vcek.der").read_bytes()
    validate_certificate(data)
    if source.get("kind") != req["kind"] or source.get("sourceSha256") != req["sourceSha256"] or source.get("certificateSha256") != digest(data):
        raise ValueError("VCEK certificate does not match current URL/report provenance; refresh required")
    return source


def publish(directory, certificate, source_hash):
    req = current_request(directory)
    if req["sourceSha256"] != source_hash:
        raise ValueError("VCEK request changed during download; refusing to publish")
    data = certificate.read_bytes()
    validate_certificate(data)
    archive(directory)
    source = {**req, "certificateSha256":digest(data)}
    # If interrupted between these writes, current() detects a mismatch and fails.
    atomic(directory / "vcek.der", data)
    atomic(directory / "vcek.source.json", (json.dumps(source, sort_keys=True)+"\n").encode())
    archive(directory)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("request", "current", "publish"))
    parser.add_argument("directory", type=Path)
    parser.add_argument("--kind", choices=("url", "report"))
    parser.add_argument("--source", type=Path)
    parser.add_argument("--certificate", type=Path)
    parser.add_argument("--source-sha256")
    args = parser.parse_args()
    try:
        if args.action == "request":
            if args.kind is None or args.source is None:
                raise ValueError("request requires kind and source")
            print(request(args.directory, args.kind, args.source))
        elif args.action == "current":
            current(args.directory)
        else:
            if args.certificate is None or args.source_sha256 is None:
                raise ValueError("publish requires certificate and original source digest")
            publish(args.directory, args.certificate, args.source_sha256)
    except (OSError, ValueError, KeyError, TypeError, ImportError) as exc:
        print(f"ERROR: VCEK bundle: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
