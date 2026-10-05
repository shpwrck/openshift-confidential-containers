"""Offline bootstrap regression fixtures. No network, cluster or provider calls.

Ansible task copies retain production conditions/actions; fixture ownership and become
settings are replaced so the same tests run as an unprivileged local user.
"""
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import threading
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
VERSION = '4.20.39'
PAYLOAD = 'registry.example/release@sha256:' + 'a' * 64


def write_executable(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    path.chmod(0o755)


class BootstrapTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='coco-bootstrap-')
        self.base = Path(self.tmp.name)
        self.bin = self.base / 'fake-bin'
        self.bin.mkdir()
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'])
        self.env.update(COCO_STATE_DIR=str(self.base / 'state'), OCP_VERSION=VERSION)
        self.log = self.base / 'calls'
        self.env['FIXTURE_CALLS'] = str(self.log)

    def tearDown(self):
        self.tmp.cleanup()

    def run_cmd(self, args, expected=0, **kwargs):
        result = subprocess.run(args, env=self.env, cwd=self.base, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, **kwargs)
        self.assertEqual(result.returncode, expected, result.stdout)
        return result.stdout

    def tool_fixture(self):
        remote = self.base / 'remote'
        remote.mkdir()
        contents = self.base / 'contents'
        contents.mkdir()
        scripts = {
            'oc': '#!/bin/sh\necho "Client Version: ' + VERSION + '"\n',
            'kubectl': '#!/bin/sh\necho kubectl\n',
            'openshift-install': '#!/bin/sh\necho "openshift-install ' + VERSION + '"\n',
            'oc-mirror': '#!/bin/sh\necho mirror-version\n',
        }
        for name, text in scripts.items():
            write_executable(contents / name, text)
        archives = {
            'openshift-client-linux-' + VERSION + '.tar.gz': ['oc', 'kubectl'],
            'openshift-install-linux-' + VERSION + '.tar.gz': ['openshift-install'],
            'oc-mirror.rhel9.tar.gz': ['oc-mirror'],
        }
        checksums = []
        for archive, names in archives.items():
            with tarfile.open(remote / archive, 'w:gz') as f:
                for name in names:
                    f.add(contents / name, arcname=name)
            checksums.append(hashlib.sha256((remote / archive).read_bytes()).hexdigest() + '  ' + archive)
        (remote / 'sha256sum.txt').write_text('\n'.join(checksums) + '\n')
        write_executable(self.bin / 'curl', '''#!/usr/bin/env python3
import os, pathlib, shutil, sys
args=sys.argv[1:]
url=next(x for x in args if x.startswith('https://'))
name=url.rsplit('/',1)[-1]
with open(os.environ['FIXTURE_CALLS'],'a') as f: f.write(url+'\\n')
source=pathlib.Path(os.environ['FIXTURE_REMOTE'])/name
if not source.is_file(): raise SystemExit(22)
shutil.copyfile(source, args[args.index('-o')+1])
''')
        self.env.update(FIXTURE_REMOTE=str(remote), OCP_CLIENTS_BASE='https://fixture.invalid/clients',
                        BIN_DIR=str(self.base / 'installed'))
        return remote

    def install_tools(self, expected=0):
        return self.run_cmd(['bash', str(ROOT / 'scripts/install-tools.sh')], expected)

    def test_tools_repair_old_or_modified_binaries_and_reuse_valid_set(self):
        self.tool_fixture()
        installed = Path(self.env['BIN_DIR'])
        installed.mkdir()
        write_executable(installed / 'oc', '#!/bin/sh\necho OLD\n')
        self.assertIn('COCO_TOOLS_CHANGED=1', self.install_tools())
        self.assertIn('COCO_TOOLS_CHANGED=0', self.install_tools())
        (installed / 'oc').write_text('changed after installation')
        self.assertIn('COCO_TOOLS_CHANGED=1', self.install_tools())
        self.assertIn('Client Version: ' + VERSION, (installed / 'oc').read_text())

    def test_tools_bad_checksum_does_not_replace_installed_set(self):
        remote = self.tool_fixture()
        self.install_tools()
        installed = Path(self.env['BIN_DIR'])
        original = (installed / 'openshift-install').read_bytes()
        # Force a repair while simulating corrupt remote content.
        (installed / 'oc').write_text('old version')
        (remote / 'oc-mirror.rhel9.tar.gz').write_bytes(b'corrupt')
        self.assertIn('checksum mismatch', self.install_tools(1))
        self.assertEqual(original, (installed / 'openshift-install').read_bytes())

    def test_tools_missing_release_never_falls_back_to_latest(self):
        self.tool_fixture()
        (Path(self.env['FIXTURE_REMOTE']) / 'sha256sum.txt').unlink()
        self.assertIn('no latest fallback', self.install_tools(1))
        self.assertNotIn('/latest/', self.log.read_text())
        self.assertFalse((Path(self.env['BIN_DIR']) / 'oc').exists())

    def test_mirror_resources_uses_custom_workspace_from_any_cwd(self):
        workspace = self.base / 'workspace with spaces'
        resources = workspace / 'working-dir/cluster-resources'
        resources.mkdir(parents=True)
        bom = json.loads((ROOT / 'install/release-manifest.json').read_text())
        endpoint = 'mirror.example:8443'
        repository = endpoint + '/' + bom['catalog']['ref'].split('@')[0].split('/', 1)[1]
        filtered_digest = 'c' * 64
        source_image = repository + ':sha256-' + filtered_digest
        catalog_name = repository.rsplit('/', 1)[1]
        filtered = (workspace / 'working-dir/operator-catalogs' / catalog_name /
                    bom['catalog']['digest'].split(':')[1] / 'filtered-catalogs/selected')
        filtered.mkdir(parents=True)
        (filtered / 'digest').write_text(filtered_digest)
        for operator in bom['operators'].values():
            fbc = [
                {'schema': 'olm.package', 'name': operator['package'], 'defaultChannel': operator['channel']},
                {'schema': 'olm.channel', 'name': operator['channel'], 'package': operator['package'],
                 'entries': [{'name': operator['startingCSV']}]},
                {'schema': 'olm.bundle', 'name': operator['startingCSV'], 'package': operator['package'],
                 'image': operator['bundleImage'], 'properties': [{'type': 'olm.package', 'value': {
                     'packageName': operator['package'], 'version': operator['version']}}]},
            ]
            config = filtered / 'catalog-config' / operator['package'] / 'catalog.json'
            config.parent.mkdir(parents=True)
            config.write_text('\n'.join(json.dumps(document) for document in fbc))
        (resources / 'idms.yaml').write_text(yaml.safe_dump({
            'apiVersion': 'config.openshift.io/v1', 'kind': 'ImageDigestMirrorSet',
            'metadata': {'name': 'fixture'}, 'spec': {'imageDigestMirrors': []}}))
        (resources / 'catalog.yaml').write_text(yaml.safe_dump({
            'apiVersion': 'operators.coreos.com/v1alpha1', 'kind': 'CatalogSource',
            'metadata': {'name': 'digest-generated-name', 'namespace': 'openshift-marketplace'},
            'spec': {'sourceType': 'grpc', 'image': source_image}}))
        (resources / 'cluster-catalog.yml').write_text(yaml.safe_dump({
            'apiVersion': 'olm.operatorframework.io/v1', 'kind': 'ClusterCatalog',
            'metadata': {'name': 'generated-olmv1-catalog'},
            'spec': {'source': {'type': 'Image', 'image': {'ref': source_image}}}}))
        signatures = {
            'apiVersion': 'v1', 'kind': 'ConfigMap', 'metadata': {
                'name': 'mirrored-release-signatures', 'namespace': 'openshift-config-managed',
                'labels': {'release.openshift.io/verification-signatures': ''}},
            'binaryData': {bom['platform']['releaseImage'].split('@')[1].replace(':', '-') + '-1': 'YWJj'},
        }
        (resources / 'signature-configmap.json').write_text(json.dumps(signatures))
        (resources / 'signature-configmap.yaml').write_text(yaml.safe_dump(signatures))
        write_executable(self.bin / 'oc', '''#!/usr/bin/env python3
import json,os,sys
with open(os.environ['FIXTURE_CALLS'],'a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')
info={'name':sys.argv[-1], 'digest':'sha256:'+'b'*64, 'contentDigest':'sha256:'+'b'*64,
 'config':{'os':'linux','architecture':'amd64','config':{'Labels':{'operators.operatorframework.io.index.configs.v1':'/configs'}}}}
if '@' not in sys.argv[-1]: info['listDigest']='sha256:'+'c'*64
print(json.dumps(info))
''')
        self.env.update(WORKSPACE='file://' + str(workspace), ARTIFACTORY_REGISTRY=endpoint,
                        BIN_DIR=str(self.bin), RELEASE_MANIFEST=str(ROOT / 'install/release-manifest.json'),
                        IMAGESET_CONFIG=str(ROOT / 'install/imageset-config.yaml'))
        out = self.run_cmd(['bash', str(ROOT / 'scripts/mirror.sh'), 'resources'])
        self.assertIn(str(workspace / 'normalized-cluster-resources.json'), out)
        normalized = json.loads((workspace / 'normalized-cluster-resources.json').read_text())
        catalog = next(item for item in normalized['items'] if item['kind'] == 'CatalogSource')
        self.assertEqual(catalog['metadata']['name'], bom['catalog']['source'])
        self.assertEqual(catalog['spec']['image'], repository + '@sha256:' + 'b' * 64)
        self.assertEqual(next(item for item in normalized['items'] if item['kind'] == 'ConfigMap'), signatures)
        self.assertFalse(any(item['kind'] == 'ClusterCatalog' for item in normalized['items']))
        self.assertEqual(len(self.log.read_text().splitlines()), 2)

    def test_wrapper_verify_has_no_provisioning_and_uses_absolute_config(self):
        write_executable(self.bin / 'ansible-playbook', '''#!/usr/bin/env python3
import json,os,sys
with open(os.environ['FIXTURE_CALLS'],'a') as f:
 f.write(json.dumps({'argv':sys.argv[1:],'cwd':os.getcwd(),'config':os.environ['ANSIBLE_CONFIG']})+'\\n')
''')
        write_executable(self.bin / 'terraform', '#!/bin/sh\nexit 97\n')
        self.env.pop('ANSIBLE_CONFIG', None)
        self.run_cmd(['bash', str(ROOT / 'ansible/up.sh'), '--mode', 'verify'])
        record = json.loads(self.log.read_text())
        self.assertEqual(record['cwd'], str(ROOT / 'ansible'))
        self.assertEqual(record['config'], str(ROOT / 'ansible/ansible.cfg'))
        self.assertIn('install_mode=verify', record['argv'])
        self.log.unlink()
        self.run_cmd(['bash', str(ROOT / 'ansible/up.sh'), '--mode', 'verify', '--',
                      '-e', 'test_text=value with spaces', '--limit', 'bastion'])
        spaced_record = json.loads(self.log.read_text())
        self.assertEqual(spaced_record['argv'], ['playbooks/site.yml', '--tags', 'drive',
            '-e', 'test_text=value with spaces', '--limit', 'bastion', '-e', 'install_mode=verify'])
        self.run_cmd(['bash', str(ROOT / 'ansible/up.sh'), '--mode', 'upgrade'], 2)
        self.run_cmd(['bash', str(ROOT / 'ansible/up.sh'), '--mode', 'verify', '--apply-tf'], 2)

    def test_wrapper_rejects_secret_state_inside_checkout(self):
        self.env['COCO_STATE_DIR'] = str(ROOT / 'state')
        out = self.run_cmd(['bash', str(ROOT / 'ansible/up.sh'), '--mode', 'verify'], 1)
        self.assertIn('outside', out)

    def test_wrapper_rejects_checkout_state_even_when_external_state_exists(self):
        repo = self.base / 'wrapper-repo'
        (repo / 'ansible').mkdir(parents=True)
        (repo / 'scripts/lib').mkdir(parents=True)
        module = repo / 'infra/latitude/bastion'
        module.mkdir(parents=True)
        shutil.copyfile(ROOT / 'ansible/up.sh', repo / 'ansible/up.sh')
        (repo / 'scripts/lib/release.sh').write_text(
            'load_release_defaults() { :; }\nrequire_resolved_release() { :; }\n')
        checkout_state = module / 'terraform.tfstate'
        external_state = Path(self.env['COCO_STATE_DIR']) / 'terraform/bastion/terraform.tfstate'
        external_state.parent.mkdir(parents=True)
        checkout_state.write_text('{"serial":2}')
        external_state.write_text('{"serial":1}')
        for tool in ('terraform', 'ansible-playbook'):
            write_executable(self.bin / tool, '#!/bin/sh\necho unexpected >> "$FIXTURE_CALLS"\nexit 97\n')
        for action in ('--plan-tf', '--apply-tf'):
            with self.subTest(action=action):
                out = self.run_cmd(['bash', str(repo / 'ansible/up.sh'), action], 2)
                self.assertIn('reconcile', out)
                self.assertFalse(self.log.exists())
                self.assertEqual(checkout_state.read_text(), '{"serial":2}')
                self.assertEqual(external_state.read_text(), '{"serial":1}')

    def test_wrapper_plan_never_applies_or_runs_ansible_and_fresh_closes_endpoint(self):
        # A resolved release fixture isolates orchestration from registry credentials.
        repo = self.base / 'wrapper-repo'
        (repo / 'ansible').mkdir(parents=True)
        (repo / 'scripts/lib').mkdir(parents=True)
        (repo / 'infra/latitude/bastion').mkdir(parents=True)
        shutil.copyfile(ROOT / 'ansible/up.sh', repo / 'ansible/up.sh')
        (repo / 'scripts/lib/release.sh').write_text(
            'load_release_defaults() { :; }\nrequire_resolved_release() { :; }\n')
        write_executable(self.bin / 'terraform', '''#!/usr/bin/env python3
import json,os,sys
args=sys.argv[1:]
with open(os.environ['FIXTURE_CALLS'],'a') as f:f.write(json.dumps({'tool':'terraform','args':args})+'\\n')
if 'output' in args:
 print({'bastion_public_ipv4':'192.0.2.1','virtual_network_vid':'123','server_id':'sv_fixture'}[args[-1]])
''')
        write_executable(self.bin / 'ansible-playbook', '''#!/usr/bin/env python3
import json,os,sys
with open(os.environ['FIXTURE_CALLS'],'a') as f:f.write(json.dumps({'tool':'ansible','args':sys.argv[1:]})+'\\n')
''')
        script = str(repo / 'ansible/up.sh')
        self.run_cmd(['bash', script, '--mode', 'fresh-install', '--plan-tf'])
        calls = [json.loads(line) for line in self.log.read_text().splitlines()]
        self.assertTrue(all(c['tool'] == 'terraform' for c in calls))
        self.assertEqual(sum('plan' in c['args'] for c in calls), 2)
        self.assertFalse(any('apply' in c['args'] for c in calls))
        self.log.unlink()
        self.run_cmd(['bash', script, '--mode', 'fresh-install', '--apply-tf'])
        calls = [json.loads(line) for line in self.log.read_text().splitlines()]
        plays = [c['args'] for c in calls if c['tool'] == 'ansible']
        self.assertEqual(len(plays), 3)
        self.assertIn('bastion_ansible_host=192.0.2.1', plays[0])
        self.assertIn('node_server_id=sv_fixture', plays[1])
        self.assertIn('pxe-stop', plays[2])
        self.assertEqual(sum('apply' in c['args'] for c in calls), 2)

    def ansible(self, task_file, variables, expected=0):
        if shutil.which('ansible-playbook') is None:
            self.skipTest('ansible-playbook required for local bootstrap fixtures')
        fixture = self.base / 'fixture'
        playbook_dir = fixture / 'ansible/playbooks'
        playbook_dir.mkdir(parents=True, exist_ok=True)
        (fixture / 'install').mkdir(exist_ok=True)
        src = ROOT / task_file
        dest = fixture / 'tasks'
        dest.mkdir(exist_ok=True)

        def unprivileged(value):
            if isinstance(value, list):
                return [unprivileged(x) for x in value]
            if isinstance(value, dict):
                result = {k: unprivileged(v) for k, v in value.items()}
                if 'become' in result:
                    result['become'] = False
                for module in ('ansible.builtin.copy', 'ansible.builtin.file'):
                    if module in result:
                        result[module].pop('owner', None)
                        result[module].pop('group', None)
                return result
            return value

        for path in src.parent.glob('*.yml'):
            data = unprivileged(yaml.safe_load(path.read_text()))
            (dest / path.name).write_text(yaml.safe_dump(data, sort_keys=False))
        play = [{'name': 'Offline bootstrap fixture', 'hosts': 'localhost', 'connection': 'local',
                 'gather_facts': False, 'vars': variables,
                 'tasks': [{'ansible.builtin.include_tasks': str(dest / src.name)}]}]
        playpath = playbook_dir / 'test.yml'
        playpath.write_text(yaml.safe_dump(play, sort_keys=False))
        config = fixture / 'ansible.cfg'
        config.write_text('[defaults]\nstdout_callback=default\nretry_files_enabled=False\n')
        self.env.update(ANSIBLE_CONFIG=str(config), ANSIBLE_LOCAL_TEMP=str(self.base / 'ansible-local'),
                        ANSIBLE_REMOTE_TEMP=str(self.base / 'ansible-remote'))
        return self.run_cmd(['ansible-playbook', '-i', 'localhost,', str(playpath)], expected, timeout=90)

    def mirror_variables(self):
        (self.base / 'fixture/install').mkdir(parents=True, exist_ok=True)
        image_set = self.base / 'fixture/install/imageset-config.yaml'
        image_set.write_text('apiVersion: fixture-v1\n')
        for name in ('remote-home', 'mirror', 'workspace'):
            (self.base / name).mkdir(exist_ok=True)
        write_executable(self.bin / 'oc-mirror', '''#!/usr/bin/env python3
import os,pathlib,sys
with open(os.environ['FIXTURE_CALLS'],'a') as f:f.write('mirror\\n')
args=sys.argv[1:]
workspace=pathlib.Path(args[args.index('--workspace')+1].removeprefix('file://'))
if os.environ.get('FIXTURE_MIRROR_FAIL')=='1':raise SystemExit(7)
out=workspace/'working-dir/cluster-resources'
out.mkdir(parents=True,exist_ok=True)
(out/'catalog.yaml').write_text('apiVersion: fixture-v1\\n')
''')
        return dict(ansible_facts={'env': {'HOME': str(self.base / 'remote-home')}},
                    mirror_root=str(self.base / 'mirror'), mirror_workspace=str(self.base / 'workspace'),
                    local_bin=str(self.bin), mirror_endpoint='registry.example:8443', ocp_version=VERSION,
                    imageset_config_absolute=str(image_set),
                    ocp_release_image=PAYLOAD, tool_path=self.env['PATH'])

    def test_mirror_stages_the_selected_imageset(self):
        variables = self.mirror_variables()
        selected = self.base / 'selected-profile-images.yaml'
        selected.write_text('apiVersion: selected-profile\n')
        variables['imageset_config_absolute'] = str(selected)
        self.ansible('ansible/roles/mirror_push/tasks/main.yml', variables)
        self.assertEqual((self.base / 'remote-home/imageset-config.yaml').read_text(), selected.read_text())

    def test_mirror_changed_inputs_invalidate_success_marker(self):
        variables = self.mirror_variables()
        task = 'ansible/roles/mirror_push/tasks/main.yml'
        self.ansible(task, variables)
        self.ansible(task, variables)
        self.assertEqual(self.log.read_text().count('mirror\n'), 1)
        (self.base / 'fixture/install/imageset-config.yaml').write_text('apiVersion: fixture-v2\n')
        self.ansible(task, variables)
        self.assertEqual(self.log.read_text().count('mirror\n'), 2)
        variables['mirror_endpoint'] = 'other.example:8443'
        self.ansible(task, variables)
        self.assertEqual(self.log.read_text().count('mirror\n'), 3)
        (self.base / 'workspace/working-dir/cluster-resources/catalog.yaml').unlink()
        self.ansible(task, variables)
        self.assertEqual(self.log.read_text().count('mirror\n'), 4)

    def pxe_variables(self):
        source = self.base / 'source'
        source.mkdir()
        (source / 'install-config.yaml').write_text('fixture install config\n')
        (source / 'agent-config.yaml').write_text('fixture boot token one\n')
        write_executable(self.bin / 'openshift-install', '''#!/usr/bin/env python3
import os,pathlib,sys
if sys.argv[1]=='version':
 print('openshift-install ''' + VERSION + '''')
 print('release image ''' + PAYLOAD + '''')
else:
 with open(os.environ['FIXTURE_CALLS'],'a') as f:f.write('pxe\\n')
 target=pathlib.Path(sys.argv[sys.argv.index('--dir')+1])/'boot-artifacts'
 target.mkdir(parents=True)
 for name in ('agent.x86_64.ipxe','agent.x86_64-vmlinuz','agent.x86_64-initrd.img'):
  (target/name).write_text('fixture')
''')
        assets = self.base / 'assets'
        return dict(install_mode='fresh', cluster_assets_dir=str(assets), install_src_dir=str(source),
                    boot_artifacts_dir=str(assets / 'boot-artifacts'), local_bin=str(self.bin),
                    ocp_version=VERSION, ocp_release_image=PAYLOAD, tool_path=self.env['PATH'])

    def test_pxe_reuses_only_matching_complete_artifacts(self):
        variables = self.pxe_variables()
        task = 'ansible/roles/pxe_serve/tasks/prepare.yml'
        self.ansible(task, variables)
        self.ansible(task, variables)
        self.assertEqual(self.log.read_text().count('pxe\n'), 1)
        (self.base / 'source/agent-config.yaml').write_text('changed boot token\n')
        self.ansible(task, variables)
        self.assertEqual(self.log.read_text().count('pxe\n'), 2)
        (self.base / 'assets/boot-artifacts/agent.x86_64-initrd.img').unlink()
        self.ansible(task, variables)
        self.assertEqual(self.log.read_text().count('pxe\n'), 3)

    def test_pxe_refuses_payload_mismatch_and_existing_cluster_replacement(self):
        variables = self.pxe_variables()
        task = 'ansible/roles/pxe_serve/tasks/prepare.yml'
        wrong = dict(variables, ocp_release_image='registry.example/release@sha256:' + 'b' * 64)
        self.assertIn('Installer release/payload differs', self.ansible(task, wrong, 2))
        self.assertFalse(self.log.exists())
        self.ansible(task, variables)
        (self.base / 'assets/auth').mkdir()
        (self.base / 'assets/auth/kubeconfig').write_text('fixture, not a credential')
        (self.base / 'source/agent-config.yaml').write_text('changed input\n')
        self.assertIn('not an upgrade', self.ansible(task, variables, 2))
        self.assertEqual(self.log.read_text().count('pxe\n'), 1)

    def test_pxe_rebuild_preserves_durable_provider_journal_and_blocks_ambiguity(self):
        variables = self.pxe_variables()
        task = 'ansible/roles/pxe_serve/tasks/prepare.yml'
        self.ansible(task, variables)
        journal = self.base / 'provider-requests/.coco-reinstall-sv_fixture.json'
        journal.parent.mkdir()
        journal.write_text(json.dumps({'state': 'requested', 'identity': 'e' * 64}))
        original = journal.read_bytes()
        (self.base / 'source/agent-config.yaml').write_text('new boot inputs\n')
        variables['reinstall_existing'] = True
        self.ansible(task, variables)
        self.assertEqual(journal.read_bytes(), original)
        marker = (self.base / 'assets/.coco-pxe-inputs').read_bytes()
        journal.write_text(json.dumps({'state': 'sending', 'identity': 'e' * 64}))
        (self.base / 'source/agent-config.yaml').write_text('another input revision\n')
        self.assertIn('ambiguous', self.ansible(task, variables, 2))
        self.assertEqual((self.base / 'assets/.coco-pxe-inputs').read_bytes(), marker)
        self.assertEqual(self.log.read_text().count('pxe\n'), 2)

    def provider_fixture(self):
        requests = []
        response = {'id': 'sv_fixture', 'post_status': 202}

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def do_GET(self):
                requests.append(('GET', self.path))
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({'data': {'id': response['id'],
                    'attributes': {'hostname': 'fixture'}}}).encode())

            def do_POST(self):
                requests.append(('POST', self.path))
                self.rfile.read(int(self.headers['Content-Length']))
                self.send_response(response['post_status'])
                self.end_headers()

        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        assets = self.base / 'assets'
        assets.mkdir()
        variables = dict(cluster_assets_dir=str(assets), install_identity='c' * 64,
                         install_machine={'name': 'fixture', 'server_id': 'sv_fixture'},
                         retry_reinstall=False, reinstall_existing=False,
                         latitude_api_base='http://127.0.0.1:' + str(server.server_port),
                         latitude_token='fixture-not-a-secret', ocp_version=VERSION,
                         ipxe_url='http://example.invalid/fixture.ipxe')
        return variables, requests, response

    def test_reinstall_once_and_ambiguous_action_requires_inspection(self):
        variables, requests, response = self.provider_fixture()
        task = 'ansible/roles/install_drive/tasks/reinstall.yml'
        response['post_status'] = 500
        self.ansible(task, variables, 2)
        record = self.base / 'provider-requests/.coco-reinstall-sv_fixture.json'
        self.assertEqual(json.loads(record.read_text())['state'], 'sending')
        self.assertIn('ambiguous', self.ansible(task, variables, 2))
        self.assertEqual(len(requests), 2, 'ambiguous action was retried automatically')
        # Simulate the operator confirming the failed request was not accepted.
        variables['retry_reinstall'] = True
        response['post_status'] = 202
        self.ansible(task, variables)
        self.assertEqual(json.loads(record.read_text())['state'], 'requested')
        self.ansible(task, variables)
        self.assertEqual(len(requests), 4, 'completed request was repeated')
        variables['install_identity'] = 'd' * 64
        self.assertIn('different inputs', self.ansible(task, variables, 2))
        self.assertEqual(len(requests), 4)

    def test_reinstall_wrong_provider_identity_never_posts(self):
        variables, requests, response = self.provider_fixture()
        response['id'] = 'sv_other'
        self.assertIn('Provider identity does not match', self.ansible(
            'ansible/roles/install_drive/tasks/reinstall.yml', variables, 2))
        self.assertEqual(requests, [('GET', '/servers/sv_fixture')])
        self.assertFalse((self.base / 'provider-requests/.coco-reinstall-sv_fixture.json').exists())

    def test_verify_checks_actual_payload_without_provider_calls(self):
        variables = dict(install_mode='verify', install_trigger_reinstall=False,
                         machines=[{'name': 'test-node', 'server_id': 'sv_fixture'}],
                         ocp_release_image=PAYLOAD, ocp_version=VERSION,
                         cluster_assets_dir=str(self.base / 'assets'), mirror_workspace=str(self.base / 'workspace'),
                         tool_path=self.env['PATH'], clusterversion_poll_retries=1, clusterversion_poll_delay=0,
                         cluster_name='fixture', base_domain='example.invalid')
        self.env['FIXTURE_RELEASE'] = VERSION
        write_executable(self.bin / 'oc', '''#!/usr/bin/env python3
import json,os
version=os.environ['FIXTURE_RELEASE']
print(json.dumps({'status':{'desired':{'version':version,'image':"''' + PAYLOAD + '''"},
'history':[{'version':version,'state':'Completed'}],
'conditions':[{'type':'Available','status':'True'},{'type':'Progressing','status':'False'},{'type':'Failing','status':'False'}]}}))
''')
        task = 'ansible/roles/install_drive/tasks/main.yml'
        self.ansible(task, variables)
        self.env['FIXTURE_RELEASE'] = '4.20.18'
        self.ansible(task, variables, 2)
        variables['install_mode'] = 'upgrade'
        self.assertIn('does not perform in-place upgrades', self.ansible(task, variables, 2))


if __name__ == '__main__':
    unittest.main()
