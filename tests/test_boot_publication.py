"""Protect installer sources while cleaning both generations of PXE publication paths."""
import copy
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import urllib.error
import urllib.request
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / 'scripts/boot-publication-paths.py'
spec = importlib.util.spec_from_file_location('publication_paths', HELPER)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PublicationPathsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='coco-publication-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.legacy = self.base / 'install/boot-artifacts'
        self.webroot = self.base / 'www/coco-boot-artifacts'
        self.private = [self.base / 'install/src', self.base / 'install/cluster-assets',
                        self.base / 'install/provider-requests']
        for path in [self.legacy, self.webroot, *self.private]:
            path.mkdir(parents=True, mode=0o700)
            (path / 'retained-input').write_text('synthetic fixture data\n')
            (path / 'retained-input').chmod(0o600)

    def plan(self, mode, webroot=None, sources=None):
        return module.cleanup_plan(str(webroot or self.webroot),
                                   [str(path) for path in (sources or self.private)], mode,
                                   legacy=str(self.legacy))

    def check_private(self):
        for path in self.private:
            self.assertEqual((path / 'retained-input').read_text(), 'synthetic fixture data\n')
            self.assertEqual(path.stat().st_mode & 0o777, 0o700)
            self.assertEqual((path / 'retained-input').stat().st_mode & 0o777, 0o600)

    def test_stop_removes_both_publication_trees_serve_keeps_current_target(self):
        self.assertEqual(self.plan('serve')['remove'], [str(self.legacy)])
        self.assertEqual(self.plan('stop')['remove'], [str(self.webroot), str(self.legacy)])
        self.assertEqual(self.plan('serve', webroot=self.legacy)['remove'], [])
        self.assertEqual(self.plan('stop', webroot=self.legacy)['remove'], [str(self.legacy)])
        self.check_private()

    def test_source_overlap_and_symlinks_fail_before_any_cleanup(self):
        alias = self.base / 'private-alias'
        alias.symlink_to(self.private[0], target_is_directory=True)
        for target in (self.private[0], self.private[0] / 'child', self.private[0].parent, alias):
            for mode in ('serve', 'stop'):
                with self.subTest(target=target, mode=mode), self.assertRaisesRegex(ValueError, 'overlaps private'):
                    self.plan(mode, webroot=target)
        self.assertTrue(self.legacy.is_dir())
        self.assertTrue(self.webroot.is_dir())
        self.check_private()

    def test_broad_system_directories_are_rejected_but_dedicated_custom_paths_work(self):
        for target in ('/', '/etc', '/etc/nginx', '/var', '/var/lib', '/usr/local', '/opt',
                       '/var/www', '/home/example', '/root/.ssh'):
            with self.subTest(target=target), self.assertRaisesRegex(ValueError, 'dedicated directory'):
                self.plan('stop', webroot=Path(target))
        for target in ('/srv/coco-publication', '/opt/coco-publication', '/var/www/custom-boot'):
            self.assertIn(target, self.plan('stop', webroot=Path(target))['remove'])

    def test_legacy_directory_used_as_source_is_preserved(self):
        sources = [*self.private, self.legacy]
        self.assertEqual(self.plan('serve', sources=sources)['remove'], [])
        self.assertEqual(self.plan('stop', sources=sources)['remove'], [str(self.webroot)])

    def shell_fixture(self):
        directory = self.base / 'scripts'
        directory.mkdir()
        helper = directory / HELPER.name
        helper.write_text(HELPER.read_text().replace("LEGACY_WEBROOT = '/opt/install/boot-artifacts'",
                                                  'LEGACY_WEBROOT = ' + repr(str(self.legacy))))
        script = directory / 'serve-boot-artifacts.sh'
        script.write_text((ROOT / 'scripts/serve-boot-artifacts.sh').read_text()
                          .replace('WEBROOT="/var/www/coco-boot-artifacts"', 'WEBROOT="' + str(self.webroot) + '"')
                          .replace('CONF="/etc/nginx/conf.d/boot-artifacts.conf"', 'CONF="' + str(self.base / 'boot.conf') + '"')
                          .replace('PUBLICATION_STATE="/var/lib/coco-boot-publication/source-paths.json"',
                                   'PUBLICATION_STATE="' + str(self.base / 'protected-state/source-paths.json') + '"')
                          .replace('sudo install -d -m 0755 /var/www', 'sudo install -d -m 0755 "' + str(self.base / 'www') + '"'))
        tools = self.base / 'bin'
        tools.mkdir()
        sudo = tools / 'sudo'
        sudo.write_text('''#!/usr/bin/env python3
import os, pathlib, subprocess, sys
args = sys.argv[1:]
base = pathlib.Path(os.environ['FIXTURE_BASE']).resolve()
with (base / 'sudo-calls').open('a') as stream:
    stream.write(repr(args) + '\\n')
if args[0] == 'python3':
    raise SystemExit(subprocess.run([sys.executable, *args[1:]]).returncode)
if args[0] in ('rm', 'mkdir', 'cp', 'chmod', 'install', 'tee'):
    # Commands execute for real, exclusively on fixture paths. Flags and numeric
    # modes have no path meaning; every actual pathname must stay in this fixture.
    paths = [value for value in args[1:] if value.startswith('/')]
    assert paths and all(base in pathlib.Path(value).resolve().parents for value in paths), args
    raise SystemExit(subprocess.run(['/usr/bin/' + args[0], *args[1:]]).returncode)
if args[0] in ('test', 'grep'):
    raise SystemExit(subprocess.run(['/usr/bin/' + args[0], *args[1:]]).returncode)
if args[0] == 'runuser':
    assert args[1:5] == ['-u', 'nginx', '--', 'test'], args
    raise SystemExit(subprocess.run(['/usr/bin/test', *args[5:]]).returncode)
if args == ['systemctl', 'is-active', '--quiet', 'firewalld']:
    raise SystemExit(3)
assert args in (['nginx', '-t'], ['systemctl', 'reload', 'nginx'], ['systemctl', 'stop', 'nginx'],
                ['systemctl', 'enable', '--now', 'nginx'], ['systemctl', 'restart', 'nginx']), args
''')
        sudo.chmod(0o755)
        for name, body in {'nginx': '#!/bin/sh\nexit 0\n', 'getenforce': '#!/bin/sh\necho Disabled\n',
                           'sleep': '#!/bin/sh\nexit 0\n'}.items():
            stub = tools / name
            stub.write_text(body)
            stub.chmod(0o755)
        curl = tools / 'curl'
        curl.write_text("#!/usr/bin/env python3\nimport os, sys\nmode = os.environ.get('FIXTURE_HTTP_MODE', 'valid')\nroot = sys.argv[-1].endswith(':8080/agent.x86_64-initrd.img')\nprint('200' if mode == 'range-failure' or (root and mode == 'root-exposed') else '404' if root else '206', end='')\nraise SystemExit(28 if mode == 'transport-failure' else 0)\n")
        curl.chmod(0o755)
        return script, dict(os.environ, PATH=str(tools) + os.pathsep + os.environ['PATH'], FIXTURE_BASE=str(self.base))

    def test_shell_stop_cleans_legacy_and_current_but_preserves_declared_source(self):
        script, env = self.shell_fixture()
        result = subprocess.run(['bash', str(script), 'stop', str(self.private[0])],
                                env=env, cwd=self.base, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(self.legacy.exists())
        self.assertFalse(self.webroot.exists())
        self.check_private()

    def test_shell_stop_preserves_legacy_source_and_rejects_active_source_overlap(self):
        script, env = self.shell_fixture()
        result = subprocess.run(['bash', str(script), 'stop', str(self.webroot)],
                                env=env, cwd=self.base, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('overlaps private', result.stderr)
        self.assertTrue(self.webroot.exists())
        self.assertTrue(self.legacy.exists())
        result = subprocess.run(['bash', str(script), 'stop', str(self.legacy)],
                                env=env, cwd=self.base, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(self.webroot.exists())
        self.assertTrue((self.legacy / 'retained-input').is_file())
        self.check_private()

    def test_shell_refuses_missing_or_invalid_token_before_publication_changes(self):
        script, env = self.shell_fixture()
        source = self.private[0]
        (source / 'agent.x86_64-initrd.img').write_bytes(b'fixture initrd')
        for token in ('', 'short', '../escape', 'a' * 31, 'g' * 32):
            with self.subTest(token=token):
                (source / 'agent.x86_64.ipxe').write_text(
                    'kernel http://192.0.2.10:8080/' + (token + '/' if token else '') + 'agent.x86_64-vmlinuz\n')
                calls = self.base / 'sudo-calls'
                calls.unlink(missing_ok=True)
                result = subprocess.run(['bash', str(script), str(source)],
                                        env=env, cwd=self.base, capture_output=True, text=True)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertIn('single hexadecimal token', result.stderr)
                self.assertNotIn("['rm'", calls.read_text())
                self.assertNotIn("['install'", calls.read_text())
                self.assertTrue((self.legacy / 'retained-input').is_file())
                self.assertTrue((self.webroot / 'retained-input').is_file())
                self.assertFalse((self.base / 'boot.conf').exists())

    def test_shell_closes_publication_on_range_root_or_transport_failure(self):
        script, env = self.shell_fixture()
        source = self.private[0]
        token = 'a' * 32
        (source / 'agent.x86_64-initrd.img').write_bytes(b'fixture initrd')
        (source / 'agent.x86_64.ipxe').write_text(
            'kernel http://192.0.2.10:8080/' + token + '/agent.x86_64-vmlinuz\n')
        for mode in ('range-failure', 'root-exposed', 'transport-failure', 'valid'):
            with self.subTest(mode=mode):
                self.legacy.mkdir(exist_ok=True)
                (self.legacy / 'retained-input').write_text('old publication')
                result = subprocess.run(['bash', str(script), str(source)],
                                        env=dict(env, FIXTURE_HTTP_MODE=mode), cwd=self.base,
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 0 if mode == 'valid' else 1, result.stdout + result.stderr)
                self.assertFalse(self.legacy.exists())
                self.assertEqual(self.webroot.exists(), mode == 'valid')
                self.assertEqual((self.base / 'boot.conf').exists(), mode == 'valid')
                self.check_private()
                if mode != 'valid':
                    self.assertIn('closing the boot-artifact endpoint', result.stderr)

    def test_default_shell_stop_remembers_a_legacy_source_used_during_serve(self):
        script, env = self.shell_fixture()
        token = 'b' * 32
        (self.legacy / 'agent.x86_64-initrd.img').write_bytes(b'fixture initrd')
        (self.legacy / 'agent.x86_64.ipxe').write_text(
            'kernel http://192.0.2.10:8080/' + token + '/agent.x86_64-vmlinuz\n')
        result = subprocess.run(['bash', str(script), str(self.legacy)], env=env,
                                cwd=self.base, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        metadata = self.base / 'protected-state/source-paths.json'
        self.assertIn(str(self.legacy), json.loads(metadata.read_text())['sources'])
        self.assertEqual(metadata.stat().st_mode & 0o777, 0o600)
        self.assertEqual(metadata.parent.stat().st_mode & 0o777, 0o700)
        result = subprocess.run(['bash', str(script), 'stop'], env=env,
                                cwd=self.base, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.legacy / 'agent.x86_64-initrd.img').is_file())
        self.assertFalse(self.webroot.exists())

    def test_untrusted_source_metadata_prevents_cleanup(self):
        script, env = self.shell_fixture()
        metadata = self.base / 'protected-state/source-paths.json'
        metadata.parent.mkdir(mode=0o700)
        for content, mode in (({'version': 1, 'sources': [str(self.legacy)]}, 0o644),
                              ({'version': 1, 'sources': ['relative/source']}, 0o600)):
            with self.subTest(content=content, mode=mode):
                metadata.write_text(json.dumps(content))
                metadata.chmod(mode)
                result = subprocess.run(['bash', str(script), 'stop'], env=env,
                                        cwd=self.base, capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(self.webroot.exists())
                self.assertTrue(self.legacy.exists())

    def run_local_ansible(self, tasks, variables, env_overrides=None, expected=0):
        config = self.base / 'ansible.cfg'
        config.write_text('[defaults]\nstdout_callback=default\nretry_files_enabled=False\n')
        env = dict(os.environ, ANSIBLE_CONFIG=str(config), ANSIBLE_LOCAL_TEMP=str(self.base / 'local'),
                   ANSIBLE_REMOTE_TEMP=str(self.base / 'remote'), **(env_overrides or {}))
        variables = dict(variables, ansible_python_interpreter=sys.executable)
        playbook = self.base / 'play.yml'
        playbook.write_text(yaml.safe_dump([{'hosts': 'localhost', 'connection': 'local', 'gather_facts': False,
                                             'vars': variables, 'tasks': tasks}]))
        result = subprocess.run(['ansible-playbook', '-i', 'localhost,', str(playbook), '-e', 'pxe_mode=serve'],
                                env=env, cwd=self.base, capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result.stdout + result.stderr

    @unittest.skipUnless(shutil.which('ansible-playbook'), 'requires local Ansible')
    def test_ansible_staging_does_not_expand_path_variables_after_validation(self):
        block = yaml.safe_load((ROOT / 'ansible/roles/pxe_serve/tasks/main.yml').read_text())[1]['block']
        stage = copy.deepcopy(next(task for task in block if task['name'].startswith('Stage the boot artifacts')))
        stage['become'] = False
        literal_target = self.base / '${COCO_PATH_FRAGMENT}' / 'src'
        self.plan('serve', webroot=literal_target)  # Validation sees the literal, independent pathname.
        token = 'c' * 32
        self.run_local_ansible([stage], {'boot_artifacts_webroot': str(literal_target),
                              'boot_artifacts_dir': str(self.private[0]), 'pxe_url_prefix': token},
                              env_overrides={'COCO_PATH_FRAGMENT': 'install'})
        self.check_private()
        self.assertTrue((literal_target / token / 'retained-input').is_file())

    @unittest.skipUnless(shutil.which('ansible-playbook'), 'requires local Ansible')
    def test_ansible_failed_public_probe_removes_publication_and_remains_failed(self):
        role = ROOT / 'ansible/roles/pxe_serve/tasks'
        production = yaml.safe_load((role / 'main.yml').read_text())[1]
        block = production['block']
        token = 'd' * 32
        source = self.private[0]
        (source / 'agent.x86_64-initrd.img').write_bytes(b'fixture initrd')
        served_file = self.webroot / token / 'agent.x86_64-initrd.img'
        statuses = []
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass
            def do_GET(self):
                # Deliberately ignore Range while published, then expose no file
                # after the real cleanup tasks remove the publication directory.
                status = 200 if served_file.exists() else 404
                statuses.append(status)
                self.send_response(status)
                self.send_header('Content-Length', '2')
                self.end_headers()
                self.wfile.write(b'ok')
        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        cleanup = yaml.safe_load((role / 'cleanup_publication.yml').read_text())
        cleanup[0]['ansible.builtin.command']['argv'][2] = HELPER.read_text().replace(
            "LEGACY_WEBROOT = '/opt/install/boot-artifacts'", 'LEGACY_WEBROOT = ' + repr(str(self.legacy)))
        for task in cleanup:
            task['become'] = False
        (self.base / 'cleanup_publication.yml').write_text(yaml.safe_dump(cleanup))
        stop = yaml.safe_load((role / 'stop_publication.yml').read_text())
        for task in stop:
            if 'ansible.builtin.include_tasks' not in task:
                task['become'] = False
            if 'ansible.builtin.file' in task:
                task['ansible.builtin.file']['path'] = str(self.base / 'boot.conf')
            if 'ansible.builtin.command' in task:
                task['ansible.builtin.command'] = 'true'
            if 'ansible.builtin.systemd' in task:
                task.pop('ansible.builtin.systemd')
                task['ansible.builtin.debug'] = {'msg': 'fixture nginx reload'}
        (self.base / 'stop_publication.yml').write_text(yaml.safe_dump(stop))
        selected = copy.deepcopy([task for task in block if task['name'] in (
            'Reset publication mutation tracking for this invocation',
            'Track publication changes for failure cleanup',
            'Stage the boot artifacts into the tokenized webroot')])
        for task in selected:
            task['become'] = False
        selected.append({'ansible.builtin.copy': {'dest': str(self.base / 'boot.conf'), 'content': 'fixture config', 'mode': '0600'}})
        probe = copy.deepcopy(next(task for task in block if task['name'] == 'Verify public boot artifact access from the controller'))
        probe.update(retries=1, delay=0)
        selected.append(probe)
        variables = {'boot_artifacts_webroot': str(self.webroot), 'boot_artifacts_dir': str(source),
                     'install_src_dir': str(source), 'cluster_assets_dir': str(self.private[1]),
                     'install_request_dir': str(self.private[2]), 'pxe_url_prefix': token,
                     'pxe_publication_state_path': str(self.base / 'protected-state/source-paths.json'),
                     'boot_artifacts_base_url': f'http://127.0.0.1:{server.server_port}/{token}'}
        output = self.run_local_ansible([{'block': selected, 'rescue': production['rescue']}], variables, expected=2)
        self.assertIn('PXE publication failed', output)
        self.assertFalse(self.webroot.exists())
        self.assertFalse((self.base / 'boot.conf').exists())
        self.check_private()
        with self.assertRaises(urllib.error.HTTPError) as caught:
            urllib.request.urlopen(variables['boot_artifacts_base_url'] + '/agent.x86_64-initrd.img', timeout=5)
        self.assertEqual(caught.exception.code, 404)
        caught.exception.close()
        self.assertIn(200, statuses)
        self.assertEqual(statuses[-1], 404)

    @unittest.skipUnless(shutil.which('ansible-playbook'), 'requires local Ansible')
    def test_ansible_migration_cleanup_preserves_private_files_and_active_legacy_override(self):
        config = self.base / 'ansible.cfg'
        config.write_text('[defaults]\nstdout_callback=default\nretry_files_enabled=False\n')
        env = dict(os.environ, ANSIBLE_CONFIG=str(config), ANSIBLE_LOCAL_TEMP=str(self.base / 'local'),
                   ANSIBLE_REMOTE_TEMP=str(self.base / 'remote'))
        tasks = yaml.safe_load((ROOT / 'ansible/roles/pxe_serve/tasks/cleanup_publication.yml').read_text())
        tasks = copy.deepcopy(tasks)
        for task in tasks:
            task['become'] = False
        # Relocate only the known legacy publication path into this test's filesystem.
        tasks[0]['ansible.builtin.command']['argv'][2] = HELPER.read_text().replace(
            "LEGACY_WEBROOT = '/opt/install/boot-artifacts'", 'LEGACY_WEBROOT = ' + repr(str(self.legacy)))
        playbook = self.base / 'play.yml'
        variables = {'ansible_python_interpreter': sys.executable, 'install_src_dir': str(self.private[0]),
                     'cluster_assets_dir': str(self.private[1]), 'boot_artifacts_dir': str(self.private[1] / 'boot-artifacts'),
                     'install_request_dir': str(self.private[2]),
                     'pxe_publication_state_path': str(self.base / 'protected-state/source-paths.json')}
        for mode, target, sources, expected in (
                ('serve', self.legacy, None, 0),
                ('serve', self.webroot, str(self.legacy), 0),
                ('serve', self.private[0], None, 2),
                ('serve', self.webroot, None, 0),
                ('stop', self.webroot, None, 0)):
            with self.subTest(mode=mode, target=target, source=sources):
                if sources is None:
                    (self.base / 'protected-state/source-paths.json').unlink(missing_ok=True)
                variables.update(pxe_mode=mode, boot_artifacts_webroot=str(target),
                                 boot_artifacts_dir=sources or str(self.private[1] / 'boot-artifacts'))
                playbook.write_text(yaml.safe_dump([{'hosts': 'localhost', 'connection': 'local', 'gather_facts': False,
                                                     'vars': variables, 'tasks': tasks}]))
                result = subprocess.run(['ansible-playbook', '-i', 'localhost,', str(playbook)],
                                        env=env, cwd=self.base, capture_output=True, text=True, timeout=60)
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                self.check_private()
                if mode == 'stop':
                    self.assertFalse(self.webroot.exists())
                    self.assertFalse(self.legacy.exists())
                elif target == self.webroot and sources is None:
                    self.assertFalse(self.legacy.exists())
                    self.assertTrue(self.webroot.exists())
                    # Recreate old publication to exercise both removals in stop.
                    self.legacy.mkdir()
                else:
                    self.assertTrue(self.legacy.exists())
                    self.assertTrue(self.webroot.exists())


if __name__ == '__main__':
    unittest.main()
