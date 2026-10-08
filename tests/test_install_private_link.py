"""Exercise the pre-reinstall gate locally with provider/SSH/host-command fixtures."""
import hashlib
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
ROLE = ROOT / 'ansible/roles/install_drive/tasks'


@unittest.skipUnless(shutil.which('ansible-playbook'), 'requires local Ansible')
class PrivateLinkInstallTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='coco-install-private-link-')
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.fixture = self.base / 'repo'
        self.playdir = self.fixture / 'ansible/playbooks'
        self.playdir.mkdir(parents=True)
        identity_scripts = self.fixture / 'scripts'
        (identity_scripts / 'lib').mkdir(parents=True)
        shutil.copy2(ROOT / 'scripts/provider-identity.py', identity_scripts)
        shutil.copy2(ROOT / 'scripts/lib/provider.py', identity_scripts / 'lib')
        self.tasks = self.base / 'tasks'
        self.tasks.mkdir()
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        self.events = self.base / 'events'
        self.journal = self.base / 'provider-requests/.coco-reinstall-sv_fixture.json'
        self.config = self.base / 'ansible.cfg'
        self.config.write_text('[defaults]\nstdout_callback=default\nretry_files_enabled=False\n')
        self.env = dict(os.environ, ANSIBLE_CONFIG=str(self.config),
                        ANSIBLE_LOCAL_TEMP=str(self.base / 'local'),
                        ANSIBLE_REMOTE_TEMP=str(self.base / 'remote'),
                        ANSIBLE_ROLES_PATH=str(self.base / 'roles'),
                        COCO_STATE_DIR=str(self.base / 'state'),
                        PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                        FIXTURE_EVENTS=str(self.events), FIXTURE_JOURNAL=str(self.journal))
        self.requests = []
        self.request_bodies = []
        self.provider_interfaces = [{'role': 'internal', 'mac_address': '02:00:00:00:00:11'},
                                    {'role': 'external', 'mac_address': '02:00:00:00:00:12'}]
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def do_GET(self):
                owner.requests.append('GET')
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                payload = getattr(owner, 'provider_payload', {'data': {'id': 'sv_fixture', 'attributes': {
                    'hostname': 'fixture', 'primary_ipv4': '192.0.2.11', 'interfaces': owner.provider_interfaces}}})
                self.wfile.write(json.dumps(payload).encode())

            def do_POST(self):
                owner.requests.append('POST')
                owner.request_bodies.append(json.loads(self.rfile.read(int(self.headers['Content-Length']))))
                owner.assertEqual(json.loads(owner.journal.read_text())['state'], 'sending')
                self.send_response(202)
                self.end_headers()

        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        self.variables = dict(cluster_assets_dir=str(self.base / 'assets'), install_identity='c' * 64,
                              install_machine={'name': 'fixture', 'server_id': 'sv_fixture',
                                               'parent_if': 'eno2', 'vlan_ip': '192.168.66.11'},
                              retry_reinstall=False, reinstall_existing=False, ocp_version='4.20.39',
                              latitude_api_base=f'http://127.0.0.1:{server.server_port}',
                              latitude_token='fixture-token', ipxe_url='http://example.invalid/fixture.ipxe')

    def run_role(self, expected=0, real_gate=False, gate_only=False):
        def local_fixture(value):
            if isinstance(value, list):
                return [local_fixture(item) for item in value]
            if not isinstance(value, dict):
                return value
            result = {key: local_fixture(item) for key, item in value.items()}
            if 'become' in result:
                result['become'] = False
            for module in ('ansible.builtin.copy', 'ansible.builtin.file'):
                if module in result:
                    result[module].pop('owner', None)
                    result[module].pop('group', None)
            if 'ansible.builtin.add_host' in result:
                # Preserve all SSH policy inputs, but execute against local files.
                result['ansible.builtin.add_host']['ansible_connection'] = 'local'
                result['ansible.builtin.add_host']['ansible_python_interpreter'] = sys.executable
            if result.get('ansible.builtin.tempfile', {}).get('path') == '/run':
                result['ansible.builtin.tempfile']['path'] = str(self.base)
            return result

        for source in ROLE.glob('*.yml'):
            (self.tasks / source.name).write_text(yaml.safe_dump(
                local_fixture(yaml.safe_load(source.read_text())), sort_keys=False))
        if not real_gate:
            (self.tasks / 'private_link.yml').write_text(yaml.safe_dump([{
                'name': 'Bounded local raw-host gate fixture',
                'ansible.builtin.command': {'argv': [sys.executable, '-c',
                    'import json,os,pathlib; p=pathlib.Path(os.environ["FIXTURE_JOURNAL"]); '
                    'pathlib.Path(os.environ["FIXTURE_EVENTS"]).open("a").write('
                    'json.dumps({"probe":True,"journal":p.read_text() if p.exists() else None})+"\\n"); '
                    'raise SystemExit(int(os.environ.get("FIXTURE_GATE_FAIL","0")))']},
                'changed_when': False,
            }], sort_keys=False))
        stop = self.base / 'roles/pxe_serve/tasks'
        stop.mkdir(parents=True, exist_ok=True)
        (stop / 'stop_publication.yml').write_text(yaml.safe_dump([{
            'name': 'Local endpoint closure fixture',
            'ansible.builtin.command': {'argv': [sys.executable, '-c',
                'import os,pathlib; pathlib.Path(os.environ["FIXTURE_EVENTS"]).open("a").write("closed\\n")']},
            'changed_when': False,
        }], sort_keys=False))
        self.variables['ansible_python_interpreter'] = sys.executable
        selected_tasks = ([{'ansible.builtin.include_tasks': str(self.tasks / 'private_link.yml')}] if gate_only
                          else [{'ansible.builtin.include_tasks': str(self.tasks / 'reinstall.yml')}])
        play = [{'name': 'Local install gate fixture', 'hosts': 'localhost', 'connection': 'local',
                 'gather_facts': False, 'vars': self.variables,
                 'tasks': selected_tasks}]
        path = self.playdir / 'test.yml'
        path.write_text(yaml.safe_dump(play, sort_keys=False))
        result = subprocess.run(['ansible-playbook', '-i', 'localhost,', str(path)],
                                cwd=self.base, env=self.env, capture_output=True, text=True, timeout=90)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def cherry(self):
        self.journal = self.base / 'provider-requests/.coco-reinstall-123.json'
        self.env['FIXTURE_JOURNAL'] = str(self.journal)
        self.variables.update(infra_provider='cherry', cherry_token='fixture-token',
                              cherry_api_base=self.variables['latitude_api_base'])
        self.variables['install_machine'].update(server_id='123', provider_hostname='allocated-node',
                                                 provider_project_id='456')
        self.provider_payload = {'id': 123, 'hostname': 'allocated-node', 'project': {'id': 456},
                                 'ip_addresses': [
                                     {'type': 'primary-ip', 'address_family': 4, 'address': '192.0.2.11'},
                                     {'type': 'private-ip', 'address_family': 4, 'address': '10.1.2.11'}]}

    def test_cherry_rebuild_posts_encoded_ipxe_after_gate_and_journal(self):
        import base64
        self.cherry()
        self.run_role()
        self.assertEqual(self.requests, ['GET', 'POST'])
        body = self.request_bodies[0]
        self.assertEqual(body['type'], 'rebuild')
        self.assertEqual(body['image'], 'custom_ipxe_install')
        self.assertEqual(body['hostname'], 'allocated-node')
        self.assertEqual(base64.b64decode(body['ipxe']).decode(), '#!ipxe\nchain --autofree http://example.invalid/fixture.ipxe\n')
        self.assertEqual(json.loads(self.journal.read_text())['state'], 'requested')

    def test_cherry_wrong_project_prevents_intent_and_post(self):
        self.cherry()
        self.provider_payload['project']['id'] = 999
        self.run_role(2)
        self.assertEqual(self.requests, ['GET'])
        self.assertFalse(self.journal.exists())

    def write_journal(self, state, identity=None):
        self.journal.parent.mkdir(exist_ok=True)
        self.journal.write_text(json.dumps({'server_id': 'sv_fixture', 'state': state,
                                           'identity': identity or self.variables['install_identity']}))

    def test_failed_gate_prevents_intent_and_post_and_closes_unused_endpoint(self):
        self.env['FIXTURE_GATE_FAIL'] = '1'
        self.run_role(2)
        self.assertEqual(self.requests, ['GET'])
        self.assertFalse(self.journal.exists())
        events = self.events.read_text().splitlines()
        self.assertIsNone(json.loads(events[0])['journal'])
        self.assertEqual(events[1], 'closed')

    def test_successful_gate_precedes_intent_and_accepted_resume_needs_no_raw_host(self):
        self.run_role()
        self.assertEqual(self.requests, ['GET', 'POST'])
        self.assertIsNone(json.loads(self.events.read_text())['journal'])
        self.assertEqual(json.loads(self.journal.read_text())['state'], 'requested')
        self.env['FIXTURE_GATE_FAIL'] = '1'
        self.run_role()
        self.assertEqual(self.requests, ['GET', 'POST'])
        self.assertEqual(len(self.events.read_text().splitlines()), 1)

    def test_ambiguous_resume_never_probes_until_explicit_retry_and_preserves_intent_on_failure(self):
        self.write_journal('sending')
        previous = self.journal.read_bytes()
        self.run_role(2)
        self.assertEqual(self.requests, [])
        self.assertFalse(self.events.exists())
        self.variables['retry_reinstall'] = True
        self.env['FIXTURE_GATE_FAIL'] = '1'
        self.run_role(2)
        self.assertEqual(self.requests, ['GET'])
        self.assertEqual(self.journal.read_bytes(), previous)
        self.assertNotIn('closed', self.events.read_text())

    def test_changed_identity_requires_explicit_override_and_fresh_proof(self):
        self.write_journal('requested', 'b' * 64)
        previous = self.journal.read_bytes()
        self.run_role(2)
        self.assertFalse(self.events.exists())
        self.variables['reinstall_existing'] = True
        self.env['FIXTURE_GATE_FAIL'] = '1'
        self.run_role(2)
        self.assertEqual(self.requests, ['GET'])
        self.assertEqual(self.journal.read_bytes(), previous)

    def test_other_machine_request_preserves_shared_endpoint_on_gate_failure(self):
        self.journal.parent.mkdir()
        other = self.journal.parent / '.coco-reinstall-sv_other.json'
        other.write_text(json.dumps({'identity': 'a' * 64, 'state': 'requested', 'server_id': 'sv_other'}))
        self.env['FIXTURE_GATE_FAIL'] = '1'
        self.run_role(2)
        self.assertEqual(self.requests, ['GET'])
        self.assertFalse(self.journal.exists())
        self.assertNotIn('closed', self.events.read_text())

    def test_other_machine_legacy_request_preserves_shared_endpoint_on_gate_failure(self):
        assets = Path(self.variables['cluster_assets_dir'])
        assets.mkdir()
        other = assets / '.coco-reinstall-sv_other.json'
        other.write_text(json.dumps({'identity': 'a' * 64, 'state': 'sending', 'server_id': 'sv_other'}))
        previous = other.read_bytes()
        self.env['FIXTURE_GATE_FAIL'] = '1'
        self.run_role(2)
        self.assertEqual(self.requests, ['GET'])
        self.assertFalse(self.journal.exists())
        self.assertEqual(other.read_bytes(), previous)
        self.assertNotIn('closed', self.events.read_text())

    def test_missing_ssh_inputs_fail_before_transport_intent_or_post(self):
        output = self.run_role(2, real_gate=True)
        self.assertIn('Fresh reinstall requires raw_node_ssh_user', output)
        self.assertEqual(self.requests, ['GET'])
        self.assertFalse(self.journal.exists())

    def configure_raw_fixture(self):
        sources = self.base / 'source'
        sources.mkdir()
        ca = self.base / 'mirror-ca.pem'
        ca.write_text('fixture public CA\n')
        (sources / 'install-config.yaml').write_text(yaml.safe_dump({
            'additionalTrustBundle': ca.read_text(), 'imageDigestSources': [
                {'source': 'registry.example/release', 'mirrors': ['mirror.rig.local:8443/openshift/release']}]}))
        agent = {'additionalNTPSources': ['192.168.66.10'], 'hosts': [{'hostname': 'fixture', 'interfaces': [
            {'name': 'eno2', 'macAddress': '02:00:00:00:00:11'}], 'networkConfig': {
                'interfaces': [{'name': 'eno2.2032', 'vlan': {'id': 2032, 'base-iface': 'eno2'},
                                'ipv4': {'address': [{'ip': '192.168.66.11', 'prefix-length': 24}]}}],
                'dns-resolver': {'config': {'server': ['192.168.66.10']}}}}]}
        (sources / 'agent-config.yaml').write_text(yaml.safe_dump(agent))
        installer = self.bin / 'openshift-install'
        installer.write_text('fixture installer')
        key = self.base / 'ssh-key'
        key.write_text('fixture unused private key')
        key.chmod(0o600)
        pins = self.base / 'known_hosts'
        pins.write_text('fixture unused host pins')
        pins.chmod(0o600)
        payload = 'registry.example/release@sha256:' + 'a' * 64
        identity = {'configs': [hashlib.sha256((sources / name).read_bytes()).hexdigest()
                                 for name in ('install-config.yaml', 'agent-config.yaml')],
                    'installer': hashlib.sha256(installer.read_bytes()).hexdigest(),
                    'release': payload, 'version': '4.20.39'}
        self.variables.update(install_src_dir=str(sources), mirror_ca_path=str(ca),
                              raw_node_ssh_user='rocky', raw_node_ssh_key=str(key),
                              bastion_ssh_key=str(key), private_link_known_hosts=str(pins),
                              ansible_user='rocky', ansible_host='192.0.2.10',
                              local_bin=str(self.bin), vlan_vid=2032, vlan_prefix=24, bastion_vlan_ip='192.168.66.10',
                              mirror_dns_name='mirror.rig.local', mirror_endpoint='mirror.rig.local:8443',
                              ocp_release_image=payload,
                              install_identity=hashlib.sha256(json.dumps(identity).encode()).hexdigest())
        ip = self.bin / 'ip'
        ip.write_text('''#!/usr/bin/env python3
import json,os
print(json.dumps([{'ifname':'eno2','ifindex':2,'address':os.environ.get('FIXTURE_RAW_MAC','02:00:00:00:00:11')},
 {'ifname':'eno2.2032','ifindex':3,'link_index':2}]))
''')
        ip.chmod(0o755)
        scripts = self.fixture / 'scripts'
        scripts.mkdir(exist_ok=True)
        (scripts / 'check-private-link.py').write_text('''import json,os,pathlib,sys
args=sys.argv[1:]
status=os.environ.get('FIXTURE_PROOF_STATUS','PASS')
pathlib.Path(args[args.index('--evidence')+1]).write_text(json.dumps({'status':status}))
pathlib.Path(os.environ['FIXTURE_EVENTS']).open('a').write(json.dumps({'checkerArgs':args})+'\\n')
raise SystemExit(0 if status=='PASS' else 1)
''')

    def test_real_gate_binds_current_inputs_and_retains_private_evidence(self):
        self.configure_raw_fixture()
        self.run_role(real_gate=True)
        self.assertEqual(self.requests, ['GET', 'POST'])
        args = json.loads(self.events.read_text())['checkerArgs']
        self.assertEqual(args[args.index('--interface') + 1], 'eno2.2032')
        self.assertEqual(args[args.index('--node-ip') + 1], '192.168.66.11')
        records = list((self.base / 'state/validation/private-link').glob('sv_fixture-*/result.json'))
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0].stat().st_mode & 0o777, 0o600)
        self.assertEqual(json.loads(records[0].read_text())['checker']['status'], 'PASS')
        identity = json.loads(records[0].with_name('identity.json').read_text())
        self.assertEqual(identity['install_identity'], self.variables['install_identity'])
        self.assertEqual(identity['raw_address'], '192.0.2.11')
        self.assertFalse(list(self.base.glob('coco-private-link-*')))

    def test_real_failed_probe_retains_errors_without_post_or_intent(self):
        self.configure_raw_fixture()
        self.env['FIXTURE_PROOF_STATUS'] = 'FAIL'
        self.run_role(2, real_gate=True)
        self.assertEqual(self.requests, ['GET'])
        self.assertFalse(self.journal.exists())
        records = list((self.base / 'state/validation/private-link').glob('sv_fixture-*/result.json'))
        self.assertEqual(json.loads(records[0].read_text())['checker']['status'], 'FAIL')
        self.assertEqual(records[0].stat().st_mode & 0o777, 0o600)
        self.assertIn('closed', self.events.read_text())

    def test_raw_mac_mismatch_stops_before_checker_or_provider_post(self):
        self.configure_raw_fixture()
        self.env['FIXTURE_RAW_MAC'] = '02:00:00:00:00:99'
        output = self.run_role(2, real_gate=True)
        self.assertIn('Raw private NIC/VLAN', output)
        self.assertEqual(self.requests, ['GET'])
        self.assertFalse(self.journal.exists())
        self.assertEqual(self.events.read_text().strip(), 'closed')

    def test_changed_ca_and_unbuilt_source_revision_cannot_authorize_install(self):
        self.configure_raw_fixture()
        ca = Path(self.variables['mirror_ca_path'])
        ca.write_text('other CA\n')
        self.assertIn('mirror trust differs', self.run_role(2, real_gate=True))
        ca.write_text('fixture public CA\n')
        self.variables['install_identity'] = 'f' * 64
        self.assertIn('changed after PXE generation', self.run_role(2, real_gate=True))
        self.assertEqual(self.requests, ['GET', 'GET'])
        self.assertFalse(self.journal.exists())

    def test_prepared_vlan_on_wrong_parent_fails_even_with_current_artifact_identity(self):
        self.configure_raw_fixture()
        source = Path(self.variables['install_src_dir'])
        agent_file = source / 'agent-config.yaml'
        agent = yaml.safe_load(agent_file.read_text())
        agent['hosts'][0]['networkConfig']['interfaces'][0]['vlan']['base-iface'] = 'eno1'
        agent_file.write_text(yaml.safe_dump(agent))
        identity = {'configs': [hashlib.sha256((source / name).read_bytes()).hexdigest()
                                 for name in ('install-config.yaml', 'agent-config.yaml')],
                    'installer': hashlib.sha256((self.bin / 'openshift-install').read_bytes()).hexdigest(),
                    'release': self.variables['ocp_release_image'], 'version': self.variables['ocp_version']}
        self.variables['install_identity'] = hashlib.sha256(json.dumps(identity).encode()).hexdigest()
        output = self.run_role(2, real_gate=True)
        self.assertIn('Raw private NIC/VLAN', output)
        self.assertEqual(self.requests, ['GET'])
        self.assertFalse(self.journal.exists())
        self.assertEqual(self.events.read_text().strip(), 'closed')

    def test_changed_runtime_mirror_cannot_prove_a_different_prepared_registry(self):
        self.configure_raw_fixture()
        self.variables['mirror_endpoint'] = 'other.rig.local:8443'
        self.variables['mirror_dns_name'] = 'other.rig.local'
        output = self.run_role(2, real_gate=True)
        self.assertIn('service endpoint or mirror trust differs', output)
        self.assertEqual(self.requests, ['GET'])
        self.assertFalse(self.journal.exists())
        self.assertEqual(self.events.read_text().strip(), 'closed')


    def refresh_artifact_identity(self):
        source = Path(self.variables['install_src_dir'])
        identity = {'configs': [hashlib.sha256((source / name).read_bytes()).hexdigest()
                                for name in ('install-config.yaml', 'agent-config.yaml')],
                    'installer': hashlib.sha256((self.bin / 'openshift-install').read_bytes()).hexdigest(),
                    'release': self.variables['ocp_release_image'], 'version': self.variables['ocp_version']}
        self.variables['install_identity'] = hashlib.sha256(json.dumps(identity).encode()).hexdigest()

    def configure_public_fixture(self):
        self.configure_raw_fixture()
        self.variables.update(network_profile='public-routed-lab', node_public_ipv4='192.0.2.11',
                              node_public_prefix=31, node_public_gateway='192.0.2.10',
                              bastion_service_ip='198.51.100.10', ansible_host='198.51.100.10',
                              air_gap=False, enforce_node_egress=False,
                              provider_machine={'json': {'data': {'id': 'sv_fixture', 'attributes': {
                                  'primary_ipv4': '192.0.2.11', 'interfaces': self.provider_interfaces}}}})
        self.variables['install_machine'].update(external_if='eno1', external_mac='02:00:00:00:00:12')
        self.public_agent = {'rendezvousIP': '192.0.2.11', 'additionalNTPSources': ['198.51.100.10'], 'hosts': [{
            'hostname': 'fixture', 'interfaces': [
                {'name': 'eno2', 'macAddress': '02:00:00:00:00:11'},
                {'name': 'eno1', 'macAddress': '02:00:00:00:00:12'}],
            'networkConfig': {'interfaces': [
                {'name': 'eno2', 'type': 'ethernet', 'state': 'down',
                 'ipv4': {'enabled': False}, 'ipv6': {'enabled': False}},
                {'name': 'eno1', 'type': 'ethernet', 'state': 'up',
                 'ipv4': {'enabled': True, 'dhcp': False, 'address': [{'ip': '192.0.2.11', 'prefix-length': 31}]},
                 'ipv6': {'enabled': False}}],
                'dns-resolver': {'config': {'server': ['198.51.100.10']}},
                'routes': {'config': [{'destination': '0.0.0.0/0', 'next-hop-address': '192.0.2.10',
                                      'next-hop-interface': 'eno1'}]}}}]}
        install_file = Path(self.variables['install_src_dir']) / 'install-config.yaml'
        install = yaml.safe_load(install_file.read_text())
        install['networking'] = {'machineNetwork': [{'cidr': '192.0.2.10/31'}]}
        install_file.write_text(yaml.safe_dump(install))
        self.save_public_agent()
        (self.bin / 'ip').write_text('''#!/usr/bin/env python3
import json,os
print(json.dumps([{'ifname':'eno2','ifindex':2,'address':'02:00:00:00:00:11'},
 {'ifname':'eno1','ifindex':1,'address':os.environ.get('FIXTURE_RAW_MAC','02:00:00:00:00:12')}]))
''')

    def save_public_agent(self):
        (Path(self.variables['install_src_dir']) / 'agent-config.yaml').write_text(yaml.safe_dump(self.public_agent))
        self.refresh_artifact_identity()

    def test_public_reinstall_has_no_bypass_and_never_queries_or_sends_provider(self):
        self.variables.update(network_profile='public-routed-lab', public_ingress_verified=True,
                              retry_reinstall=True, reinstall_existing=True)
        output = self.run_role(2)
        self.assertIn('public-routed-lab reinstall is currently blocked', output)
        self.assertEqual(self.requests, [])
        self.assertFalse(self.journal.exists())
        self.assertFalse(self.events.exists())

    def test_public_gate_only_binds_provider_source_mac_gateway_and_evidence(self):
        self.configure_public_fixture()
        output = self.run_role(real_gate=True, gate_only=True)
        self.assertEqual(self.requests, [])
        self.assertFalse(self.journal.exists())
        args = json.loads(self.events.read_text())['checkerArgs']
        expected = {'--network-mode': 'public-routed-lab', '--interface': 'eno1', '--node-ip': '192.0.2.11',
                    '--gateway': '192.0.2.10', '--prefix-length': '31', '--expected-mac': '02:00:00:00:00:12',
                    '--bastion-ip': '198.51.100.10'}
        for flag, value in expected.items():
            self.assertEqual(args[args.index(flag) + 1], value)
        self.assertNotIn('--vid', args)
        records = list((self.base / 'state/validation/private-link').glob('sv_fixture-*/identity.json'))
        identity = json.loads(records[0].read_text())
        self.assertEqual(identity['network_profile'], 'public-routed-lab')
        self.assertEqual(identity['reviewed_gateway'], '192.0.2.10')
        self.assertNotIn('private_mac', identity)
        self.assertIn('public-routed-lab path proof passed', output)
        self.assertFalse(list(self.base.glob('coco-private-link-*')))

    def test_public_gate_rejects_prepared_route_mismatch_even_with_current_identity(self):
        self.configure_public_fixture()
        self.public_agent['hosts'][0]['networkConfig']['routes']['config'][0]['next-hop-address'] = '192.0.2.12'
        self.save_public_agent()
        output = self.run_role(2, real_gate=True, gate_only=True)
        self.assertIn('reviewed gateway', output)
        self.assertFalse(self.events.exists())
        self.assertFalse(self.journal.exists())

    def test_public_gate_rejects_stale_rendezvous_or_machine_network_with_recomputed_identity(self):
        self.configure_public_fixture()
        self.public_agent['rendezvousIP'] = '192.168.66.11'
        self.save_public_agent()
        output = self.run_role(2, real_gate=True, gate_only=True)
        self.assertIn('private_link_prepared_rendezvous == node_public_ipv4', output)
        self.assertIn('"evaluated_to": false', output)
        self.assertFalse(self.events.exists())
        self.public_agent['rendezvousIP'] = self.variables['node_public_ipv4']
        self.save_public_agent()
        install_file = Path(self.variables['install_src_dir']) / 'install-config.yaml'
        install = yaml.safe_load(install_file.read_text())
        install['networking']['machineNetwork'] = [{'cidr': '192.168.66.0/24'}]
        install_file.write_text(yaml.safe_dump(install))
        self.refresh_artifact_identity()
        output = self.run_role(2, real_gate=True, gate_only=True)
        self.assertIn('private_link_prepared_machine_networks ==', output)
        self.assertIn('"evaluated_to": false', output)
        self.assertFalse(self.events.exists())
        self.assertFalse(self.journal.exists())

    def test_public_gate_rejects_internal_mac_as_public_before_any_probe(self):
        self.configure_public_fixture()
        self.env['FIXTURE_RAW_MAC'] = '02:00:00:00:00:11'
        output = self.run_role(2, real_gate=True, gate_only=True)
        self.assertIn('Raw public NIC/provider MAC', output)
        self.assertFalse(self.events.exists())
        self.assertFalse(self.journal.exists())

    def test_public_gate_requires_current_provider_ip_and_no_airgap_claim(self):
        self.configure_public_fixture()
        for key, value in [('node_public_ipv4', '192.0.2.12'), ('air_gap', True),
                           ('air_gap', 'unexpected'), ('enforce_node_egress', 'unexpected'),
                           ('node_public_prefix', 24)]:
            original = self.variables[key]
            self.variables[key] = value
            with self.subTest(key=key):
                output = self.run_role(2, real_gate=True, gate_only=True)
                self.assertIn("provider's current public IP", output)
                self.assertFalse(self.events.exists())
            self.variables[key] = original



if __name__ == '__main__':
    unittest.main()
