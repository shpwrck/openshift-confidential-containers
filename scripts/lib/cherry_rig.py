"""Choose a Cherry Servers rig and describe it for Ansible.

Pure functions over Cherry API documents and what SSH reads on the servers;
scripts/order-rig.py does the API calls, Terraform runs and logins.
"""
import ipaddress
import json
import re

SLUG = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]*")
MAC = re.compile(r"(?:[0-9a-f]{2}:){5}[0-9a-f]{2}")


class RigError(ValueError):
    """The rig cannot be ordered or described as it is."""


def hourly_price(plan):
    prices = [p["price"] for p in plan.get("pricing", []) if p.get("unit") == "Hourly" and p.get("currency", "EUR") == "EUR"]
    return min(prices) if prices else None


def stock(plan, region):
    return sum(r.get("stock_qty") or 0 for r in plan.get("available_regions", []) if r.get("slug") == region)


def images(plan):
    return {s.get("image", {}).get("slug") for s in plan.get("softwares", [])}


def largest_disk_gb(plan):
    sizes = [d.get("size", 0) * (1000 if d.get("unit") == "TB" else 1) for d in plan.get("specs", {}).get("storage", [])]
    return max(sizes, default=0)


def _choice(plan, image, tested):
    return {"plan": plan["slug"], "image": image, "price": hourly_price(plan), "tested": tested,
            "cpu": plan.get("specs", {}).get("cpus", {}).get("name", "")}


# SEV-SNP needs an EPYC 7003, 8004, 9004 or 9005 series CPU (model numbers ending 3, 4, 4/5).
SNP_CPU = re.compile(r"EPYC\s+(?:7\d\d3|8\d\d4|9\d\d[45])[A-Z]?\b")


def rig_options(plans, tested, untested_nodes=False):
    """Every region with a tested node plan in stock, paired with the best helper there.

    Fully tested pairs come first, then the cheapest. Without a tested helper in stock,
    the cheapest bare-metal plan with enough disk is offered and marked untested. With
    untested_nodes, the node plans are instead the untested ones whose CPU supports SEV-SNP.
    """
    by_slug = {p["slug"]: p for p in plans if p.get("type") == "baremetal" and hourly_price(p) is not None}
    regions = sorted({r["slug"] for p in by_slug.values() for r in p.get("available_regions", [])})
    fallback = tested["untestedHelper"]
    if untested_nodes:
        known = {n["plan"] for n in tested["node"]}
        candidates = [(p, tested["untestedNode"]["image"], False) for p in by_slug.values()
                      if p["slug"] not in known and SNP_CPU.search(p.get("specs", {}).get("cpus", {}).get("name", ""))]
    else:
        candidates = [(by_slug[n["plan"]], n["image"], True) for n in tested["node"] if n["plan"] in by_slug]
    options = []
    for region in regions:
        nodes = [_choice(plan, image, is_tested) for plan, image, is_tested in candidates
                 if stock(plan, region) > 0 and image in images(plan)]
        if not nodes:
            continue
        node = min(nodes, key=lambda c: c["price"])

        def available(slug):
            # One server of the node's plan is already taken by the node.
            return stock(by_slug[slug], region) - (1 if slug == node["plan"] else 0) > 0
        helpers = [_choice(by_slug[h["plan"]], h["image"], True) for h in tested["helper"]
                   if h["plan"] in by_slug and available(h["plan"]) and h["image"] in images(by_slug[h["plan"]])]
        if not helpers:
            helpers = [_choice(p, fallback["image"], False) for p in by_slug.values()
                       if available(p["slug"]) and fallback["image"] in images(p)
                       and largest_disk_gb(p) >= fallback["minimumDiskGB"]]
        if not helpers:
            continue
        helper = min(helpers, key=lambda c: (c["price"], c["plan"]))
        options.append({"region": region, "node": node, "helper": helper,
                        "price": round(node["price"] + helper["price"], 3)})
    return sorted(options, key=lambda o: (not o["node"]["tested"], not o["helper"]["tested"], o["price"], o["region"]))


