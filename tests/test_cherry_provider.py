"""Reject ownership and bonded-network drift before a Cherry reinstall."""
import copy
import importlib.util
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from lib.provider import server_identity

spec = importlib.util.spec_from_file_location("cherry_discovery", ROOT / "scripts/discover-node-macs.py")
discovery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(discovery)


class CherryProviderTests(unittest.TestCase):
    def setUp(self):
        self.server = {"id": 123, "hostname": "allocated-node", "project": {"id": 456},
                       "root_password": "MUST NOT LEAK", "ip_addresses": [
                           {"type": "primary-ip", "address_family": 4, "address": "192.0.2.11"},
                           {"type": "private-ip", "address_family": 4, "address": "10.1.2.11"}]}
        self.machine = {"name": "cluster-node", "server_id": "123", "provider_hostname": "allocated-node",
                        "provider_project_id": "456", "parent_if": "bond0", "parent_mac": "02:00:00:00:00:01",
                        "external_if": "", "vlan_ip": "10.1.2.11", "bond_mode": "802.3ad", "bond_ports": [
                            {"name": "eth0", "mac": "02:00:00:00:00:01"},
                            {"name": "eth1", "mac": "02:00:00:00:00:02"}]}
        self.raw = {"hostname": "allocated-node", "links": [
            {"ifname": "bond0", "address": "02:00:00:00:00:01", "linkinfo": {"info_kind": "bond"}},
            {"ifname": "eth0", "link_type": "ether", "master": "bond0", "address": "02:00:00:00:00:01"},
            {"ifname": "eth1", "link_type": "ether", "master": "bond0", "address": "02:00:00:00:00:01",
             "permaddr": "02:00:00:00:00:02"}], "addresses": [{"addr_info": [
                 {"local": "192.0.2.11"}, {"local": "10.1.2.11"}]}]}

    def capture(self):
        return discovery.capture_cherry([self.machine], [self.server], [self.raw])

    def test_capture_requires_one_node_server_and_pinned_observation(self):
        for machines, servers, observations in (([], [self.server], [self.raw]),
                                                ([self.machine], [], [self.raw]),
                                                ([self.machine], [self.server], []),
                                                ([self.machine], [self.server] * 2, [self.raw])):
            with self.subTest(counts=(len(machines), len(servers), len(observations))), self.assertRaises(ValueError):
                discovery.capture_cherry(machines, servers, observations)

    def test_removed_provider_is_not_normalized_as_cherry(self):
        with self.assertRaisesRegex(ValueError, 'Unsupported provider'):
            server_identity('latitude', self.server, '123', 'allocated-node', '456')

    def test_identity_output_excludes_credentials(self):
        result = server_identity("cherry", self.server, "123", "allocated-node", "456")
        self.assertNotIn("root_password", result)
        self.assertEqual(result["private_ipv4"], "10.1.2.11")

    def test_ownership_mismatches_reject(self):
        for args in [("999", "allocated-node", "456"), ("123", "other-node", "456"),
                     ("123", "allocated-node", "999"), ("123", "", "456")]:
            with self.subTest(args=args), self.assertRaises(ValueError):
                server_identity("cherry", self.server, *args)

    def test_pinned_observation_retains_physical_member_macs(self):
        cache = self.capture()
        self.assertEqual(cache["bindings"][0]["parent_mac"], "02:00:00:00:00:01")
        self.assertEqual(discovery.merge([self.machine], cache)[0]["bond_ports"], self.machine["bond_ports"])

    def test_wrong_pinned_hostname_and_member_mac_reject(self):
        for change in ("hostname", "port"):
            raw = copy.deepcopy(self.raw)
            if change == "hostname":
                self.raw["hostname"] = "different-server"
            else:
                self.raw["links"][2]["permaddr"] = "02:00:00:00:00:99"
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.capture()
            self.raw = raw

    def test_private_assignment_drift_rejects(self):
        self.machine["vlan_ip"] = "10.1.2.99"
        with self.assertRaisesRegex(ValueError, "private address"):
            self.capture()

    def test_duplicate_port_identities_reject(self):
        self.machine["bond_ports"][1] = copy.deepcopy(self.machine["bond_ports"][0])
        with self.assertRaisesRegex(ValueError, "distinct"):
            self.capture()
