"""Render the actual bonded private topology, including fail-closed input checks."""
import shutil
import unittest
import test_public_routed_profile as fixtures


@unittest.skipUnless(shutil.which("ansible-playbook"), "requires local Ansible")
class BondedProfileTests(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.PublicRoutedProfileTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.machine = {"name": "fixture-node", "server_id": "123", "role": "master",
                        "root_device": "/dev/disk/by-path/fixture", "vlan_ip": "192.168.66.11",
                        "parent_if": "bond0", "parent_mac": "02:00:00:00:00:01", "external_if": "",
                        "bond_mode": "802.3ad", "bond_ports": [
                            {"name": "eth0", "mac": "02:00:00:00:00:01"},
                            {"name": "eth1", "mac": "02:00:00:00:00:02"}]}

    def test_private_bond_has_no_public_address_or_dhcp(self):
        _, agent = self.fixture.run_render({"machines": [self.machine]})
        host = agent["hosts"][0]
        self.assertEqual([x["name"] for x in host["interfaces"]], ["eth0", "eth1"])
        interfaces = host["networkConfig"]["interfaces"]
        self.assertEqual([x["name"] for x in interfaces], ["bond0", "eth0", "eth1", "bond0.1234"])
        self.assertEqual(interfaces[0]["type"], "bond")
        self.assertEqual(interfaces[0]["link-aggregation"]["port"], ["eth0", "eth1"])
        self.assertTrue(all(not x["ipv4"]["enabled"] for x in interfaces[:3]))
        self.assertTrue(all(not x["ipv6"]["enabled"] for x in interfaces))
        self.assertEqual(interfaces[3]["ipv4"]["address"], [{"ip": "192.168.66.11", "prefix-length": 24}])

    def test_duplicate_member_mac_fails_before_render(self):
        self.machine["bond_ports"][1]["mac"] = self.machine["parent_mac"]
        self.fixture.run_render({"machines": [self.machine]}, success=False)

    def test_separate_public_nic_with_bond_rejects(self):
        self.machine["external_if"] = "eth2"
        self.fixture.run_render({"machines": [self.machine]}, success=False)