def key_material(public_key):
    """The key type and base64 body of an OpenSSH public key line, without the comment."""
    parts = (public_key or "").split()
    if len(parts) < 2 or not parts[0].startswith(("ssh-", "ecdsa-", "sk-")):
        raise RigError("not an OpenSSH public key")
    return parts[0], parts[1]


def matching_key_id(public_key, account_keys):
    """The ID of the account SSH key with the same key material, or None."""
    want = key_material(public_key)
    for key in account_keys:
        try:
            if key_material(key.get("key")) == want:
                return str(key["id"])
        except RigError:
            continue
    return None


def _hcl_string(value):
    if "${" in value or "%{" in value:
        raise RigError(f"cannot write {value!r} into a Terraform file")
    return json.dumps(value)


def render_tfvars(order):
    for field in ("region",):
        if not SLUG.fullmatch(order[field]):
            raise RigError(f"unexpected {field}: {order[field]!r}")
    for role in ("node", "helper"):
        for field in ("plan", "image"):
            if not SLUG.fullmatch(order[role][field]):
                raise RigError(f"unexpected {role} {field}: {order[role][field]!r}")
    if not re.fullmatch(r"[1-9][0-9]*", str(order["project_id"])):
        raise RigError("project_id must be a Cherry project number")
    lines = ["# Written by make order-rig; run it again to change the rig.",
             f"project_id   = {order['project_id']}",
             f"region       = {_hcl_string(order['region'])}",
             f"node_plan    = {_hcl_string(order['node']['plan'])}",
             f"node_image   = {_hcl_string(order['node']['image'])}",
             f"helper_plan  = {_hcl_string(order['helper']['plan'])}",
             f"helper_image = {_hcl_string(order['helper']['image'])}"]
    if order.get("ssh_key_id"):
        if not re.fullmatch(r"[1-9][0-9]*", str(order["ssh_key_id"])):
            raise RigError("ssh_key_id must be a Cherry key number")
        lines.append(f"ssh_key_ids  = [{_hcl_string(str(order['ssh_key_id']))}]")
    else:
        lines.append(f"ssh_public_key_file = {_hcl_string(order['ssh_public_key'])}")
    return "\n".join(lines) + "\n"


def parse_env_file(text):
    """KEY=value lines, as the helper bootstrap writes /etc/rig-network.env."""
    values = {}
    for line in text.splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, _, value = line.partition("=")
            values[key.strip()] = value.strip().strip('"')
    return values


def _mac(value):
    value = (value or "").lower()
    if not MAC.fullmatch(value) or int(value[:2], 16) & 1 or value == "00:00:00:00:00:00":
        raise RigError(f"not a usable MAC address: {value!r}")
    return value


def _addresses(observation):
    return {a.get("local"): i["ifname"] for i in observation["addresses"] for a in i.get("addr_info", [])}


