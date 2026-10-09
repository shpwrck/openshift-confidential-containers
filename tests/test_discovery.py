"""Discovery identity gates and real Ansible load/render behavior; no live provider."""
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
import unittest
from unittest.mock import patch

import yaml

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'scripts/discover-node-macs.py'
spec = importlib.util.spec_from_file_location('node_macs', SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def machine(**values):
    return dict(name='sno-node', server_id='123', parent_if='eno2',
                external_if='eno1', parent_mac='', external_mac='',
                root_device='/dev/sda', vlan_ip='192.0.2.11', role='master', **values)


def cached_bindings(machines):
    return {'version': 1, 'bindings': [dict(name=m['name'], server_id=m['server_id'],
        parent_mac='02:00:00:00:00:01', external_mac='02:00:00:00:00:02' if m.get('external_if') else '')
        for m in machines]}


def response(server_id=123):
    return {'id': server_id, 'hostname': 'allocated-node', 'project': {'id': 456}, 'ip_addresses': [
        {'type': 'primary-ip', 'address_family': 4, 'address': '198.51.100.11'},
        {'type': 'private-ip', 'address_family': 4, 'address': '192.0.2.11'}]}


class DiscoveryTests(unittest.TestCase):
    def setUp(self):
        self.machines = [machine()]

    def rejected(self, text, operation):
        with self.assertRaisesRegex(module.InvalidDiscovery, text):
            operation()

    def test_cache_stores_only_identity_and_macs(self):
        cache = cached_bindings(self.machines)
        self.assertEqual(set(cache['bindings'][0]), {'name', 'server_id', 'parent_mac', 'external_mac'})
        self.assertEqual(module.merge(self.machines, cache)[0]['parent_mac'], '02:00:00:00:00:01')

    def test_machine_identity_must_be_unique_and_real(self):
        self.rejected('unique', lambda: module.check_machines(self.machines * 2))
        for bad_id in ('', 'REPLACE_WITH_CHERRY_SERVER_ID', '../servers'):
            self.rejected('server_id', lambda: module.check_machines([dict(machine(), server_id=bad_id)]))

    def test_malformed_zero_multicast_and_duplicate_macs_fail(self):
        for bad in ('', '00:00:00:00:00:00', 'ff:ff:ff:ff:ff:ff', '01:00:00:00:00:01', 'not-a-mac'):
            self.rejected('MAC', lambda: module.mac(bad))
        duplicate = dict(machine(), parent_mac='02:00:00:00:00:01', external_mac='02:00:00:00:00:01')
        self.rejected('unique', lambda: module.merge([duplicate]))

    def test_missing_configured_public_nic_fails(self):
        manual = dict(machine(), parent_mac='02:00:00:00:00:01')
        self.rejected('Configured public NIC', lambda: module.merge([manual]))

    def test_cached_public_mac_cannot_be_omitted_by_clearing_interface_name(self):
        cache = cached_bindings(self.machines)
        self.machines[0]['external_if'] = ''
        self.rejected('no external_if', lambda: module.merge(self.machines, cache))

    def test_manual_public_mac_requires_interface_name(self):
        manual = dict(machine(), parent_mac='02:00:00:00:00:01',
                      external_if='', external_mac='02:00:00:00:00:02')
        self.rejected('no external_if', lambda: module.merge([manual]))
        # A whitespace-only value is not an interface name either.
        manual['external_if'] = ' '
        self.rejected('name an interface', lambda: module.merge([manual]))
        manual['external_if'] = ''
        manual['external_mac'] = ''
        self.assertEqual(module.merge([manual]), [manual])

    def test_duplicate_macs_across_different_servers_fail(self):
        second = dict(machine(), name='node-two', server_id='124')
        self.rejected('unique', lambda: module.merge([machine(), second], cached_bindings([machine(), second])))

    def test_changed_name_or_server_rejects_stale_cache(self):
        cache = cached_bindings(self.machines)
        for field, value in (('server_id', '125'), ('name', 'renamed-node')):
            self.rejected('different machines', lambda: module.merge([dict(machine(), **{field: value})], cache))

    def test_cache_cannot_supply_disk_or_network_settings(self):
        cache = cached_bindings(self.machines)
        cache['bindings'][0]['root_device'] = '/dev/old-disk'
        self.rejected('only server identity', lambda: module.merge(self.machines, cache))

    def test_current_disk_network_and_nic_names_are_preserved(self):
        cache = cached_bindings(self.machines)
        current = dict(machine(), root_device='/dev/new-disk', vlan_ip='192.0.2.99',
                       parent_if='private0', external_if='public0')
        merged = module.merge([current], cache)[0]
        for field in ('root_device', 'vlan_ip', 'parent_if', 'external_if'):
            self.assertEqual(merged[field], current[field])
        self.assertEqual(current['parent_mac'], '')  # Caller inputs are not mutated.

    def test_explicit_macs_work_without_cache_and_win_over_cached_values(self):
        explicit = dict(machine(), parent_mac='02:00:00:00:01:01', external_mac='02:00:00:00:01:02')
        self.assertEqual(module.merge([explicit]), [explicit])
        cache = cached_bindings(self.machines)
        self.assertEqual(module.merge([explicit], cache), [explicit])

    def test_begin_validates_inputs_before_invalidating_cache(self):
        with tempfile.TemporaryDirectory() as directory:
            env = dict(os.environ, COCO_STATE_DIR=directory)
            with patch.dict(os.environ, COCO_STATE_DIR=directory):
                path = module.cache_path()
                module.write_cache(path, cached_bindings(self.machines))
            for machines, expected, exists in (([], 1, True), (self.machines, 0, False)):
                result = subprocess.run([sys.executable, str(SCRIPT), 'begin'],
                                        input=json.dumps({'machines': machines}), env=env,
                                        text=True, capture_output=True, check=False)
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assertEqual(path.exists(), exists)

    def test_external_cache_write_is_atomic_private_and_idempotent(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, COCO_STATE_DIR=directory):
            path = module.cache_path()
            cache = cached_bindings(self.machines)
            self.assertTrue(module.write_cache(path, cache))
            self.assertFalse(module.write_cache(path, cache))
            self.assertEqual(json.loads(path.read_text()), cache)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(path.parent.stat().st_mode & 0o777, 0o700)
        with patch.dict(os.environ, COCO_STATE_DIR=str(ROOT / 'generated')):
            self.rejected('outside', module.cache_path)


@unittest.skipUnless(shutil.which('ansible-playbook'), 'requires local Ansible')
class DiscoveryAnsibleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='coco-discovery-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        config = self.base / 'ansible.cfg'
        config.write_text('[defaults]\nstdout_callback=default\nretry_files_enabled=False\n')
        self.env = dict(os.environ, ANSIBLE_CONFIG=str(config), COCO_STATE_DIR=str(self.base / 'state'),
                        ANSIBLE_LOCAL_TEMP=str(self.base / 'local'), ANSIBLE_REMOTE_TEMP=str(self.base / 'remote'))
        self.variables = {'ansible_python_interpreter': sys.executable}

    def run_play(self, tasks, extra=None, expected=0):
        # Only the helper's location is adjusted; the tasks and Jinja data flow are production code.
        encoded = yaml.safe_dump(tasks).replace('{{ playbook_dir }}/../../scripts/discover-node-macs.py', str(SCRIPT))
        encoded = encoded.replace('tasks/discovery-cherry.yml', str(ROOT / 'ansible/playbooks/tasks/discovery-cherry.yml'))
        encoded = encoded.replace('{{ playbook_dir }}/../../scripts/provider-identity.py', str(ROOT / 'scripts/provider-identity.py'))
        tasks = yaml.safe_load(encoded)
        play = self.base / 'play.yml'
        play.write_text(yaml.safe_dump([{'hosts': 'localhost', 'connection': 'local', 'gather_facts': False,
                                        'vars': self.variables, 'tasks': tasks}]))
        extra_file = self.base / 'input.json'
        extra_file.write_text(json.dumps(extra or {}))
        result = subprocess.run(['ansible-playbook', '-i', 'localhost,', str(play), '-e', '@' + str(extra_file)],
                                env=self.env, cwd=self.base, capture_output=True, text=True, timeout=60)
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, expected, output)
        return output

    def start_api(self, status=200, document=None):
        calls = []
        document = document if document is not None else response()
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass
            def do_GET(self):
                calls.append((self.path, self.headers.get('Authorization')))
                self.send_response(status)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps(document).encode())
        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return f'http://127.0.0.1:{server.server_port}', calls

    def discovery_tasks(self):
        tasks = yaml.safe_load((ROOT / 'ansible/playbooks/discover.yml').read_text())[0]['tasks']
        # Inline the included production tasks so fixture path normalization reaches their CLIs.
        expanded = []
        for task in tasks:
            if task.get('ansible.builtin.include_tasks') == 'tasks/discovery-cherry.yml':
                expanded.extend(yaml.safe_load((ROOT / 'ansible/playbooks/tasks/discovery-cherry.yml').read_text()))
            else:
                expanded.append(task)
        return expanded

    def merge_and_render_tasks(self):
        phase = next(play for play in yaml.safe_load((ROOT / 'ansible/playbooks/site.yml').read_text())
                     if play.get('name', '').startswith('Phase C'))
        return copy.deepcopy(phase['pre_tasks']) + [{'ansible.builtin.template': {
            'src': str(ROOT / 'ansible/roles/render_configs/templates/agent-config.yaml.j2'),
            'dest': str(self.base / 'agent-config.yaml'), 'mode': '0600'}}]

    def render_variables(self):
        return dict(cluster_name='fixture', node_vlan_ip='192.0.2.11', boot_artifacts_base_url='http://192.0.2.10:8080/fixture',
                    additional_ntp_sources=['192.0.2.10'], vlan_vid=1234, vlan_prefix=24, bastion_vlan_ip='192.0.2.10',
                    mirror_dns_name='mirror.fixture.invalid')

    def render_disk_fixture(self):
        self.variables.update(yaml.safe_load((ROOT / 'ansible/group_vars/all.yml').read_text()))
        self.variables.update(self.render_variables())
        self.variables.update(boot_artifacts_token='a' * 32, bastion_public_ipv4='192.0.2.10',
                              install_src_dir=str(self.base / 'install/src'),
                              cluster_assets_dir=str(self.base / 'install/cluster-assets'))
        tasks = yaml.safe_load((ROOT / 'ansible/roles/render_configs/tasks/main.yml').read_text())
        first_write = next(index for index, task in enumerate(tasks)
                           if task['name'] == 'Ensure the install src + cluster-assets dirs exist')
        # Execute the real guard sequence AND its first filesystem mutation. This catches a
        # guard moved below directory creation, without needing mirror credentials or a host.
        selected = copy.deepcopy(tasks[:first_write + 1])
        render = copy.deepcopy(next(task for task in tasks if task['name'] == 'Render agent-config.yaml into the src dir'))
        render['ansible.builtin.template']['src'] = str(ROOT / 'ansible/roles/render_configs/templates/agent-config.yaml.j2')
        selected.append(render)
        for task in selected:
            task['become'] = False
            task['no_log'] = False  # Fixture paths and MACs only.
            for action in ('ansible.builtin.file', 'ansible.builtin.template'):
                if action in task:
                    task[action].pop('owner', None)
                    task[action].pop('group', None)
        return selected

    def test_default_node_disk_must_be_supplied_before_renderer_writes(self):
        tasks = self.render_disk_fixture()
        output = self.run_play(tasks, {'node_server_id': '127',
                                      'node_parent_mac': '02:00:00:00:01:01',
                                      'node_external_mac': '02:00:00:00:01:02'}, expected=2)
        self.assertIn('Verify the intended', output)
        self.assertIn('/dev/disk/by-path/', output)
        self.assertFalse((self.base / 'install').exists())

    def test_each_machine_needs_a_valid_explicit_disk_before_renderer_writes(self):
        tasks = self.render_disk_fixture()
        verified = dict(machine(), parent_mac='02:00:00:00:00:01')
        for value in (None, '', 'nvme0n1', '/dev/', '/tmp/disk', '/dev/../sda', '/dev/sda\n'):
            invalid = dict(verified, name='second-node', root_device=value)
            if value is None:
                invalid.pop('root_device')
            with self.subTest(root_device=value):
                output = self.run_play(tasks, {'machines': [verified, invalid]}, expected=2)
                self.assertIn('requires an explicit absolute /dev/', output)
                self.assertFalse((self.base / 'install').exists())

    def test_verified_stable_and_explicit_device_paths_render_unchanged(self):
        tasks = self.render_disk_fixture()
        paths = ['/dev/disk/by-path/pci-0000:c2:00.0-nvme-1', '/dev/nvme0n1', '/dev/sda']
        effective = [dict(machine(), name=f'node-{index}', parent_mac=f'02:00:00:00:00:{index + 1:02x}',
                          root_device=path) for index, path in enumerate(paths)]
        # Both the guard and template must use the already validated discovery output.
        self.run_play(tasks, {'machines': [dict(machine(), root_device='')], 'discovery_machines': effective})
        rendered = yaml.safe_load((self.base / 'install/src/agent-config.yaml').read_text())
        self.assertEqual([host['rootDeviceHints']['deviceName'] for host in rendered['hosts']], paths)

    def cherry_inputs(self, base_url):
        key, pins = self.base / 'key', self.base / 'known_hosts'
        key.write_text('unused fixture private key'); key.chmod(0o600)
        pins.write_text('unused fixture pins'); pins.chmod(0o600)
        ports = [{'name': 'eth0', 'mac': '02:00:00:00:00:01'}, {'name': 'eth1', 'mac': '02:00:00:00:00:02'}]
        node = dict(machine(), parent_if='bond0', parent_mac=ports[0]['mac'], external_if='',
                    provider_hostname='allocated-node', provider_project_id='456', bond_mode='802.3ad', bond_ports=ports)
        raw = {'hostname': 'allocated-node', 'links': [
            {'ifname': 'bond0', 'address': ports[0]['mac'], 'linkinfo': {'info_kind': 'bond'}},
            *[{'ifname': x['name'], 'link_type': 'ether', 'master': 'bond0', 'address': x['mac']} for x in ports]],
            'addresses': [{'addr_info': [{'local': '198.51.100.11'}, {'local': '192.0.2.11'}]}]}
        bin_dir = self.base / 'bin'; bin_dir.mkdir(exist_ok=True)
        ssh = bin_dir / 'ssh'
        ssh.write_text('#!' + sys.executable + '\nimport os,pathlib\npathlib.Path(os.environ["FIXTURE_SSH_CALL"]).touch()\nprint(os.environ["FIXTURE_SSH_DATA"])\n')
        ssh.chmod(0o755)
        self.env.update(PATH=str(bin_dir) + os.pathsep + os.environ['PATH'], FIXTURE_SSH_DATA=json.dumps(raw),
                        FIXTURE_SSH_CALL=str(self.base / 'ssh-called'))
        return {'machines': [node], 'infra_provider': 'cherry', 'cherry_api_base': base_url,
                'cherry_token': 'fixture-sensitive-token', 'raw_node_ssh_user': 'root',
                'raw_node_ssh_key': str(key), 'private_link_known_hosts': str(pins)}

    def test_real_discovery_then_render_keeps_extra_var_disk_network_and_nic_changes(self):
        base_url, calls = self.start_api()
        inputs = self.cherry_inputs(base_url)
        output = self.run_play(self.discovery_tasks(), inputs)
        self.assertNotIn('fixture-sensitive-token', output)
        self.assertEqual(calls, [('/servers/123', 'Bearer fixture-sensitive-token')])
        cache = Path(self.env['COCO_STATE_DIR']) / 'discovery/node-macs.json'
        self.assertTrue(cache.is_file())
        self.variables.update(self.render_variables())
        current = dict(inputs['machines'][0], root_device='/dev/current-disk', vlan_ip='192.0.2.99', parent_if='private0')
        self.run_play(self.merge_and_render_tasks(), {'machines': [current]})
        host = yaml.safe_load((self.base / 'agent-config.yaml').read_text())['hosts'][0]
        self.assertEqual(host['rootDeviceHints']['deviceName'], '/dev/current-disk')
        self.assertEqual(host['interfaces'], [{'name': x['name'], 'macAddress': x['mac']} for x in current['bond_ports']])
        vlan = host['networkConfig']['interfaces'][-1]
        self.assertEqual(vlan['ipv4']['address'][0]['ip'], '192.0.2.99')
        self.run_play(self.merge_and_render_tasks(), {'machines': [dict(current, server_id='126')]}, expected=2)

    def test_api_failure_censors_token(self):
        base_url, calls = self.start_api(status=500)
        with patch.dict(os.environ, COCO_STATE_DIR=self.env['COCO_STATE_DIR']):
            module.write_cache(module.cache_path(), cached_bindings([machine()]))
        output = self.run_play(self.discovery_tasks(), self.cherry_inputs(base_url), expected=2)
        self.assertNotIn('fixture-sensitive-token', output)
        self.assertEqual(len(calls), 1)
        self.assertFalse((Path(self.env['COCO_STATE_DIR']) / 'discovery/node-macs.json').exists())
        self.variables.update(self.render_variables())
        output = self.run_play(self.merge_and_render_tasks(), {'machines': [machine()]}, expected=2)
        self.assertIn('Missing internal MAC', output)
        self.assertFalse((self.base / 'agent-config.yaml').exists())

    def test_wrong_api_identity_invalidates_existing_cache(self):
        base_url, _ = self.start_api(document=response(server_id=999))
        with patch.dict(os.environ, COCO_STATE_DIR=self.env['COCO_STATE_DIR']):
            cache = module.cache_path()
            module.write_cache(cache, cached_bindings([machine()]))
        output = self.run_play(self.discovery_tasks(), self.cherry_inputs(base_url), expected=2)
        self.assertFalse((self.base / 'ssh-called').exists())
        self.assertFalse(cache.exists())

    def test_render_rejects_unnamed_cached_public_nic_and_allows_true_single_nic(self):
        self.variables.update(self.render_variables())
        with patch.dict(os.environ, COCO_STATE_DIR=self.env['COCO_STATE_DIR']):
            path = module.cache_path()
            module.write_cache(path, cached_bindings([machine()]))
        current = dict(machine(), external_if='')
        output = self.run_play(self.merge_and_render_tasks(), {'machines': [current]}, expected=2)
        self.assertIn('no external_if', output)
        self.assertFalse((self.base / 'agent-config.yaml').exists())
        # A confirmed single-NIC API response has neither an external name nor MAC.
        module.write_cache(path, cached_bindings([current]))
        self.run_play(self.merge_and_render_tasks(), {'machines': [current]})
        host = yaml.safe_load((self.base / 'agent-config.yaml').read_text())['hosts'][0]
        self.assertEqual(host['interfaces'], [{'name': 'eno2', 'macAddress': '02:00:00:00:00:01'}])
        self.assertEqual([nic['name'] for nic in host['networkConfig']['interfaces']], ['eno2', 'eno2.1234'])

    def test_public_nic_render_gate_requires_mac_even_with_old_bypass(self):
        tasks = yaml.safe_load((ROOT / 'ansible/roles/render_configs/tasks/main.yml').read_text())
        gate = next(task for task in tasks if task['name'].startswith('Fail closed if the public NIC'))
        self.variables['mirror_dns_name'] = 'mirror.fixture.invalid'
        for external_if, external_mac, expected in (('eno1', '', 2), ('', '', 0),
                                                    ('eno1', '02:00:00:00:00:02', 0)):
            with self.subTest(external_if=external_if, external_mac=external_mac):
                self.run_play([gate], {'machines': [dict(machine(), external_if=external_if,
                                                         external_mac=external_mac)],
                                       'allow_unmanaged_public_nic': True}, expected=expected)

    def test_single_node_overrides_render_without_discovery_cache(self):
        # Load the real all.yml defaults so node_* expressions use actual Ansible precedence.
        defaults = yaml.safe_load((ROOT / 'ansible/group_vars/all.yml').read_text())
        self.variables.update(defaults)
        self.variables.update(self.render_variables())
        self.run_play(self.merge_and_render_tasks(), {'node_server_id': '127', 'node_root_device': '/dev/sda',
                      'node_parent_if': 'eno2', 'node_external_if': 'eno1',
                      'node_parent_mac': '02:00:00:00:01:01', 'node_external_mac': '02:00:00:00:01:02'})
        host = yaml.safe_load((self.base / 'agent-config.yaml').read_text())['hosts'][0]
        self.assertEqual(host['interfaces'][0], {'name': 'eno2', 'macAddress': '02:00:00:00:01:01'})
        self.assertEqual(host['rootDeviceHints']['deviceName'], '/dev/sda')


if __name__ == '__main__':
    unittest.main()
