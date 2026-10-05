"""Exercise bastion startup and network gates locally; no remote hosts or providers."""
import copy
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which('ansible-playbook'), 'requires local Ansible')
class BastionNetworkTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='coco-bastion-network-')
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        self.config = self.base / 'ansible.cfg'
        self.config.write_text('[defaults]\nstdout_callback=default\nretry_files_enabled=False\n')
        self.env = dict(os.environ, ANSIBLE_CONFIG=str(self.config),
                        ANSIBLE_LOCAL_TEMP=str(self.base / 'local'),
                        ANSIBLE_REMOTE_TEMP=str(self.base / 'remote'),
                        PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                        FIXTURE_STATE=str(self.base))

    def run_play(self, play, expected=0):
        play['hosts'] = 'localhost'
        play.setdefault('connection', 'local')
        play.setdefault('gather_facts', False)
        play.setdefault('vars', {})['ansible_python_interpreter'] = sys.executable
        path = self.base / 'test.yml'
        path.write_text(yaml.safe_dump([play], sort_keys=False))
        result = subprocess.run(['ansible-playbook', '-i', 'localhost,', str(path)],
                                env=self.env, cwd=self.base, capture_output=True,
                                text=True, timeout=60)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def executable(self, name, body):
        path = self.bin / name
        path.write_text(body)
        path.chmod(0o755)

    def test_fresh_bastion_retries_connection_before_gathering_facts(self):
        phase = next(play for play in yaml.safe_load((ROOT / 'ansible/playbooks/site.yml').read_text())
                     if play.get('name', '').startswith('Phase A'))
        # A local connection plugin fails the first command like a cold SSH host.
        # Retaining production gather_facts catches setup being scheduled too early.
        plugins = self.base / 'connection_plugins'
        plugins.mkdir()
        (plugins / 'cold_fixture.py').write_text('''
import os
from pathlib import Path
from ansible.errors import AnsibleConnectionFailure
from ansible.plugins.connection.local import Connection as LocalConnection

class Connection(LocalConnection):
    transport = 'cold_fixture'
    def exec_command(self, cmd, in_data=None, sudoable=True):
        marker = Path(os.environ['FIXTURE_STATE']) / 'connection-attempted'
        if not marker.exists():
            marker.touch()
            raise AnsibleConnectionFailure('fixture cold host: SSH not ready')
        return super().exec_command(cmd, in_data=in_data, sudoable=sudoable)
''')
        self.env['ANSIBLE_CONNECTION_PLUGINS'] = str(plugins)
        startup = []
        for task in phase['pre_tasks']:
            startup.append(copy.deepcopy(task))
            if 'ansible.builtin.setup' in task:
                # Exercise real setup after the connection retry, but only collect
                # the OS-family fact asserted below. Full workstation discovery can
                # block on unrelated hardware/network probes on macOS runners.
                startup[-1]['ansible.builtin.setup'] = {
                    'gather_subset': ['!all', '!min', 'distribution'],
                    'gather_timeout': 5,
                }
                break
        self.assertTrue(any('ansible.builtin.setup' in task for task in startup))
        output = self.run_play({
            'connection': 'cold_fixture', 'gather_facts': phase['gather_facts'],
            'vars': {'bastion_ssh_wait_timeout': 15}, 'pre_tasks': startup,
            'tasks': [{'ansible.builtin.assert': {'that': 'ansible_facts.os_family is defined'}}],
        })
        self.assertTrue((self.base / 'connection-attempted').exists())
        self.assertLess(output.index('Wait for the bastion to accept SSH'),
                        output.index('Gather bastion facts after SSH is ready'))
        self.assertNotIn('TASK [Gathering Facts]', output)

    def dns_tasks(self):
        tasks = yaml.safe_load((ROOT / 'ansible/roles/dns_ntp/tasks/main.yml').read_text())
        self.assertIn('bind-utils', tasks[0]['ansible.builtin.package']['name'])
        start = next(i for i, task in enumerate(tasks)
                     if task['name'] == 'Query the mirror and cluster names through the VLAN DNS server')
        tasks = copy.deepcopy(tasks[start:])
        for task in tasks:
            task['become'] = False
        return tasks

    def test_firmware_acknowledgement_still_fails_closed_without_exact_token(self):
        phase = next(play for play in yaml.safe_load((ROOT / 'ansible/playbooks/site.yml').read_text())
                     if 'bios' in play.get('tags', []))
        gate = copy.deepcopy(next(task for task in phase['tasks']
                                  if 'ansible.builtin.assert' in task))
        sentinel = self.base / 'installation-started'
        for variables, expected in (({}, 2), ({'bios_ack': {'user_input': ''}}, 2),
                                    ({'bios_ack': {'user_input': 'yes'}}, 2),
                                    ({'bios_ack': {'user_input': 'SNP-SET'}}, 0),
                                    ({'skip_bios_pause': True}, 0)):
            with self.subTest(variables=variables):
                sentinel.unlink(missing_ok=True)
                self.run_play({'vars': variables, 'tasks': [gate, {
                    'ansible.builtin.copy': {'dest': str(sentinel), 'content': 'started',
                                            'mode': '0600'}}]}, expected=expected)
                self.assertEqual(sentinel.exists(), expected == 0)

    def test_bootstrap_marker_wait_uses_privilege_for_protected_directory(self):
        phase = next(play for play in yaml.safe_load((ROOT / 'ansible/playbooks/site.yml').read_text())
                     if play.get('name', '').startswith('Phase A'))
        wait = copy.deepcopy(next(task for task in phase['pre_tasks']
                                  if task['name'] == 'Wait for the first-boot mirror bootstrap to settle'))
        gate = copy.deepcopy(next(task for task in phase['pre_tasks']
                                  if task['name'] == 'Fail closed if the mirror bootstrap did not succeed'))
        protected = self.base / 'protected-mirror'
        protected.mkdir(mode=0o700)
        (protected / 'MIRROR_READY').write_text('fixture ready\n')
        (protected / 'MIRROR_READY').chmod(0o600)
        plugins = self.base / 'become_plugins'
        plugins.mkdir()
        (plugins / 'fixture_privilege.py').write_text('''
from ansible.plugins.become import BecomeBase

class BecomeModule(BecomeBase):
    name = 'fixture_privilege'
    def build_become_command(self, cmd, shell):
        super().build_become_command(cmd, shell)
        return 'env COCO_FIXTURE_PRIVILEGED=1 ' + self._build_success_command(cmd, shell)
''')
        self.env['ANSIBLE_BECOME_PLUGINS'] = str(plugins)
        # Simulate the rocky login's file-test behavior: inaccessible root-owned
        # markers look absent. A fixture become plugin grants access without sudo
        # or user/permission changes on the test machine. The marker script itself
        # is unchanged and reads real files once that privilege is present.
        self.executable('marker-shell', '''#!/bin/bash
if [[ "${COCO_FIXTURE_PRIVILEGED:-}" != 1 ]]; then
  echo PENDING
  exit 0
fi
exec /bin/bash "$@"
''')
        wait['args']['executable'] = str(self.bin / 'marker-shell')
        sentinel = self.base / 'preparation-started'
        tasks = [wait, gate, {'ansible.builtin.copy': {
            'dest': str(sentinel), 'content': 'started', 'mode': '0600'}}]
        play = {'become_method': 'fixture_privilege',
                'vars': {'mirror_root': str(protected), 'mirror_bootstrap_retries': 1,
                         'mirror_bootstrap_delay': 0}, 'tasks': tasks}
        self.run_play(play)
        self.assertTrue(sentinel.exists())
        # Removing privilege reproduces the original endless PENDING behavior,
        # shortened to one retry here, and must prevent all later preparation.
        sentinel.unlink()
        wait['become'] = False
        self.run_play(play, expected=2)
        self.assertFalse(sentinel.exists())

    def run_dns(self, mode='valid', expected=0):
        self.env['FIXTURE_DNS_MODE'] = mode
        self.executable('dig', '''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
assert args[0] == '@192.0.2.10', args
assert args[2:] == ['A', '+short', '+time=2', '+tries=1'], args
with (pathlib.Path(os.environ['FIXTURE_STATE']) / 'dns-calls').open('a') as stream:
    stream.write(json.dumps(args) + '\\n')
mode = os.environ['FIXTURE_DNS_MODE']
if mode == 'unreachable':
    raise SystemExit(9)
if mode == 'wrong-api' and args[1].startswith('api.'):
    print('192.0.2.99')
else:
    print('192.0.2.10' if args[1] == 'mirror.fixture.invalid' else '192.0.2.11')
''')
        # A resolver using NSS instead of the selected DNS server would appear healthy.
        self.executable('getent', '#!/bin/sh\necho "192.0.2.10 mirror.fixture.invalid"\n')
        return self.run_play({'vars': {'bastion_vlan_ip': '192.0.2.10', 'node_vlan_ip': '192.0.2.11',
                                      'mirror_dns_name': 'mirror.fixture.invalid', 'cluster_name': 'sno',
                                      'base_domain': 'fixture.invalid',
                                      'dnsmasq_verify_retries': 1, 'dnsmasq_verify_delay': 0},
                              'tasks': self.dns_tasks()}, expected)

    def test_vlan_dns_checks_mirror_api_internal_api_and_apps(self):
        self.run_dns()
        calls = [json.loads(line) for line in (self.base / 'dns-calls').read_text().splitlines()]
        self.assertEqual([args[1] for args in calls], [
            'mirror.fixture.invalid', 'api.sno.fixture.invalid', 'api-int.sno.fixture.invalid',
            'coco-dns-probe.apps.sno.fixture.invalid'])

    def test_wrong_api_dns_answer_blocks_preparation(self):
        self.run_dns('wrong-api', expected=2)

    def test_unreachable_vlan_dns_fails_despite_healthy_local_resolution(self):
        self.run_dns('unreachable', expected=2)

    def test_pxe_gathers_fresh_service_facts_before_firewall_gate(self):
        tasks = yaml.safe_load((ROOT / 'ansible/roles/pxe_serve/tasks/main.yml').read_text())[1]['block']
        start = next(i for i, task in enumerate(tasks) if 'ansible.builtin.service_facts' in task)
        end = next(i for i, task in enumerate(tasks)
                   if task['name'] == 'Open the boot-artifacts port in firewalld (if active)')
        self.assertLess(start, end)
        selected = copy.deepcopy(tasks[start:end + 1])
        # Mock the remote service discovery result; retain the real firewalld task,
        # condition and loop. Each play starts without cached service facts.
        selected[0].pop('ansible.builtin.service_facts')
        selected[0]['ansible.builtin.set_fact'] = {
            'ansible_facts': {'services': {'firewalld.service': {'state': '{{ fixture_firewalld_state }}'}}}}
        for task in selected:
            task['become'] = False
        self.executable('firewall-cmd', '''#!/usr/bin/env python3
import json, os, pathlib, sys
with (pathlib.Path(os.environ['FIXTURE_STATE']) / 'firewall-calls').open('a') as stream:
    stream.write(json.dumps(sys.argv[1:]) + '\\n')
if os.environ.get('FIXTURE_FIREWALL_FAIL') == '1':
    raise SystemExit(7)
print('success')
''')
        for state, fail in (('running', False), ('stopped', False), ('running', True)):
            with self.subTest(state=state, firewall_failure=fail):
                calls_file = self.base / 'firewall-calls'
                calls_file.unlink(missing_ok=True)
                self.env['FIXTURE_FIREWALL_FAIL'] = '1' if fail else '0'
                self.run_play({'vars': {'boot_artifacts_port': 8080, 'fixture_firewalld_state': state},
                               'tasks': selected}, expected=2 if fail else 0)
                if state == 'running':
                    calls = [json.loads(line) for line in calls_file.read_text().splitlines()]
                    self.assertEqual(calls, [['--add-port=8080/tcp', '--permanent'], ['--reload']])
                else:
                    self.assertFalse(calls_file.exists())

    def test_pxe_refuses_an_unreadable_staging_parent_before_configuring_nginx(self):
        tasks = yaml.safe_load((ROOT / 'ansible/roles/pxe_serve/tasks/main.yml').read_text())[1]['block']
        probe = copy.deepcopy(next(task for task in tasks
                                   if task['name'] == 'Check that the nginx worker can read the staged initrd'))
        gate = copy.deepcopy(next(task for task in tasks
                                  if task['name'] == 'Require a readable public staging path before configuring nginx'))
        # Run the same kernel-backed read check as this fixture user. The live
        # task uses root's runuser to execute it as nginx; CI does not create users.
        probe['ansible.builtin.command']['argv'] = probe['ansible.builtin.command']['argv'][4:]
        probe['become'] = False
        webroot = self.base / 'public'
        token_dir = webroot / 'fixture-token'
        token_dir.mkdir(parents=True)
        (token_dir / 'agent.x86_64-initrd.img').write_bytes(b'fixture initrd')
        sentinel = self.base / 'nginx-configuration-started'
        self.addCleanup(webroot.chmod, 0o755)
        for mode, expected in ((0o755, 0), (0o000, 2)):
            with self.subTest(parent_mode=oct(mode)):
                sentinel.unlink(missing_ok=True)
                webroot.chmod(mode)
                self.run_play({'vars': {'boot_artifacts_webroot': str(webroot), 'pxe_url_prefix': 'fixture-token'},
                               'tasks': [probe, gate, {'ansible.builtin.copy': {
                                   'dest': str(sentinel), 'content': 'started', 'mode': '0600'}}]}, expected=expected)
                self.assertEqual(sentinel.exists(), expected == 0)

    def test_public_boot_probe_blocks_provider_step_without_range_response(self):
        tasks = yaml.safe_load((ROOT / 'ansible/roles/pxe_serve/tasks/main.yml').read_text())[1]['block']
        task = copy.deepcopy(next(task for task in tasks
                                  if task['name'] == 'Verify public boot artifact access from the controller'))
        self.assertEqual(task['delegate_to'], 'localhost')
        self.assertFalse(task['become'])
        self.assertTrue(task['no_log'])
        # Retry timing is shortened in the fixture; status/URL/headers and failure
        # semantics remain the real task, with an actual loopback HTTP endpoint.
        task.update(retries=1, delay=0)
        token = 'synthetic-token-not-for-public-output'
        calls = []

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                calls.append((self.path, self.headers.get('Range')))
                self.send_response(self.server.response_status)
                self.send_header('Content-Length', '2')
                if self.server.response_status == 206:
                    self.send_header('Content-Range', 'bytes 0-1/2')
                self.end_headers()
                self.wfile.write(b'ok')

            def log_message(self, *args):
                pass

        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            sentinel = self.base / 'provider-action'
            for status in (206, 200):
                with self.subTest(http_status=status):
                    server.response_status = status
                    sentinel.unlink(missing_ok=True)
                    output = self.run_play({
                        'vars': {'boot_artifacts_base_url': f'http://127.0.0.1:{server.server_port}/{token}'},
                        'tasks': [task, {'name': 'Fixture provider action after completed PXE role',
                                         'ansible.builtin.copy': {'dest': str(sentinel), 'content': 'requested', 'mode': '0600'}}],
                    }, expected=0 if status == 206 else 2)
                    self.assertEqual(sentinel.exists(), status == 206)
                    self.assertNotIn(token, output)
            self.assertTrue(calls)
            self.assertTrue(all(path == f'/{token}/agent.x86_64-initrd.img' and header == 'bytes=0-1'
                                for path, header in calls))
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)


if __name__ == '__main__':
    unittest.main()