def network_facts(observation, private_ipv4):
    """The VLAN interface carrying the node's private address, its tag, and the bond under it."""
    links = {link["ifname"]: link for link in observation["links"]}
    vlan_if = _addresses(observation).get(private_ipv4)
    if not vlan_if:
        raise RigError(f"no interface on the node has its private address {private_ipv4}")
    vlan = links.get(vlan_if, {})
    info = vlan.get("linkinfo", {})
    if info.get("info_kind") != "vlan" or not vlan.get("link"):
        raise RigError(f"{vlan_if} carries the private address but is not a VLAN interface")
    bond_name = vlan["link"]
    bond = links.get(bond_name, {})
    if bond.get("linkinfo", {}).get("info_kind") != "bond":
        raise RigError(f"the private VLAN sits on {bond_name}, which is not a bond")
    members = sorted((link for link in links.values() if link.get("master") == bond_name and link.get("link_type") == "ether"),
                     key=lambda link: link["ifname"])
    ports = [{"name": link["ifname"],
              "mac": _mac(link.get("permaddr") or link.get("linkinfo", {}).get("info_slave_data", {}).get("perm_hw_addr")
                          or link.get("address"))} for link in members]
    # Physical NICs outside the bond; the BMC's USB network device (enx...) is not one.
    loose = sorted(link["ifname"] for link in links.values()
                   if link.get("link_type") == "ether" and not link.get("master") and link["ifname"] != bond_name
                   and not link.get("linkinfo") and not link["ifname"].startswith("enx"))
    # A port that missed the bond can come back under another name after a reboot; its MAC stays.
    loose_macs = {name: (links[name].get("permaddr") or links[name].get("address") or "").lower() for name in loose}
    return {"vlan_if": vlan_if, "vlan_tag": str(info.get("info_data", {}).get("id", "")), "bond": bond_name,
            "bond_mac": _mac(bond.get("address")), "ports": ports, "loose_nics": loose, "loose_macs": loose_macs}


def _walk(device):
    yield device
    for child in device.get("children", []) or []:
        yield from _walk(child)


def disk_facts(observation):
    """Disks the installer can use, the one holding the original OS's /boot/efi first."""
    by_path = {}
    for link, target in sorted(observation.get("by_path", {}).items()):
        if "-part" not in link:
            by_path.setdefault(target, link)
    disks = []
    for device in observation["block"].get("blockdevices", []):
        if device.get("type") != "disk" or device.get("tran") == "usb" or int(device.get("size") or 0) < 100 * 10**9:
            continue
        path = device.get("path") or "/dev/" + device["name"]
        if path not in by_path:
            continue
        efi = any("/boot/efi" in (d.get("mountpoints") or []) for d in _walk(device))
        disks.append({"name": device["name"], "size_gb": int(device["size"]) // 10**9,
                      "model": (device.get("model") or "").strip(), "serial": (device.get("serial") or "").strip(),
                      "by_path": "/dev/disk/by-path/" + by_path[path], "holds_efi": efi})
    if not disks:
        raise RigError("the node shows no disk of 100 GB or more with a /dev/disk/by-path name")
    return sorted(disks, key=lambda d: (not d["holds_efi"], not d["name"].startswith("nvme"), d["by_path"]))


def _q(value):
    return json.dumps(str(value))


