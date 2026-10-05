"""Exercise real render guards/templates offline; no provider or remote host access."""
import copy
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
ROLE = ROOT / 'ansible/roles/render_configs'


@unittest.skipUnless(shutil.which('ansible-playbook'), 'requires local Ansible')
class PublicRoutedProfileTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='coco-public-profile-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.src = self.base / 'install/src'
        config = self.base / 'ansible.cfg'
        config.write_text('[defaults]\nstdout_callback=default\nretry_files_enabled=False\n')
        self.env = dict(os.environ, ANSIBLE_CONFIG=str(config),
                        ANSIBLE_LOCAL_TEMP=str(self.base / 'local'),
                        ANSIBLE_REMOTE_TEMP=str(self.base / 'remote'))
        (self.base / 'mirror-auth.json').write_text(json.dumps({'auths': {
            'mirror.fixture.invalid:8443': {'auth': 'Zml4dHVyZTpmaXh0dXJl'}}}))
        (self.base / 'ca.pem').write_text('FIXTURE PUBLIC CA\n')
        (self.base / 'controller.pub').write_text('ssh-ed25519 Zml4dHVyZQ== fixture\n')
        self.variables = yaml.safe_load((ROOT / 'ansible/group_vars/all.yml').read_text())
        self.variables.update({
            'ansible_python_interpreter': sys.executable,
            'cluster_name': 'fixture', 'base_domain': 'fixture.invalid',
            'node_server_id': 'sv_fixture', 'node_root_device': '/dev/disk/by-path/fixture',
            'node_parent_if': 'private0', 'node_parent_mac': '02:00:00:00:00:01',
            'node_external_if': 'public0', 'node_external_mac': '02:00:00:00:00:02',
            'node_public_ipv4': '192.0.2.11', 'node_public_prefix': 31,
            'node_public_gateway': '192.0.2.10', 'bastion_public_ipv4': '198.51.100.9',
            'vlan_vid': 1234, 'boot_artifacts_token': 'f' * 32,
            'mirror_endpoint': 'mirror.fixture.invalid:8443', 'mirror_dns_name': 'mirror.fixture.invalid',
            'mirror_pull_secret': str(self.base / 'mirror-auth.json'),
            'mirror_ca_path': str(self.base / 'ca.pem'),
            'node_ssh_pubkey_src': str(self.base / 'controller.pub'),
            'node_ssh_pubkey_path': str(self.base / 'bastion.pub'),
            'install_src_dir': str(self.src), 'cluster_assets_dir': str(self.base / 'install/assets'),
        })
        self.tasks = copy.deepcopy(yaml.safe_load((ROLE / 'tasks/main.yml').read_text()))

        def localize(tasks):
            for task in tasks:
                # Real conditions/actions; only local fixture permissions/template location differ.
                task['become'] = False
                for action in ('ansible.builtin.file', 'ansible.builtin.template'):
                    if action in task:
                        task[action].pop('owner', None)
                        task[action].pop('group', None)
                if 'ansible.builtin.template' in task:
                    item = task['ansible.builtin.template']
                    item['src'] = str(ROLE / 'templates' / item['src'])
                for section in ('block', 'rescue', 'always'):
                    if section in task:
                        localize(task[section])
        localize(self.tasks)

    def run_render(self, overrides=None, success=True):
        play = self.base / 'play.yml'
        play.write_text(yaml.safe_dump([{'hosts': 'localhost', 'connection': 'local',
                                        'gather_facts': False, 'vars': self.variables,
                                        'tasks': self.tasks}]))
        extra = self.base / 'overrides.json'
        extra.write_text(json.dumps(overrides or {}))
        result = subprocess.run(['ansible-playbook', '-i', 'localhost,', str(play), '-e', '@' + str(extra)],
                                env=self.env, cwd=self.base, capture_output=True, text=True, timeout=60)
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0 if success else 2, output)
        if not success:
            self.assertFalse(self.src.exists(), 'invalid inputs created installer source directory')
            return output
        return tuple(yaml.safe_load((self.src / name).read_text())
                     for name in ('install-config.yaml', 'agent-config.yaml'))

    def public(self, **changes):
        return dict(network_profile='public-routed-lab', **changes)

    def test_default_private_vlan_topology_and_mirror_identity_are_preserved(self):
        install, agent = self.run_render()
        self.assertEqual(agent['rendezvousIP'], '192.168.66.11')
        self.assertEqual(install['networking']['machineNetwork'], [{'cidr': '192.168.66.0/24'}])
        self.assertEqual(agent['additionalNTPSources'], ['192.168.66.10'])
        net = agent['hosts'][0]['networkConfig']
        self.assertEqual([(i['name'], i['state']) for i in net['interfaces']],
                         [('private0', 'up'), ('public0', 'down'), ('private0.1234', 'up')])
        self.assertEqual(net['interfaces'][2]['vlan'], {'base-iface': 'private0', 'id': 1234})
        self.assertEqual(net['interfaces'][2]['ipv4']['address'], [{'ip': '192.168.66.11', 'prefix-length': 24}])
        self.assertEqual(net['routes']['config'], [{'destination': '0.0.0.0/0',
                         'next-hop-address': '192.168.66.10', 'next-hop-interface': 'private0.1234'}])

    def test_public_renders_pinned_static_slash31_without_vlan_or_dhcp(self):
        # Public profile does not need a provisioned VLAN; default placeholder must remain harmless.
        install, agent = self.run_render(self.public(vlan_vid='REPLACE_WITH_virtual_network_vid'))
        self.assertEqual(agent['rendezvousIP'], '192.0.2.11')
        self.assertEqual(install['networking']['machineNetwork'], [{'cidr': '192.0.2.10/31'}])
        self.assertEqual(agent['additionalNTPSources'], ['198.51.100.9'])
        host = agent['hosts'][0]
        self.assertEqual(host['interfaces'], [{'name': 'private0', 'macAddress': '02:00:00:00:00:01'},
                                              {'name': 'public0', 'macAddress': '02:00:00:00:00:02'}])
        net = host['networkConfig']
        self.assertEqual([(i['name'], i['state']) for i in net['interfaces']],
                         [('private0', 'down'), ('public0', 'up')])
        active = net['interfaces'][1]
        self.assertEqual(active['ipv4'], {'enabled': True, 'dhcp': False, 'auto-dns': False,
                         'address': [{'ip': '192.0.2.11', 'prefix-length': 31}]})
        self.assertTrue(all(not i['ipv6']['enabled'] for i in net['interfaces']))
        self.assertEqual(net['dns-resolver']['config']['server'], ['198.51.100.9'])
        self.assertEqual(net['routes']['config'], [{'destination': '0.0.0.0/0',
                         'next-hop-address': '192.0.2.10', 'next-hop-interface': 'public0'}])
        self.assertEqual(set(json.loads(install['pullSecret'])['auths']), {'mirror.fixture.invalid:8443'})
        self.assertEqual(install['additionalTrustBundle'], 'FIXTURE PUBLIC CA\n')
        self.assertNotIn('additionalNTPSources', install)
        self.assertTrue(all(m.startswith('mirror.fixture.invalid:8443/')
                            for ids in install['imageDigestSources'] for m in ids['mirrors']))

    def test_lower_address_can_be_node_when_verified_gateway_is_upper_address(self):
        install, agent = self.run_render(self.public(node_public_ipv4='192.0.2.10', node_public_gateway='192.0.2.11'))
        self.assertEqual(install['networking']['machineNetwork'], [{'cidr': '192.0.2.10/31'}])
        self.assertEqual(agent['rendezvousIP'], '192.0.2.10')

    def test_public_rejects_missing_or_inconsistent_provider_network_inputs(self):
        for changes in ({'node_public_prefix': ''}, {'node_public_prefix': 24},
                        {'node_public_gateway': ''}, {'node_public_gateway': '198.51.100.1'},
                        {'node_public_gateway': '192.0.2.11'}, {'node_public_ipv4': 'invalid'},
                        {'bastion_public_ipv4': '192.0.2.10'},
                        {'cluster_network_cidr': '192.0.2.0/24'}):
            with self.subTest(changes=changes):
                self.run_render(self.public(**changes), success=False)

    def test_public_refuses_unimplemented_isolation_even_when_flags_are_strings(self):
        for flag in ('air_gap', 'enforce_node_egress'):
            for value in (True, 'true', 'unexpected'):
                with self.subTest(flag=flag, value=value):
                    output = self.run_render(self.public(**{flag: value}), success=False)
                    self.assertIn('isolation are not implemented', output)

    def test_public_refuses_missing_or_aliased_hardware_identities(self):
        for changes in ({'node_external_mac': ''}, {'node_external_if': ''},
                        {'node_external_if': 'private0'},
                        {'node_external_mac': '02:00:00:00:00:01'}):
            with self.subTest(changes=changes):
                self.run_render(self.public(**changes), success=False)

    def test_public_refuses_stale_private_services_or_non_sno_layout(self):
        for changes in ({'additional_ntp_sources': ['192.168.66.10']},
                        {'bastion_service_ip': '192.168.66.10'}, {'cluster_node_ip': '192.168.66.11'},
                        {'control_plane_replicas': 3}, {'compute_replicas': 1}):
            with self.subTest(changes=changes):
                self.run_render(self.public(**changes), success=False)

    def test_public_pxe_refuses_serve_before_mutations_but_stop_cleans_publication(self):
        role = ROOT / 'ansible/roles/pxe_serve/tasks'
        fixture_role = self.base / 'pxe-tasks'
        shutil.copytree(role, fixture_role)
        webroot = self.base / 'published'
        legacy = self.base / 'legacy-published'
        private = self.base / 'private-source'
        nginx_conf = self.base / 'boot-artifacts.conf'
        for path in (webroot, legacy, private):
            path.mkdir(mode=0o700)
            (path / 'retained').write_text('fixture')
        nginx_conf.write_text('fixture')
        cleanup = yaml.safe_load((fixture_role / 'cleanup_publication.yml').read_text())
        # Scope the production cleanup helper's legacy path to this temporary fixture.
        cleanup[0]['ansible.builtin.command']['argv'][2] = (
            (ROOT / 'scripts/boot-publication-paths.py').read_text().replace(
                "LEGACY_WEBROOT = '/opt/install/boot-artifacts'", 'LEGACY_WEBROOT = ' + repr(str(legacy))))
        for task in cleanup:
            task['become'] = False
        (fixture_role / 'cleanup_publication.yml').write_text(yaml.safe_dump(cleanup))
        stop = yaml.safe_load((fixture_role / 'stop_publication.yml').read_text())
        for task in stop:
            if 'ansible.builtin.include_tasks' not in task:
                task['become'] = False
            if 'ansible.builtin.file' in task:
                task['ansible.builtin.file']['path'] = str(nginx_conf)
            if task.get('ansible.builtin.command') == 'nginx -t':
                task['ansible.builtin.command'] = {'argv': [sys.executable, '-c', 'pass']}
            if 'ansible.builtin.systemd' in task:
                # Fixture service reload only; retain actual entrypoint and cleanup actions.
                task.pop('ansible.builtin.systemd')
                task['ansible.builtin.command'] = {'argv': [sys.executable, '-c', 'pass']}
        (fixture_role / 'stop_publication.yml').write_text(yaml.safe_dump(stop))
        variables = dict(self.variables, network_profile='public-routed-lab',
                         pxe_publication_started=True,  # Stale fact from a previous role invocation.
                         boot_artifacts_webroot=str(webroot), install_src_dir=str(private),
                         cluster_assets_dir=str(private / 'assets'), boot_artifacts_dir=str(private / 'boot'),
                         install_request_dir=str(private / 'requests'),
                         pxe_publication_state_path=str(self.base / 'pxe-state/sources.json'))
        play = self.base / 'pxe-play.yml'
        play.write_text(yaml.safe_dump([{'hosts': 'localhost', 'connection': 'local',
                                        'gather_facts': False, 'vars': variables,
                                        'tasks': [{'ansible.builtin.include_tasks': str(fixture_role / 'main.yml')}]}]))
        for mode, expected in (('serve', 2), ('stop', 0)):
            result = subprocess.run(['ansible-playbook', '-i', 'localhost,', str(play), '-e', 'pxe_mode=' + mode],
                                    env=self.env, cwd=self.base, capture_output=True, text=True, timeout=60)
            output = result.stdout + result.stderr
            self.assertEqual(result.returncode, expected, output)
            self.assertEqual((private / 'retained').read_text(), 'fixture')
            if mode == 'serve':
                self.assertIn('Ingress protection must cover both', output)
                self.assertTrue(webroot.exists())
                self.assertTrue(legacy.exists())
                self.assertTrue(nginx_conf.exists())
                self.assertFalse((self.base / 'pxe-state').exists())
            else:
                self.assertFalse(webroot.exists())
                self.assertFalse(legacy.exists())
                self.assertFalse(nginx_conf.exists())

    def test_bastion_hosts_task_uses_public_sno_or_each_private_master_address(self):
        tasks = yaml.safe_load((ROOT / 'ansible/roles/install_drive/tasks/main.yml').read_text())
        source = next(task for task in tasks if task.get('ansible.builtin.blockinfile', {}).get('path') == '/etc/hosts')
        private_machines = [{'role': 'master', 'vlan_ip': '192.168.66.11'},
                            {'role': 'master', 'vlan_ip': '192.168.66.12'},
                            {'role': 'worker', 'vlan_ip': '192.168.66.13'}]
        cases = [('default-private', None, private_machines, ['192.168.66.11', '192.168.66.12']),
                 ('private', 'private-vlan', private_machines, ['192.168.66.11', '192.168.66.12']),
                 ('public', 'public-routed-lab', private_machines[:1], ['192.0.2.11'])]
        names = ['api.fixture.fixture.invalid', 'api-int.fixture.fixture.invalid',
                 'console-openshift-console.apps.fixture.fixture.invalid',
                 'oauth-openshift.apps.fixture.fixture.invalid']
        for label, profile, machines, addresses in cases:
            with self.subTest(profile=label):
                hosts = self.base / ('hosts-' + label)
                hosts.write_text('127.0.0.1 localhost\n')
                task = copy.deepcopy(source)
                task['become'] = False
                task['ansible.builtin.blockinfile']['path'] = str(hosts)
                variables = dict(self.variables, install_mode='fresh', machines=machines,
                                 cluster_node_ip='192.168.66.99')
                # A stale global alias must not collapse separate private master addresses.
                if profile is None:
                    variables.pop('network_profile', None)
                else:
                    variables['network_profile'] = profile
                play = self.base / ('hosts-' + label + '.yml')
                play.write_text(yaml.safe_dump([{'hosts': 'localhost', 'connection': 'local',
                                                'gather_facts': False, 'vars': variables, 'tasks': [task]}]))
                result = subprocess.run(['ansible-playbook', '-i', 'localhost,', str(play)],
                                        env=self.env, cwd=self.base, capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                records = [line for line in hosts.read_text().splitlines() if line and not line.startswith('#')]
                self.assertEqual(records, ['127.0.0.1 localhost'] + [ip + ' ' + name for ip in addresses for name in names])

    def test_unknown_profile_fails_before_creating_installer_sources(self):
        self.run_render({'network_profile': 'public-vlan-typo'}, success=False)


if __name__ == '__main__':
    unittest.main()
