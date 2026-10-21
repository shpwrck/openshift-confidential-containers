"""Render the helper cloud-init the way the Cherry Servers guide does."""
from pathlib import Path
import shutil
import subprocess
import sys
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'scripts/render-helper-bootstrap.py'
TEMPLATE = ROOT / 'ansible/bootstrap/mirror-registry.yaml.j2'
SHA = '0123456789abcdef' * 4
URL = 'https://example.invalid/v2.0.12/mirror-registry.tar.gz'


def run(*extra):
    args = ['--ssh-user', 'root', '--vlan-vid', '1234', '--mirror-registry-url', URL,
            '--mirror-registry-sha256', SHA, *extra]
    return subprocess.run([sys.executable, str(SCRIPT), *args], capture_output=True, text=True, timeout=30)


class RenderHelperBootstrap(unittest.TestCase):
    def test_renders_checksum_and_network_into_the_scripts(self):
        result = run()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(result.stdout.startswith('#cloud-config\n'))
        document = yaml.safe_load(result.stdout)
        scripts = {item['path']: item['content'] for item in document['write_files']}
        bootstrap = scripts['/usr/local/bin/bootstrap-mirror.sh']
        self.assertIn(f'URL="{URL}"', bootstrap)
        self.assertIn(f'SHA="{SHA}"', bootstrap)
        vlan = scripts['/usr/local/bin/setup-rig-vlan.sh']
        self.assertIn('VID="1234"', vlan)
        self.assertIn('address1=192.168.66.10/24', vlan)
        self.assertIn('allow 192.168.66.0/24', scripts['/etc/chrony.d/rig.conf'])
        self.assertEqual(document['user']['name'], 'root')
        bash = shutil.which('bash')
        for path, content in scripts.items():
            if path.endswith('.sh'):
                with self.subTest(path=path):
                    check = subprocess.run([bash, '-n'], input=content, capture_output=True, text=True)
                    self.assertEqual(check.returncode, 0, check.stderr)

    def test_template_takes_inputs_from_jinja_not_unset_shell_variables(self):
        self.assertNotIn('${mirror_registry', TEMPLATE.read_text())

    def test_rejects_unpinned_or_inconsistent_inputs(self):
        cases = {
            'latest URL': ['--mirror-registry-url', 'https://example.invalid/latest/mirror-registry.tar.gz'],
            'plain HTTP': ['--mirror-registry-url', 'http://example.invalid/v2.0.12/mirror-registry.tar.gz'],
            'short checksum': ['--mirror-registry-sha256', 'abc'],
            'VLAN tag': ['--vlan-vid', '4095'],
            'helper outside VLAN': ['--helper-vlan-ip', '10.0.0.10'],
            'interface name': ['--vlan-parent-interface', 'eth0; reboot'],
        }
        for name, extra in cases.items():
            with self.subTest(name=name):
                result = run(*extra)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertEqual(result.stdout, '')


if __name__ == '__main__':
    unittest.main()
