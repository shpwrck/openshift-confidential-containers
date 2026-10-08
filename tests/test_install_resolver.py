"""The installer must resolve its private API before waiting for completion."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which('ansible-playbook'), 'requires local Ansible')
class InstallerResolverTests(unittest.TestCase):
    def test_fresh_wait_sees_private_api_mapping(self):
        with tempfile.TemporaryDirectory(prefix='coco-api-resolver-') as directory:
            base = Path(directory)
            hosts = base / 'hosts'
            hosts.write_text('127.0.0.1 localhost\n')
            tasks = yaml.safe_load((ROOT / 'ansible/roles/install_drive/tasks/main.yml').read_text())
            selected = []
            for task in tasks:
                if 'ansible.builtin.blockinfile' in task:
                    task['ansible.builtin.blockinfile']['path'] = str(hosts)
                    task['become'] = False
                    selected.append(task)
                elif task.get('name', '').startswith('Wait for the Agent-based'):
                    task['ansible.builtin.command'] = {'argv': [sys.executable, '-c',
                        'from pathlib import Path; import sys; '
                        'assert "10.1.2.11 api.fixture.example.internal" in Path(sys.argv[1]).read_text()',
                        str(hosts)]}
                    task.pop('async', None)
                    task.pop('poll', None)
                    task['become'] = False
                    selected.append(task)
            selected.append({'name': 'Installer wait used the private API mapping',
                             'ansible.builtin.assert': {'that': 'install_wait.rc == 0'}})
            play = base / 'play.yml'
            play.write_text(yaml.safe_dump([{'hosts': 'localhost', 'connection': 'local',
                'gather_facts': False, 'vars': {'install_mode': 'fresh',
                    'cluster_name': 'fixture', 'base_domain': 'example.internal',
                    'tool_path': os.environ['PATH'], 'ansible_python_interpreter': sys.executable,
                    'machines': [{'role': 'master', 'vlan_ip': '10.1.2.11'}]},
                'tasks': selected}], sort_keys=False))
            config = base / 'ansible.cfg'
            config.write_text('[defaults]\nstdout_callback=default\nretry_files_enabled=False\n')
            env = dict(os.environ, ANSIBLE_CONFIG=str(config),
                       ANSIBLE_LOCAL_TEMP=str(base/'local'), ANSIBLE_REMOTE_TEMP=str(base/'remote'))
            result = subprocess.run(['ansible-playbook', '-i', 'localhost,', str(play)],
                                    env=env, capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
