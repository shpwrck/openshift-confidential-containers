"""Exercise both NTP configuration paths without changing the workstation clock."""
import copy
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
ROLE = ROOT / 'ansible/roles/dns_ntp'
CLOUD = ROOT / 'infra/latitude/bastion/cloud-init/mirror-registry.yaml'


class ChronyConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='coco-chrony-')
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        self.main = self.base / 'chrony.conf'
        self.original = '# Image settings must survive\npool time.example.invalid iburst\nmakestep 1.0 3\n'
        self.main.write_text(self.original)
        self.managed = self.base / 'chrony.d/rig.conf'
        self.effective = 'pool time.example.invalid iburst\nallow 192.168.66.0/24\nlocal stratum 10\n'
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                        FIXTURE_EFFECTIVE=self.effective)
        # Model chronyd's parse-and-exit interface; never run a daemon in CI.
        parser = self.bin / 'chronyd'
        parser.write_text('''#!/usr/bin/env python3
import os, sys
assert sys.argv[1:3] == ['-p', '-f'], sys.argv
assert len(sys.argv) == 4, sys.argv
raise_code = int(os.environ.get('FIXTURE_PARSE_RC', '0'))
if raise_code:
    raise SystemExit(raise_code)
print(os.environ['FIXTURE_EFFECTIVE'], end='')
''')
        parser.chmod(0o755)

    def cloud_script(self):
        document = yaml.safe_load(CLOUD.read_text())
        content = {item['path']: item['content'] for item in document['write_files']}
        self.managed.parent.mkdir(exist_ok=True)
        self.managed.write_text(content['/etc/chrony.d/rig.conf'].replace('${vlan_subnet}', '192.168.66.0/24'))
        script = content['/usr/local/bin/setup-rig-ntp.sh']
        # Scope filesystem writes to the fixture; retain actual shell guards/flow.
        return script.replace('/etc/chrony.conf', str(self.main)).replace(
            '/etc/chrony.d/rig.conf', str(self.managed)).replace(
            '/etc/chrony[.]d/rig[.]conf', str(self.managed).replace('.', '[.]')).replace(
            '${vlan_subnet}', '192.168.66.0/24')

    def test_cloud_init_includes_private_policy_once_and_preserves_image_sources(self):
        script = self.cloud_script()
        for _ in range(2):
            result = subprocess.run(['bash', '-c', script], env=self.env,
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.main.read_text().startswith(self.original))
        self.assertEqual(self.main.read_text().count('include ' + str(self.managed)), 1)
        self.assertEqual([line for line in self.managed.read_text().splitlines() if line.startswith('allow ')],
                         ['allow 192.168.66.0/24'])

    def test_cloud_init_fails_if_parser_rejects_or_omits_managed_policy(self):
        script = self.cloud_script()
        for override in ({'FIXTURE_PARSE_RC': '7'}, {'FIXTURE_EFFECTIVE': 'pool time.example.invalid iburst\n'}):
            with self.subTest(override=override):
                result = subprocess.run(['bash', '-c', script], env=dict(self.env, **override),
                                        capture_output=True, text=True, timeout=10)
                self.assertNotEqual(result.returncode, 0)

    def ansible_play(self):
        tasks = copy.deepcopy(yaml.safe_load((ROLE / 'tasks/chrony.yml').read_text()))
        tasks = [task for task in tasks if 'ansible.builtin.package' not in task]
        # All production mutations and parse assertions execute locally; only
        # package/service access, ownership and absolute paths are substituted.
        for task in tasks:
            task['become'] = False
            for module in ('ansible.builtin.file', 'ansible.builtin.template'):
                if module in task:
                    task[module].pop('owner', None)
                    task[module].pop('group', None)
            if 'ansible.builtin.template' in task:
                task['ansible.builtin.template']['src'] = str(ROLE / 'templates/chrony-rig.conf.j2')
        serialized = yaml.safe_dump(tasks, sort_keys=False)
        serialized = serialized.replace('/etc/chrony.conf', str(self.main)).replace(
            '/etc/chrony.d', str(self.managed.parent)).replace(
            '/etc/chrony[.]d/rig[.]conf', str(self.managed).replace('.', '[.]'))
        config = self.base / 'ansible.cfg'
        config.write_text('[defaults]\nstdout_callback=default\nretry_files_enabled=False\n')
        self.env.update(ANSIBLE_CONFIG=str(config), ANSIBLE_LOCAL_TEMP=str(self.base / 'local'),
                        ANSIBLE_REMOTE_TEMP=str(self.base / 'remote'))
        play = self.base / 'play.yml'
        play.write_text(yaml.safe_dump([{
            'hosts': 'localhost', 'connection': 'local', 'gather_facts': False,
            'vars': {'ansible_python_interpreter': sys.executable, 'vlan_cidr': '192.168.66.0/24'},
            'tasks': yaml.safe_load(serialized),
            'handlers': [{'name': 'Restart chronyd', 'ansible.builtin.copy': {
                'dest': str(self.base / 'restart-requested'), 'content': 'restart', 'mode': '0600'}}],
        }], sort_keys=False))
        return play

    @unittest.skipUnless(shutil.which('ansible-playbook'), 'requires local Ansible')
    def test_role_repairs_missing_include_idempotently_before_restart(self):
        play = self.ansible_play()
        for attempt in range(2):
            result = subprocess.run(['ansible-playbook', '-i', 'localhost,', str(play)],
                                    cwd=self.base, env=self.env, capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            if attempt:
                self.assertIn('changed=0', result.stdout)
        self.assertTrue((self.base / 'restart-requested').exists())
        self.assertTrue(self.main.read_text().startswith(self.original))
        self.assertEqual(self.main.read_text().count('include ' + str(self.managed)), 1)
        self.assertEqual([line for line in self.managed.read_text().splitlines() if line.startswith('allow ')],
                         ['allow 192.168.66.0/24'])

    @unittest.skipUnless(shutil.which('ansible-playbook'), 'requires local Ansible')
    def test_role_stops_before_restart_when_effective_policy_is_missing(self):
        play = self.ansible_play()
        self.env['FIXTURE_EFFECTIVE'] = 'pool time.example.invalid iburst\n'
        result = subprocess.run(['ansible-playbook', '-i', 'localhost,', str(play)],
                                cwd=self.base, env=self.env, capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn('Chrony did not load the managed private rig policy', result.stdout)
        self.assertFalse((self.base / 'restart-requested').exists())


if __name__ == '__main__':
    unittest.main()
