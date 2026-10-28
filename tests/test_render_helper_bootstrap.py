"""Render the helper cloud-init the way the Cherry Servers guide does, and run its VLAN step."""
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
SCRIPT = ROOT / 'scripts/render-helper-bootstrap.py'
TEMPLATE = ROOT / 'ansible/bootstrap/mirror-registry.yaml.j2'
SHA = '0123456789abcdef' * 4
URL = 'https://example.invalid/v2.0.12/mirror-registry.tar.gz'
# What a Cherry image shows: public address on the bond, private address on its tagged child.
CHERRY_LINKS = [{'ifname': 'bond0.2738', 'link': 'bond0',
                 'linkinfo': {'info_kind': 'vlan', 'info_data': {'protocol': '802.1Q', 'id': 2738}}}]
CHERRY_ADDRESSES = [{'ifname': 'bond0', 'addr_info': [{'local': '84.32.48.3', 'prefixlen': 25}]},
                    {'ifname': 'bond0.2738', 'addr_info': [{'local': '10.191.48.7', 'prefixlen': 24}]}]
FAKE_IP = '''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
if args == ['-j', '-d', 'link', 'show', 'type', 'vlan']:
    print(os.environ['FIXTURE_LINKS'])
elif args == ['-j', '-4', 'addr', 'show']:
    print(os.environ['FIXTURE_ADDRESSES'])
elif args == ['-j', 'route', 'get', '1.1.1.1']:
    print(json.dumps([{'dst': '1.1.1.1', 'dev': 'bond0'}]))
else:
    raise SystemExit('unexpected ip call: ' + ' '.join(args))
'''


def render(*extra, cloud_config=True):
    args = ['--mirror-registry-url', URL, '--mirror-registry-sha256', SHA, *extra]
    if cloud_config:
        args = ['--cloud-config', '--ssh-user', 'root', *args]
    return subprocess.run([sys.executable, str(SCRIPT), *args], capture_output=True, text=True, timeout=30)


def scripts_of(text):
    return {item['path']: item['content'] for item in yaml.safe_load(text)['write_files']}


