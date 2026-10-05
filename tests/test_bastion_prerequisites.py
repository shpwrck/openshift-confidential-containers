"""Exercise the actual cloud-init prerequisite script without host or provider changes."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / 'infra/latitude/bastion/cloud-init/mirror-registry.yaml'


class BastionPrerequisites(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='coco-bastion-prerequisites-')
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        self.config = yaml.safe_load(CONFIG.read_text())
        scripts = {item['path']: item['content'] for item in self.config['write_files']}
        self.script = self.base / 'prerequisites.sh'
        self.script.write_text(scripts['/usr/local/bin/check-mirror-prerequisites.sh'])
        self.bash = shutil.which('bash')
        for name in ('podman', 'curl', 'tar', 'openssl', 'ssh', 'ssh-keygen', 'sshd'):
            self.executable(name, '#!/bin/sh\nexit 99\n')
        self.executable('hostname', '#!/bin/sh\n[ "$1" = "-f" ] || exit 2\nprintf "%s\\n" bastion.example.test\n')

    def executable(self, name, content):
        path = self.bin / name
        path.write_text(content)
        path.chmod(0o755)

    def run_check(self, expected):
        result = subprocess.run([self.bash, str(self.script)], cwd=self.base,
                                env=dict(os.environ, PATH=str(self.bin)),
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def test_valid_hostname_passes_without_running_install_commands(self):
        self.run_check(0)

    def test_missing_hostname_stops_with_actionable_error(self):
        (self.bin / 'hostname').unlink()
        self.assertIn('missing mirror-registry prerequisite: hostname', self.run_check(1))

    def test_unresolvable_or_empty_hostname_stops(self):
        for body in ('exit 1', 'exit 0'):
            with self.subTest(body=body):
                self.executable('hostname', '#!/bin/sh\n' + body + '\n')
                self.assertIn('hostname -f must succeed', self.run_check(1))

    def test_missing_ssh_server_stops_before_registry_work(self):
        (self.bin / 'sshd').unlink()
        self.assertIn('missing mirror-registry prerequisite: sshd', self.run_check(1))


if __name__ == '__main__':
    unittest.main()
