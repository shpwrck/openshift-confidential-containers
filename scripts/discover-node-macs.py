#!/usr/bin/env python3
"""Validate Latitude NIC identities and merge only MACs into current install inputs."""
import argparse
import json
import os
from pathlib import Path
import re
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
MAC = re.compile(r"(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}\Z")


class InvalidDiscovery(ValueError):
    """Discovery cannot safely identify the requested node interfaces."""


def mac(value):
    if not isinstance(value, str) or not MAC.fullmatch(value):
        raise InvalidDiscovery("MAC addresses must contain six colon-separated hexadecimal octets")
    if int(value[:2], 16) & 1 or value.lower() == "00:00:00:00:00:00":
        raise InvalidDiscovery("MAC addresses must be nonzero unicast addresses")
    return value.lower()


def check_machines(machines):
    if not isinstance(machines, list) or not machines:
        raise InvalidDiscovery("Provide a nonempty machines list")
    names, server_ids, addresses = set(), set(), set()
    for machine in machines:
        if not isinstance(machine, dict):
            raise InvalidDiscovery("Every machine must be an object")
        name, server_id = machine.get("name"), machine.get("server_id")
        if not isinstance(name, str) or not name.strip() or name in names:
            raise InvalidDiscovery("Every machine must have a unique nonempty name")
        if (not isinstance(server_id, str) or not re.fullmatch(r"sv_[A-Za-z0-9]+", server_id)
                or server_id in server_ids):
            raise InvalidDiscovery("Every machine must have a unique Latitude server_id (sv_...)")
        names.add(name)
        server_ids.add(server_id)
        if not isinstance(machine.get("parent_if"), str) or not machine["parent_if"].strip():
            raise InvalidDiscovery("Every machine must configure its internal parent_if")
        external_if = machine.get("external_if", "")
        if (not isinstance(external_if, str) or (external_if and not external_if.strip())
                or external_if == machine["parent_if"]):
            raise InvalidDiscovery("external_if must be empty or name an interface different from parent_if")
        if machine.get("external_mac") and not external_if:
            raise InvalidDiscovery("Public NIC has an external MAC but no external_if; configure its interface name")
        for field in ("parent_mac", "external_mac"):
            if machine.get(field, ""):
                address = mac(machine[field])
                if address in addresses:
                    raise InvalidDiscovery("Interface MAC addresses must be unique across all machines")
                addresses.add(address)
    return machines


def capture(machines, servers):
    check_machines(machines)
    if not isinstance(servers, list) or len(servers) != len(machines):
        raise InvalidDiscovery("The API response count must exactly match the requested machines")
    by_id = {}
    for server in servers:
        if not isinstance(server, dict) or not isinstance(server.get("data"), dict):
            raise InvalidDiscovery("The API must return one server object per request")
        data = server["data"]
        server_id = data.get("id")
        if not isinstance(server_id, str) or server_id in by_id:
            raise InvalidDiscovery("The API returned a missing or duplicate server identity")
        by_id[server_id] = data
    if set(by_id) != {machine["server_id"] for machine in machines}:
        raise InvalidDiscovery("The API server identities do not exactly match the requested machines")
    bindings = []
    for machine in machines:
        attributes = by_id[machine["server_id"]].get("attributes")
        if not isinstance(attributes, dict):
            raise InvalidDiscovery("The API server attributes are missing")
        interfaces = attributes.get("interfaces")
        if interfaces is None or interfaces == []:
            specs = attributes.get("specs", {})
            interfaces = specs.get("nics", []) if isinstance(specs, dict) else []
        if not isinstance(interfaces, list) or any(not isinstance(nic, dict) for nic in interfaces):
            raise InvalidDiscovery("The API interface list is malformed")
        binding = {key: machine[key] for key in ("name", "server_id")}
        for role, field, required in (("internal", "parent_mac", True),
                                      ("external", "external_mac", bool(machine.get("external_if")))):
            matches = [nic for nic in interfaces if nic.get("role") == role]
            if len(matches) > 1 or (required and len(matches) != 1):
                raise InvalidDiscovery(f"Expected exactly one {role}-role NIC for each configured interface")
            address = mac(matches[0].get("mac_address")) if matches else ""
            if machine.get(field) and mac(machine[field]) != address:
                raise InvalidDiscovery(f"Explicit {field} disagrees with the current API interface identity")
            binding[field] = address
        bindings.append(binding)
    result = {"version": 1, "bindings": bindings}
    merge(machines, result)  # Cross-node uniqueness and required public-NIC checks.
    return result