class RenderHelperBootstrap(unittest.TestCase):
    def test_renders_checksum_and_explicit_network_into_the_scripts(self):
        result = render('--vlan-vid', '1234')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(result.stdout.startswith('#cloud-config\n'))
        self.assertEqual(yaml.safe_load(result.stdout)['user']['name'], 'root')
        scripts = scripts_of(result.stdout)
        bootstrap = scripts['/usr/local/bin/bootstrap-mirror.sh']
        self.assertIn(f'URL="{URL}"', bootstrap)
        self.assertIn(f'SHA="{SHA}"', bootstrap)
        vlan = scripts['/usr/local/bin/setup-rig-vlan.sh']
        for line in ('VID="1234"', 'ADDRESS="192.168.66.10"', 'PREFIX="24"', 'SUBNET="192.168.66.0/24"'):
            self.assertIn(line, vlan)

    def test_default_render_adopts_the_provider_vlan_and_passes_bash_syntax(self):
        result = render()
        self.assertEqual(result.returncode, 0, result.stderr)
        scripts = scripts_of(result.stdout)
        self.assertIn('VID="auto"', scripts['/usr/local/bin/setup-rig-vlan.sh'])
        bash = shutil.which('bash')
        for path, content in scripts.items():
            if path.endswith('.sh'):
                with self.subTest(path=path):
                    check = subprocess.run([bash, '-n'], input=content, capture_output=True, text=True)
                    self.assertEqual(check.returncode, 0, check.stderr)

    def test_template_takes_inputs_from_jinja_not_unset_shell_variables(self):
        self.assertNotIn('${mirror_registry', TEMPLATE.read_text())

    def test_without_flags_the_release_manifest_pin_is_used(self):
        pin = json.loads((ROOT / 'install/release-manifest.json').read_text())['tools']['mirrorRegistry']
        result = subprocess.run([sys.executable, str(SCRIPT), '--cloud-config'], capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        bootstrap = scripts_of(result.stdout)['/usr/local/bin/bootstrap-mirror.sh']
        self.assertIn(f'URL="{pin["url"]}"', bootstrap)
        self.assertIn(f'SHA="{pin["sha256"]}"', bootstrap)
        # An archive without its checksum, or the reverse, is refused.
        half = subprocess.run([sys.executable, str(SCRIPT), '--mirror-registry-url', URL],
                              capture_output=True, text=True, timeout=30)
        self.assertEqual(half.returncode, 2, half.stderr)
        self.assertEqual(half.stdout, '')

    def test_rejects_unpinned_or_inconsistent_inputs(self):
        cases = {
            'latest URL': ['--mirror-registry-url', 'https://example.invalid/latest/mirror-registry.tar.gz'],
            'plain HTTP': ['--mirror-registry-url', 'http://example.invalid/v2.0.12/mirror-registry.tar.gz'],
            'short checksum': ['--mirror-registry-sha256', 'abc'],
            'VLAN tag': ['--vlan-vid', '4095'],
            'VLAN word': ['--vlan-vid', 'tagged'],
            'helper outside VLAN': ['--vlan-vid', '1234', '--helper-vlan-ip', '10.0.0.10'],
            'interface name': ['--vlan-parent-interface', 'eth0; reboot'],
        }
        for name, extra in cases.items():
            with self.subTest(name=name):
                result = render(*extra)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertEqual(result.stdout, '')


class HelperBootstrapScript(unittest.TestCase):
    """The default output: the same bootstrap as one root script, run over SSH (Cherry ignores its setup with user data)."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='coco-helper-script-')
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.bin = self.base / 'stubs'
        self.bin.mkdir()
        self.calls = self.base / 'calls'
        # dnf and the runcmd's bash only record their arguments; id reports root.
        for name in ('dnf', 'bash'):
            (self.bin / name).write_text(f'#!/bin/sh\nprintf "%s\\0" {name} "$@" >> "$FIXTURE_CALLS"\nprintf "\\036" >> "$FIXTURE_CALLS"\n')
        (self.bin / 'id').write_text('#!/bin/sh\necho 0\n')
        for name in ('dnf', 'bash', 'id'):
            (self.bin / name).chmod(0o755)

    def test_script_writes_the_same_files_and_runs_the_same_commands_as_cloud_init(self):
        cloud = yaml.safe_load(render().stdout)
        result = render(cloud_config=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(result.stdout.startswith('#!/bin/bash\n'))
        target = self.base / 'root'
        script = result.stdout.replace('/usr/local/bin', f'{target}/usr/local/bin')
        env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'], FIXTURE_CALLS=str(self.calls))
        run = subprocess.run([shutil.which('bash'), '-c', script], env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        for item in cloud['write_files']:
            with self.subTest(path=item['path']):
                written = Path(f"{target}{item['path']}")
                self.assertEqual(written.read_text(), item['content'])
                self.assertEqual(oct(written.stat().st_mode & 0o777), oct(int(item['permissions'], 8)))
        calls = [call.split('\0')[:-1] for call in self.calls.read_text().split('\036')[:-1]]
        self.assertEqual(calls[0], ['dnf', '-y', 'install', *cloud['packages']])
        expected_runcmd = [[part.replace('/usr/local/bin', f'{target}/usr/local/bin') for part in command]
                           for command in cloud['runcmd']]
        self.assertEqual(calls[1:], expected_runcmd)

    def test_script_ignores_the_ssh_user(self):
        self.assertEqual(render('--ssh-user', 'someone', cloud_config=False).stdout, render(cloud_config=False).stdout)


class HelperVlanSetup(unittest.TestCase):
    """Run the rendered setup-rig-vlan.sh against fake ip/nmcli and a scratch /etc."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='coco-helper-vlan-')
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.etc = self.base / 'etc'
        for directory in ('NetworkManager/system-connections', 'dnsmasq.d'):
            (self.etc / directory).mkdir(parents=True)
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        (self.bin / 'ip').write_text(FAKE_IP)
        (self.bin / 'nmcli').write_text('#!/bin/sh\necho "$*" >> "$FIXTURE_NMCLI_LOG"\n')
        for name in ('ip', 'nmcli'):
            (self.bin / name).chmod(0o755)
        self.nmcli_log = self.base / 'nmcli.log'
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                        FIXTURE_LINKS=json.dumps(CHERRY_LINKS), FIXTURE_ADDRESSES=json.dumps(CHERRY_ADDRESSES),
                        FIXTURE_NMCLI_LOG=str(self.nmcli_log))

    def run_setup(self, *extra):
        rendered = render(*extra)
        self.assertEqual(rendered.returncode, 0, rendered.stderr)
        script = scripts_of(rendered.stdout)['/usr/local/bin/setup-rig-vlan.sh'].replace('/etc/', f'{self.etc}/')
        return subprocess.run(['bash', '-c', script], env=self.env, capture_output=True, text=True, timeout=30)

    def network_env(self):
        lines = (self.etc / 'rig-network.env').read_text().splitlines()
        return dict(line.split('=', 1) for line in lines)

    def test_auto_adopts_the_single_private_vlan_without_touching_networkmanager(self):
        result = self.run_setup()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.network_env(), {
            'VLAN_IFACE': 'bond0.2738', 'VLAN_PARENT': 'bond0', 'VLAN_VID': '2738',
            'BASTION_VLAN_IP': '10.191.48.7', 'VLAN_PREFIX': '24', 'VLAN_SUBNET': '10.191.48.0/24',
            'PUBLIC_IFACE': 'bond0'})
        self.assertEqual((self.etc / 'dnsmasq.d/rig.conf').read_text(), 'address=/mirror.rig.local/10.191.48.7\n')
        self.assertIn('interface=bond0.2738\n', (self.etc / 'dnsmasq.d/rig-iface.conf').read_text())
        self.assertFalse((self.etc / 'NetworkManager/system-connections/rigvlan.nmconnection').exists())
        self.assertFalse(self.nmcli_log.exists())

    def test_auto_stops_unless_exactly_one_private_vlan_address_exists(self):
        second = {'ifname': 'bond0.99', 'link': 'bond0',
                  'linkinfo': {'info_kind': 'vlan', 'info_data': {'protocol': '802.1Q', 'id': 99}}}
        cases = {
            'none': ([], CHERRY_ADDRESSES),
            'public only': (CHERRY_LINKS, CHERRY_ADDRESSES[:1]),
            'two': (CHERRY_LINKS + [second],
                    CHERRY_ADDRESSES + [{'ifname': 'bond0.99', 'addr_info': [{'local': '10.9.9.9', 'prefixlen': 24}]}]),
        }
        for name, (links, addresses) in cases.items():
            with self.subTest(name=name):
                self.env.update(FIXTURE_LINKS=json.dumps(links), FIXTURE_ADDRESSES=json.dumps(addresses))
                result = self.run_setup()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('expected one private VLAN address', result.stderr)
                self.assertFalse((self.etc / 'rig-network.env').exists())

    def test_explicit_tag_creates_the_static_connection(self):
        result = self.run_setup('--vlan-vid', '1234', '--vlan-parent-interface', 'bond0')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        connection = (self.etc / 'NetworkManager/system-connections/rigvlan.nmconnection').read_text()
        for line in ('interface-name=bond0.1234', 'parent=bond0', 'id=1234', 'address1=192.168.66.10/24'):
            self.assertIn(line + '\n', connection)
        self.assertEqual(self.nmcli_log.read_text(), 'connection reload\nconnection up rigvlan\n')
        self.assertEqual(self.network_env()['VLAN_SUBNET'], '192.168.66.0/24')
        self.assertEqual((self.etc / 'dnsmasq.d/rig.conf').read_text(), 'address=/mirror.rig.local/192.168.66.10\n')


if __name__ == '__main__':
    unittest.main()
