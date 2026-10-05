"""Mirror completion/retry markers; execute only the production completion block."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]


class MirrorBootstrapTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='coco-mirror-bootstrap-')
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.mirror = self.base / 'mirror'
        self.mirror.mkdir()
        self.failed = self.mirror / 'MIRROR_FAILED'
        self.failed.write_text('earlier failed attempt\n')
        self.ca = self.mirror / 'quay/quay-rootCA/rootCA.pem'
        self.ca.parent.mkdir(parents=True)
        self.ca.write_text('public fixture CA\n')
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        # The actual node runs GNU install. Emulate only that command so the
        # fixture also works on macOS without running any bootstrap/download.
        install = self.bin / 'install'
        install.write_text('''#!/usr/bin/env python3
import os, pathlib, shutil, sys
args = sys.argv[1:]
assert args[:2] == ['-D', '-m0644'], args
if os.environ.get('FIXTURE_INSTALL_FAIL') == '1':
    raise SystemExit(7)
source, destination = map(pathlib.Path, args[2:])
destination.parent.mkdir(parents=True, exist_ok=True)
shutil.copyfile(source, destination)
destination.chmod(0o644)
''')
        install.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                        MIRROR_ROOT=str(self.mirror), QUAY_ROOT=str(self.mirror / 'quay'))

    def run_completion(self):
        document = yaml.safe_load((ROOT / 'infra/latitude/bastion/cloud-init/mirror-registry.yaml').read_text())
        script = next(item['content'] for item in document['write_files']
                      if item['path'] == '/usr/local/bin/bootstrap-mirror.sh')
        completion = script[script.index('CA_SRC='):]
        return subprocess.run(['bash', '-c', 'set -euo pipefail\n' + completion], env=self.env,
                              cwd=self.base, capture_output=True, text=True, timeout=10)

    def run_startup(self, failure):
        document = yaml.safe_load((ROOT / 'infra/latitude/bastion/cloud-init/mirror-registry.yaml').read_text())
        script = next(item['content'] for item in document['write_files']
                      if item['path'] == '/usr/local/bin/bootstrap-mirror.sh')
        # Execute the real initial guard/directory ordering and completion block;
        # omit installation, downloads, SSH setup and credential generation.
        bootstrap = script.split('# registry DNS name', 1)[0] + script[script.index('CA_SRC='):]
        bootstrap = bootstrap.replace('${mirror_root}', str(self.mirror))
        bootstrap = bootstrap.replace('/usr/local/bin/check-mirror-prerequisites.sh', str(self.bin / 'prerequisites'))
        (self.bin / 'bootstrap').write_text(bootstrap)
        (self.bin / 'bootstrap').chmod(0o755)
        for name, step in (('vlan', 'vlan'), ('ntp', 'ntp'), ('prerequisites', 'prerequisites'),
                           ('systemctl', 'services'), ('firewall-cmd', 'firewall')):
            path = self.bin / name
            path.write_text('''#!/usr/bin/env python3
import os, pathlib, sys
step = ''' + repr(step) + '''
with (pathlib.Path(os.environ['FIXTURE_STATE']) / 'startup-calls').open('a') as stream:
    stream.write(step + '\\n')
if os.environ.get('FIXTURE_FAIL_STEP') == step:
    raise SystemExit(17)
''')
            path.chmod(0o755)
        self.assertEqual(len(document['runcmd']), 1, 'dependent cloud-init steps must stop together on failure')
        command = document['runcmd'][0][2]
        command = command.replace('${mirror_root}', str(self.mirror))
        command = command.replace('/usr/local/bin/setup-rig-vlan.sh', str(self.bin / 'vlan'))
        command = command.replace('/usr/local/bin/setup-rig-ntp.sh', str(self.bin / 'ntp'))
        command = command.replace('/usr/local/bin/bootstrap-mirror.sh', str(self.bin / 'bootstrap'))
        command = command.replace('/var/log/mirror-bootstrap.log', str(self.base / 'bootstrap.log'))
        self.env.update(FIXTURE_STATE=str(self.base), FIXTURE_FAIL_STEP=failure)
        return subprocess.run(['bash', '-c', command], env=self.env, cwd=self.base,
                              capture_output=True, text=True, timeout=10)

    def test_successful_retry_clears_failure_only_after_installing_ca(self):
        result = self.run_completion()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.failed.exists())
        self.assertEqual((self.mirror / 'ca/rootCA.pem').read_text(), self.ca.read_text())
        self.assertRegex((self.mirror / 'MIRROR_READY').read_text(), r'^\d{4}-\d{2}-\d{2}T')

    def test_missing_ca_retains_failure_and_does_not_declare_ready(self):
        self.ca.unlink()
        result = self.run_completion()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('quay CA not found', result.stdout)
        self.assertTrue(self.failed.exists())
        self.assertFalse((self.mirror / 'MIRROR_READY').exists())

    def test_failed_ca_copy_retains_failure_and_does_not_declare_ready(self):
        self.env['FIXTURE_INSTALL_FAIL'] = '1'
        result = self.run_completion()
        self.assertEqual(result.returncode, 7)
        self.assertTrue(self.failed.exists())
        self.assertFalse((self.mirror / 'MIRROR_READY').exists())

    def test_first_boot_prerequisite_failure_records_failed_marker(self):
        shutil.rmtree(self.mirror)
        result = self.run_startup('prerequisites')
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.failed.exists(), result.stdout + result.stderr)
        self.assertEqual(self.mirror.stat().st_mode & 0o777, 0o700)
        self.assertFalse((self.mirror / 'MIRROR_READY').exists())
        self.assertIn('prerequisites', (self.base / 'startup-calls').read_text())

    def test_failed_network_setup_stops_before_registry_bootstrap(self):
        for failure in ('vlan', 'ntp', 'services', 'firewall'):
            with self.subTest(step=failure):
                shutil.rmtree(self.mirror)
                (self.base / 'startup-calls').unlink(missing_ok=True)
                result = self.run_startup(failure)
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(self.failed.exists(), result.stdout + result.stderr)
                self.assertFalse((self.mirror / 'MIRROR_READY').exists())
                self.assertNotIn('prerequisites', (self.base / 'startup-calls').read_text())

    def test_successful_startup_runs_network_before_bootstrap(self):
        result = self.run_startup('')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = (self.base / 'startup-calls').read_text().splitlines()
        self.assertEqual(calls, ['vlan', 'ntp', 'services', 'services', 'services', 'firewall', 'firewall', 'prerequisites'])
        self.assertFalse(self.failed.exists())
        self.assertTrue((self.mirror / 'MIRROR_READY').exists())


if __name__ == '__main__':
    unittest.main()