def render_rig_file(values, node, helper_env, access, token, written):
    """The complete rig file for a Terraform-ordered Cherry rig."""
    network = ipaddress.ip_network(values["private_network"], strict=True)
    for role in ("node", "helper"):
        if ipaddress.ip_address(values[f"{role}_private_ipv4"]) not in network:
            raise RigError(f"the {role}'s private address is outside {network}")
    tag = node["vlan_tag"]
    if not re.fullmatch(r"[1-9][0-9]{0,3}", tag):
        raise RigError(f"unexpected VLAN tag on the node: {tag!r}")
    if values.get("vlan_tag") and values["vlan_tag"] != tag:
        raise RigError(f"the node's VLAN tag {tag} differs from the {values['vlan_tag']} the Cherry API reports")
    if helper_env.get("VLAN_VID") != tag:
        raise RigError(f"the helper's VLAN tag {helper_env.get('VLAN_VID')!r} differs from the node's {tag}")
    if helper_env.get("BASTION_VLAN_IP") != values["helper_private_ipv4"]:
        raise RigError("the helper's VLAN address differs from the one the Cherry API reports")
    for key in ("VLAN_IFACE", "PUBLIC_IFACE"):
        if not re.fullmatch(r"[A-Za-z0-9_.:-]+", helper_env.get(key, "")):
            raise RigError(f"the helper's /etc/rig-network.env has no usable {key}")
    if len(node["ports"]) != 2:
        raise RigError(f"the node's bond has {len(node['ports'])} members; the install needs both")
    if not re.fullmatch(r"[0-9a-f]{32}", token):
        raise RigError("the boot token must be 32 hex characters")
    disk = access["disk"]
    others = [d for d in access["disks"] if d["by_path"] != disk["by_path"]]
    lines = [
        "---",
        f"# Written by make order-rig on {written} for Cherry server {values['node_id']}.",
        "# make order-rig keeps it up to date. Edit it only to pick another install disk",
        "# or to set an option at the end.",
        "",
        "# ---- Servers (from the Cherry Servers API) ---------------------------------",
        f"node_server_id: {_q(values['node_id'])}",
        f"node_provider_hostname: {_q(values['node_hostname'])}",
        f"node_provider_project_id: {_q(values['project_id'])}",
        f"bastion_ansible_host: {_q(values['helper_public_ipv4'])}",
        f"bastion_public_ipv4_override: {_q(values['helper_public_ipv4'])}",
        "",
        "# ---- Private VLAN -----------------------------------------------------------",
        f"node_vlan_ip: {_q(values['node_private_ipv4'])}",
        f"bastion_vlan_ip: {_q(values['helper_private_ipv4'])}",
        f"machine_network: {_q(network)}",
        f"vlan_cidr: {_q(network)}",
        f"vlan_prefix: {network.prefixlen}",
        f"# The tag on the wire: {node['vlan_if']} on the node, {helper_env['VLAN_IFACE']} on the helper.",
        f"vlan_vid_override: {_q(tag)}",
        "",
        "# ---- SSH access (host keys pinned when make order-rig first reached them) ---",
        'bastion_ssh_user: "root"',
        f"bastion_ssh_key: {_q(access['ssh_key'])}",
        'raw_node_ssh_user: "root"',
        f"raw_node_ssh_key: {_q(access['ssh_key'])}",
        f"private_link_known_hosts: {_q(access['known_hosts'])}",
        "",
        "# ---- Helper interfaces (from /etc/rig-network.env on the helper) ------------",
        f"bastion_private_if: {_q(helper_env['VLAN_IFACE'])}",
        f"bastion_external_if: {_q(helper_env['PUBLIC_IFACE'])}",
        "",
        "# ---- Node network (read on the node's original OS) --------------------------",
        f"node_parent_if: {_q(node['bond'])}",
        f"node_parent_mac: {_q(node['bond_mac'])}",
        "node_bond_ports:",
    ]
    for port in node["ports"]:
        lines += [f"  - name: {_q(port['name'])}", f"    mac: {_q(port['mac'])}"]
    lines += [
        'node_external_if: ""',
        'node_external_mac: ""',
        "",
        "# ---- Install disk: the install ERASES it ------------------------------------",
        "# Kernel names such as nvme0n1 are this boot's and can swap after a reboot;",
        "# the serials and the by-path names do not.",
        f"# {disk['name']}, {disk['size_gb']} GB, {disk['model'] or 'unknown model'}, serial {disk['serial'] or 'unknown'}"
        + ("; it holds the original OS's /boot/efi." if disk["holds_efi"] else "."),
    ]
    for other in others:
        lines.append(f"# Other disk: {other['name']}, {other['size_gb']} GB, serial {other['serial'] or 'unknown'}: {other['by_path']}")
    lines += [
        f"node_root_device: {_q(disk['by_path'])}",
        "",
        "# ---- Credentials (files outside the checkout) -------------------------------",
        f"pull_secret_src: {_q(access['pull_secret'])}",
        f"node_ssh_pubkey_src: {_q(access['ssh_key'] + '.pub')}",
        "# Random path segment for the boot files, new for each rig.",
        f"boot_artifacts_token: {_q(token)}",
        "",
        "# ---- Optional overrides -----------------------------------------------------",
        '# cluster_name: "sno-coco"',
        '# base_domain: "coco.lab.local"',
        "# public_console_enabled: false",
    ]
    return "\n".join(lines) + "\n"
