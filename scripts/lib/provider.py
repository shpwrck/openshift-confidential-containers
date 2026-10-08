"""Provider identity normalization; never returns credential-bearing fields."""
import ipaddress
import re


def server_identity(kind, document, server_id, expected_hostname="", project_id=""):
    if kind == "latitude":
        data = document.get("data", {})
        if data.get("id") != server_id:
            raise ValueError("Provider server identity mismatch")
        attrs = data.get("attributes", {})
        return {"id": server_id, "hostname": attrs.get("hostname", ""),
                "public_ipv4": attrs.get("primary_ipv4", ""),
                "interfaces": attrs.get("interfaces", attrs.get("specs", {}).get("nics", []))}
    if kind != "cherry" or not re.fullmatch(r"[1-9][0-9]*", str(server_id)):
        raise ValueError("Unsupported provider or invalid server ID")
    if type(document.get("id")) is not int or str(document["id"]) != str(server_id):
        raise ValueError("Provider server identity mismatch")
    if not expected_hostname or document.get("hostname") != expected_hostname:
        raise ValueError("Cherry hostname mismatch; provide the exact allocated hostname")
    if not project_id or str(document.get("project", {}).get("id")) != str(project_id):
        raise ValueError("Cherry project identity mismatch")
    addresses = document.get("ip_addresses", [])
    public = [x["address"] for x in addresses if x.get("type") == "primary-ip" and x.get("address_family") == 4]
    private = [x["address"] for x in addresses if x.get("type") == "private-ip" and x.get("address_family") == 4]
    if len(public) != 1 or len(private) != 1:
        raise ValueError("Expected exactly one public and private IPv4 address")
    if not ipaddress.IPv4Address(private[0]).is_private:
        raise ValueError("Provider private address is not private")
    return {"id": str(server_id), "hostname": expected_hostname,
            "public_ipv4": str(ipaddress.IPv4Address(public[0])), "private_ipv4": private[0],
            "project_id": str(project_id)}