def merge(machines, cached=None):
    check_machines(machines)
    by_identity = {}
    if cached is not None:
        if (not isinstance(cached, dict) or set(cached) != {"version", "bindings"}
                or cached["version"] != 1 or not isinstance(cached["bindings"], list)):
            raise InvalidDiscovery("Invalid discovery cache; rerun discovery")
        for binding in cached["bindings"]:
            if not isinstance(binding, dict) or set(binding) != {"name", "server_id", "parent_mac", "external_mac"}:
                raise InvalidDiscovery("Discovery cache must contain only server identity and MAC bindings")
            if not all(isinstance(binding[key], str) for key in binding):
                raise InvalidDiscovery("Invalid discovery identity or MAC binding")
            identity = binding["name"], binding["server_id"]
            if identity in by_identity:
                raise InvalidDiscovery("Duplicate server identity in discovery cache")
            # Validate cached addresses even when an explicit current input takes precedence.
            mac(binding["parent_mac"])
            if binding["external_mac"]:
                mac(binding["external_mac"])
            by_identity[identity] = binding
        if set(by_identity) != {(machine["name"], machine["server_id"]) for machine in machines}:
            raise InvalidDiscovery("Discovery cache is for different machines; rerun discovery for current names/server IDs")
    result = []
    addresses = set()
    for machine in machines:
        merged = dict(machine)
        binding = by_identity.get((machine["name"], machine["server_id"]), {})
        for field in ("parent_mac", "external_mac"):
            value = machine.get(field) or binding.get(field) or ""
            if value:
                value = mac(value)
                if value in addresses:
                    raise InvalidDiscovery("Interface MAC addresses must be unique across all machines")
                addresses.add(value)
            merged[field] = value
        if not merged["parent_mac"]:
            raise InvalidDiscovery("Missing internal MAC; run discovery or provide the verified current parent_mac")
        if merged["external_mac"] and not merged.get("external_if"):
            raise InvalidDiscovery("Public NIC has an external MAC but no external_if; configure its interface name")
        if merged.get("external_if") and not merged["external_mac"]:
            raise InvalidDiscovery("Configured public NIC has no external MAC; run discovery or provide the verified current external_mac")
        result.append(merged)
    return result


def cache_path():
    default = Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state"))) / "openshift-confidential-containers"
    state = Path(os.environ.get("COCO_STATE_DIR", str(default))).expanduser().resolve()
    if state == ROOT or ROOT in state.parents or str(state).lower().startswith("/mnt/c/homelab/") or str(state).lower() == "/mnt/c/homelab":
        raise InvalidDiscovery("COCO_STATE_DIR must be outside the repository and Homelab")
    return state / "discovery/node-macs.json"


def write_cache(path, document):
    encoded = json.dumps(document, indent=2) + "\n"
    if path.is_file() and path.read_text() == encoded:
        return False
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor, temporary = tempfile.mkstemp(prefix=".node-macs-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w") as stream:
            stream.write(encoded)
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("begin", "capture", "merge"))
    args = parser.parse_args()
    try:
        payload = json.load(sys.stdin)
        if not isinstance(payload, dict):
            raise InvalidDiscovery("Input must be an object containing machines")
        machines = payload.get("machines")
        if args.mode == "begin":
            # A failed new discovery must not leave a usable previous binding.
            # Validate the requested identities and state location before removal.
            check_machines(machines)
            path = cache_path()
            changed = path.exists()
            path.unlink(missing_ok=True)
            print(json.dumps({"changed": changed}))
        elif args.mode == "capture":
            document = capture(machines, payload.get("servers"))
            changed = write_cache(cache_path(), document)
            print(json.dumps({"changed": changed, "bindings": document["bindings"]}))
        else:
            path = cache_path()
            cached = json.loads(path.read_text()) if path.exists() else None
            print(json.dumps(merge(machines, cached)))
    except (InvalidDiscovery, OSError, ValueError) as error:
        print(f"Discovery validation failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
