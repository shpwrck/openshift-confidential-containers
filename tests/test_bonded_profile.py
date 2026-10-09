"""Exercise real render guards/templates offline; no provider or remote host access."""
import copy
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
ROLE = ROOT / 'ansible/roles/render_configs'


@unittest.skipUnless(shutil.which('ansible-playbook'), 'requires local Ansible')
class RenderFixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='coco-private-profile-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.src = self.base / 'install/src'
        config = self.base / 'ansible.cfg'
        config.write_text('[defaults]\nstdout_callback=default\nretry_files_enabled=False\n')
        self.env = dict(os.environ, ANSIBLE_CONFIG=str(config),
                        ANSIBLE_LOCAL_TEMP=str(self.base / 'local'),
                        ANSIBLE_REMOTE_TEMP=str(self.base / 'remote'))
        (self.base / 'mirror-auth.json').write_text(json.dumps({'auths': {
            'mirror.fixture.invalid:8443': {'auth': 'Zml4dHVyZTpmaXh0dXJl'}}}))
        (self.base / 'ca.pem').write_text('FIXTURE PUBLIC CA\n')
        (self.base / 'controller.pub').write_text('ssh-ed25519 Zml4dHVyZQ== fixture\n')
        self.variables = yaml.safe_load((ROOT / 'ansible/group_vars/all.yml').read_text())
        self.variables.update({
            'ansible_python_interpreter': sys.executable,
            'cluster_name': 'fixture', 'base_domain': 'fixture.invalid',
            'node_server_id': '123', 'node_root_device': '/dev/disk/by-path/fixture',
            'node_parent_if': 'private0', 'node_parent_mac': '02:00:00:00:00:01',
            'node_external_if': 'public0', 'node_external_mac': '02:00:00:00:00:02',
            'bastion_public_ipv4': '198.51.100.9',
            'vlan_vid': 1234, 'boot_artifacts_token': 'f' * 32,
            'mirror_endpoint': 'mirror.fixture.invalid:8443', 'mirror_dns_name': 'mirror.fixture.invalid',
            'mirror_pull_secret': str(self.base / 'mirror-auth.json'),
            'mirror_ca_path': str(self.base / 'ca.pem'),
            'node_ssh_pubkey_src': str(self.base / 'controller.pub'),
            'node_ssh_pubkey_path': str(self.base / 'bastion.pub'),
            'install_src_dir': str(self.src), 'cluster_assets_dir': str(self.base / 'install/assets'),
        })
        self.tasks = copy.deepcopy(yaml.safe_load((ROLE / 'tasks/main.yml').read_text()))

        def localize(tasks):
            for task in tasks:
                # Real conditions/actions; only local fixture permissions/template location differ.
                task['become'] = False
                for action in ('ansible.builtin.file', 'ansible.builtin.template'):
                    if action in task:
                        task[action].pop('owner', None)
                        task[action].pop('group', None)
                if 'ansible.builtin.template' in task:
                    item = task['ansible.builtin.template']
                    item['src'] = str(ROLE / 'templates' / item['src'])
                for section in ('block', 'rescue', 'always'):
                    if section in task:
                        localize(task[section])
        localize(self.tasks)

    def run_render(self, overrides=None, success=True):
        play = self.base / 'play.yml'
        play.write_text(yaml.safe_dump([{'hosts': 'localhost', 'connection': 'local',
                                        'gather_facts': False, 'vars': self.variables,
                                        'tasks': self.tasks}]))
        extra = self.base / 'overrides.json'
        extra.write_text(json.dumps(overrides or {}))
        result = subprocess.run(['ansible-playbook', '-i', 'localhost,', str(play), '-e', '@' + str(extra)],
                                env=self.env, cwd=self.base, capture_output=True, text=True, timeout=60)
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0 if success else 2, output)
        if not success:
            self.assertFalse(self.src.exists(), 'invalid inputs created installer source directory')
            return output
        return tuple(yaml.safe_load((self.src / name).read_text())
                     for name in ('install-config.yaml', 'agent-config.yaml'))


@unittest.skipUnless(shutil.which("ansible-playbook"), "requires local Ansible")
class BondedProfileTests(unittest.TestCase):
    def setUp(self):
        self.fixture = RenderFixture()
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

    def test_removed_network_profile_cannot_create_installer_files(self):
        self.fixture.run_render({"machines": [self.machine], "network_profile": "public-routed-lab"}, success=False)

    def test_separate_public_nic_with_bond_rejects(self):
        self.machine["external_if"] = "eth2"
        self.fixture.run_render({"machines": [self.machine]}, success=False)
