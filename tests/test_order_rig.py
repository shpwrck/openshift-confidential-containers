"""make order-rig: the plan picker, what it reads on the servers, the rig file, and a whole run
against a fake Cherry API, Terraform and SSH. Nothing is ordered and no server is contacted."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts/lib'))
import cherry_rig  # noqa: E402

spec = importlib.util.spec_from_file_location('order_rig', ROOT / 'scripts/order-rig.py')
order_rig = importlib.util.module_from_spec(spec)
spec.loader.exec_module(order_rig)

TESTED = json.loads((ROOT / 'infra/cherry/tested-plans.json').read_text())


def plan(slug, cpu, price, stock, disk_gb=1000, kind='baremetal', image_slugs=('ubuntu_26_04_64bit', 'almalinux_9_64bit')):
    return {'slug': slug, 'type': kind, 'specs': {'cpus': {'name': cpu},
            'storage': [{'count': 2, 'size': disk_gb, 'unit': 'GB', 'type': 'NVME'}]},
            'pricing': [{'unit': 'Monthly', 'price': price * 600, 'currency': 'EUR'},
                        {'unit': 'Hourly', 'price': price, 'currency': 'EUR'}],
            'available_regions': [{'slug': region, 'stock_qty': qty} for region, qty in stock.items()],
            'softwares': [{'image': {'slug': s}} for s in image_slugs]}


PLANS = [
    plan('amd-epyc-9124p', 'AMD EPYC 9124P', 0.61, {'US-Chicago': 2, 'NL-Amsterdam': 0}),
    plan('amd-epyc-9254p', 'AMD EPYC 9254P', 0.70, {'SE-Stockholm': 1, 'US-Chicago': 0}),
    plan('2x-intel-gold-6330', '2x Intel GOLD 6330', 0.632, {'US-Chicago': 2}, disk_gb=500),
    plan('amd-ryzen-9700x', 'AMD Ryzen 9700X', 0.324, {'SE-Stockholm': 3}),
    plan('small-disk', 'Intel Xeon E-2276G', 0.10, {'SE-Stockholm': 5}, disk_gb=240),
    plan('amd-epyc-7402p', 'AMD EPYC 7402P', 0.40, {'NL-Amsterdam': 4}),
    plan('amd-epyc-9355', 'AMD EPYC 9355', 1.20, {'NL-Amsterdam': 1}),
    plan('vds-epyc', '2 x AMD EPYC 9354P', 0.05, {'US-Chicago': 9}, kind='vds'),
]


def link(ifname, **fields):
    return dict(ifname=ifname, link_type='ether', **fields)


# What the node's original OS reports on a delivered Cherry rig (both members joined).
LINKS = [
    {'ifname': 'lo', 'link_type': 'loopback', 'address': '00:00:00:00:00:00'},
    link('enp5s0f0', address='7c:c2:55:ab:73:7a', master='bond0',
         linkinfo={'info_slave_kind': 'bond', 'info_slave_data': {'perm_hw_addr': '7c:c2:55:ab:73:7a'}}),
    link('enp5s0f1', address='7c:c2:55:ab:73:7a', permaddr='7c:c2:55:ab:73:7b', master='bond0',
         linkinfo={'info_slave_kind': 'bond', 'info_slave_data': {'perm_hw_addr': '7c:c2:55:ab:73:7b'}}),
    link('bond0', address='7c:c2:55:ab:73:7a', linkinfo={'info_kind': 'bond', 'info_data': {'mode': '802.3ad'}}),
    link('bond0.3436', address='7c:c2:55:ab:73:7a', link='bond0',
         linkinfo={'info_kind': 'vlan', 'info_data': {'protocol': '802.1Q', 'id': 3436}}),
    link('enxbe3af2b6059f', address='be:3a:f2:b6:05:9f'),
]
ADDRESSES = [
    {'ifname': 'bond0', 'addr_info': [{'local': '84.32.220.45', 'prefixlen': 26}]},
    {'ifname': 'bond0.3436', 'addr_info': [{'local': '10.198.229.47', 'prefixlen': 24}]},
]
# Cherry installs Ubuntu as a RAID1 mirror over both NVMe disks; /boot/efi is on the second one.
BLOCK = {'blockdevices': [
    {'name': 'nvme0n1', 'path': '/dev/nvme0n1', 'type': 'disk', 'size': 960197124096, 'serial': '241848968827',
     'model': 'Micron_7450_MTFDKCB960TFR', 'tran': 'nvme', 'mountpoints': [None],
     'children': [{'name': 'nvme0n1p1', 'type': 'part', 'mountpoints': ['/boot/efi/ubuntu2']},
                  {'name': 'nvme0n1p2', 'type': 'part', 'mountpoints': [None],
                   'children': [{'name': 'md0', 'type': 'raid1', 'mountpoints': ['/']}]}]},
    {'name': 'nvme1n1', 'path': '/dev/nvme1n1', 'type': 'disk', 'size': 960197124096, 'serial': '24184896895E',
     'model': 'Micron_7450_MTFDKCB960TFR', 'tran': 'nvme', 'mountpoints': [None],
     'children': [{'name': 'nvme1n1p1', 'type': 'part', 'mountpoints': ['/boot/efi']},
                  {'name': 'nvme1n1p2', 'type': 'part', 'mountpoints': [None],
                   'children': [{'name': 'md0', 'type': 'raid1', 'mountpoints': ['/']}]}]},
    # The BMC's virtual media.
    {'name': 'sda', 'path': '/dev/sda', 'type': 'disk', 'size': 500 * 10**9, 'tran': 'usb', 'mountpoints': [None]},
]}
BY_PATH = {'pci-0000:01:00.0-nvme-1': '/dev/nvme1n1', 'pci-0000:01:00.0-nvme-1-part1': '/dev/nvme1n1p1',
           'pci-0000:02:00.0-nvme-1': '/dev/nvme0n1', 'pci-0000:c3:00.0-usb-0:1:1.0-scsi-0:0:0:0': '/dev/sda'}
OBSERVATION = {'hostname': 'sno-coco-node', 'links': LINKS, 'addresses': ADDRESSES, 'block': BLOCK, 'by_path': BY_PATH}
# What scripts/lib/node_checks.py reads on the node before it is erased.
IDENTITY = {'hostname': 'sno-coco-node', 'cpu': 'AMD EPYC 9254 24-Core Processor', 'system': 'Supermicro Super Server',
            'board': 'H13SST-G', 'bios_version': '3.7', 'bios_date': '06/12/2025', 'uefi': True,
            'disks': [{k: d.get(k) for k in ('name', 'path', 'type', 'size', 'serial', 'model', 'tran')} for d in BLOCK['blockdevices']]}
VALUES = {'project_id': '295530', 'node_id': '1047102', 'node_hostname': 'sno-coco-node',
          'node_public_ipv4': '84.32.220.45', 'node_private_ipv4': '10.198.229.47',
          'helper_id': '1047103', 'helper_hostname': 'sno-coco-helper',
          'helper_public_ipv4': '185.8.107.144', 'helper_private_ipv4': '10.198.229.10',
          'private_network': '10.198.229.0/24', 'vlan_tag': '3436'}
HELPER_ENV = ('VLAN_IFACE=bond0.3436\nVLAN_PARENT=bond0\nVLAN_VID=3436\nBASTION_VLAN_IP=10.198.229.10\n'
              'VLAN_PREFIX=24\nVLAN_SUBNET=10.198.229.0/24\nPUBLIC_IFACE=bond0\n')
PUBLIC_KEY = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureKeyMaterialOnly0000000000000000000 me@laptop\n'


class PlanPicker(unittest.TestCase):
    def test_the_cheapest_fully_tested_pair_comes_first(self):
        options = cherry_rig.rig_options(PLANS, TESTED)
        first = options[0]
        self.assertEqual((first['region'], first['node']['plan'], first['helper']['plan']),
                         ('US-Chicago', 'amd-epyc-9124p', '2x-intel-gold-6330'))
        self.assertTrue(first['node']['tested'] and first['helper']['tested'])
        self.assertEqual(first['price'], 1.242)
        self.assertEqual(first['node']['image'], 'ubuntu_26_04_64bit')
        self.assertEqual(first['helper']['image'], 'almalinux_9_64bit')

    def test_without_a_tested_helper_the_cheapest_big_enough_plan_is_marked_untested(self):
        stockholm = next(o for o in cherry_rig.rig_options(PLANS, TESTED) if o['region'] == 'SE-Stockholm')
        self.assertEqual(stockholm['node']['plan'], 'amd-epyc-9254p')
        # small-disk is cheaper but has 240 GB; the VDS is not bare metal.
        self.assertEqual(stockholm['helper']['plan'], 'amd-ryzen-9700x')
        self.assertFalse(stockholm['helper']['tested'])

    def test_regions_without_a_tested_node_in_stock_are_left_out(self):
        regions = {o['region'] for o in cherry_rig.rig_options(PLANS, TESTED)}
        self.assertEqual(regions, {'US-Chicago', 'SE-Stockholm'})

    def test_the_node_plan_serves_as_helper_only_with_a_second_server_in_stock(self):
        plans = [plan('amd-epyc-9124p', 'AMD EPYC 9124P', 0.61, {'US-Chicago': 1})]
        self.assertEqual(cherry_rig.rig_options(plans, TESTED), [])
        plans = [plan('amd-epyc-9124p', 'AMD EPYC 9124P', 0.61, {'US-Chicago': 2})]
        option, = cherry_rig.rig_options(plans, TESTED)
        self.assertEqual(option['helper']['plan'], 'amd-epyc-9124p')

    def test_untested_nodes_are_only_epyc_series_with_sev_snp(self):
        options = cherry_rig.rig_options(PLANS, TESTED, untested_nodes=True)
        self.assertEqual([o['node']['plan'] for o in options], ['amd-epyc-9355'])
        self.assertFalse(options[0]['node']['tested'])
        for cpu, snp in [('AMD EPYC 7313P', True), ('AMD EPYC 7402P', False), ('AMD EPYC 8024P', True),
                         ('AMD EPYC 9474F', True), ('AMD EPYC 9575F', True), ('AMD EPYC 4464P', False),
                         ('AMD Ryzen 9 7950X', False)]:
            with self.subTest(cpu=cpu):
                self.assertEqual(bool(cherry_rig.SNP_CPU.search(cpu)), snp)


class AccountValues(unittest.TestCase):
    def test_a_key_already_in_the_account_is_found_whatever_its_comment(self):
        keys = [{'id': 7, 'key': 'ssh-rsa AAAAB3Nza other'},
                {'id': 20026, 'key': PUBLIC_KEY.replace('me@laptop', 'portal label')}]
        self.assertEqual(cherry_rig.matching_key_id(PUBLIC_KEY, keys), '20026')
        self.assertIsNone(cherry_rig.matching_key_id(PUBLIC_KEY, keys[:1]))
        with self.assertRaises(cherry_rig.RigError):
            cherry_rig.matching_key_id('not a key', keys)

    def order(self, **extra):
        option = cherry_rig.rig_options(PLANS, TESTED)[0]
        return dict(option, **{'project_id': 295530, 'ssh_key': '/home/me/.ssh/id_ed25519',
                               'ssh_public_key': '/home/me/.ssh/id_ed25519.pub', 'ssh_key_id': None, **extra})

    def test_tfvars_name_the_existing_key_or_register_the_file(self):
        text = cherry_rig.render_tfvars(self.order(ssh_key_id='20026'))
        self.assertIn('ssh_key_ids  = ["20026"]', text)
        self.assertIn('region       = "US-Chicago"', text)
        self.assertIn('node_plan    = "amd-epyc-9124p"', text)
        self.assertNotIn('ssh_public_key_file', text)
        text = cherry_rig.render_tfvars(self.order())
        self.assertIn('ssh_public_key_file = "/home/me/.ssh/id_ed25519.pub"', text)

    def test_tfvars_refuse_values_terraform_would_interpret(self):
        for order in (self.order(region='US-Chicago"\nx = "y'), self.order(ssh_public_key='/tmp/${file("/etc/passwd")}'),
                      self.order(project_id='0'), self.order(ssh_key_id='1; rm')):
            with self.assertRaises(cherry_rig.RigError):
                cherry_rig.render_tfvars(order)


class NodeObservation(unittest.TestCase):
    def test_reads_the_vlan_tag_bond_and_permanent_member_macs(self):
        facts = cherry_rig.network_facts(OBSERVATION, '10.198.229.47')
        self.assertEqual(facts['vlan_tag'], '3436')
        self.assertEqual((facts['vlan_if'], facts['bond'], facts['bond_mac']), ('bond0.3436', 'bond0', '7c:c2:55:ab:73:7a'))
        self.assertEqual(facts['ports'], [{'name': 'enp5s0f0', 'mac': '7c:c2:55:ab:73:7a'},
                                          {'name': 'enp5s0f1', 'mac': '7c:c2:55:ab:73:7b'}])
        # The BMC's USB network device is not a NIC that missed the bond.
        self.assertEqual(facts['loose_nics'], [])

    def test_a_member_that_missed_the_bond_is_named(self):
        links = [dict(x) for x in LINKS]
        links[2] = link('enp5s0f1np1', address='7c:c2:55:ab:73:7b')
        facts = cherry_rig.network_facts(dict(OBSERVATION, links=links), '10.198.229.47')
        self.assertEqual([p['name'] for p in facts['ports']], ['enp5s0f0'])
        self.assertEqual(facts['loose_nics'], ['enp5s0f1np1'])

    def test_the_private_address_must_be_on_a_vlan_over_a_bond(self):
        with self.assertRaisesRegex(cherry_rig.RigError, 'no interface'):
            cherry_rig.network_facts(OBSERVATION, '10.198.229.99')
        addresses = [ADDRESSES[0], {'ifname': 'bond0', 'addr_info': [{'local': '10.198.229.47'}]}]
        with self.assertRaisesRegex(cherry_rig.RigError, 'not a VLAN'):
            cherry_rig.network_facts(dict(OBSERVATION, addresses=addresses), '10.198.229.47')

    def test_the_disk_holding_boot_efi_comes_first_and_virtual_media_is_left_out(self):
        disks = cherry_rig.disk_facts(OBSERVATION)
        self.assertEqual([d['name'] for d in disks], ['nvme1n1', 'nvme0n1'])
        self.assertEqual(disks[0]['by_path'], '/dev/disk/by-path/pci-0000:01:00.0-nvme-1')
        self.assertEqual((disks[0]['serial'], disks[0]['size_gb'], disks[0]['holds_efi']), ('24184896895E', 960, True))
        # /boot/efi/ubuntu2 is the mirror's copy, not the ESP the firmware boots.
        self.assertFalse(disks[1]['holds_efi'])

    def test_without_boot_efi_the_first_nvme_disk_is_the_default(self):
        block = json.loads(json.dumps(BLOCK).replace('"/boot/efi"', '"/srv"'))
        self.assertEqual(cherry_rig.disk_facts(dict(OBSERVATION, block=block))[0]['name'], 'nvme1n1')
        with self.assertRaisesRegex(cherry_rig.RigError, 'no disk'):
            cherry_rig.disk_facts(dict(OBSERVATION, by_path={}))


class RigFile(unittest.TestCase):
    def render(self, values=VALUES, helper_env=HELPER_ENV, observation=OBSERVATION):
        disks = cherry_rig.disk_facts(observation)
        access = {'ssh_key': '/home/me/.ssh/id_ed25519', 'known_hosts': '/state/known_hosts',
                  'pull_secret': '/state/credentials/pull-secret.json', 'disk': disks[0], 'disks': disks}
        return cherry_rig.render_rig_file(values, cherry_rig.network_facts(observation, values['node_private_ipv4']),
                                          cherry_rig.parse_env_file(helper_env), access, 'a' * 32, '2026-10-28 14:40 UTC')

    def test_the_rig_file_is_complete_and_fills_every_example_value(self):
        text = self.render()
        rig = yaml.safe_load(text)
        example = yaml.safe_load((ROOT / 'ansible/rig.example.yml').read_text())
        self.assertLessEqual(set(example), set(rig))
        self.assertNotIn('REPLACE', text)
        self.assertEqual(rig['node_server_id'], '1047102')
        self.assertEqual(rig['node_provider_project_id'], '295530')
        self.assertEqual((rig['bastion_ansible_host'], rig['bastion_public_ipv4_override']), ('185.8.107.144',) * 2)
        self.assertEqual((rig['machine_network'], rig['vlan_cidr'], rig['vlan_prefix']), ('10.198.229.0/24',) * 2 + (24,))
        self.assertEqual(rig['vlan_vid_override'], '3436')
        self.assertEqual((rig['bastion_private_if'], rig['bastion_external_if']), ('bond0.3436', 'bond0'))
        self.assertEqual(rig['node_bond_ports'][1], {'name': 'enp5s0f1', 'mac': '7c:c2:55:ab:73:7b'})
        self.assertEqual(rig['node_root_device'], '/dev/disk/by-path/pci-0000:01:00.0-nvme-1')
        self.assertEqual(rig['node_ssh_pubkey_src'], '/home/me/.ssh/id_ed25519.pub')
        self.assertEqual((rig['raw_node_ssh_user'], rig['bastion_ssh_user']), ('root', 'root'))
        self.assertIn('serial 24184896895E', text)
        self.assertIn('Other disk: nvme0n1', text)
        self.assertIn('can swap after a reboot', text)

    def test_mismatched_servers_are_refused(self):
        cases = {
            'API tag': (dict(VALUES, vlan_tag='2738'), HELPER_ENV),
            'helper tag': (VALUES, HELPER_ENV.replace('VLAN_VID=3436', 'VLAN_VID=2911')),
            'helper address': (VALUES, HELPER_ENV.replace('=10.198.229.10', '=10.198.229.11')),
            'network': (dict(VALUES, private_network='10.198.230.0/24'), HELPER_ENV),
            'no interface': (VALUES, HELPER_ENV.replace('PUBLIC_IFACE=bond0', 'PUBLIC_IFACE=')),
        }
        for name, (values, env) in cases.items():
            with self.subTest(name), self.assertRaises(cherry_rig.RigError):
                self.render(values, env)

    def test_a_tag_the_api_does_not_report_is_taken_from_the_node(self):
        self.assertEqual(yaml.safe_load(self.render(dict(VALUES, vlan_tag=None)))['vlan_vid_override'], '3436')

    def test_a_bond_with_one_member_cannot_be_written(self):
        links = [x for x in LINKS if x['ifname'] != 'enp5s0f1']
        with self.assertRaisesRegex(cherry_rig.RigError, '1 members'):
            self.render(observation=dict(OBSERVATION, links=links))


FAKE_TERRAFORM = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
fixture = Path(os.environ['FIXTURE_DIR'])
args = [a for a in sys.argv[1:] if not a.startswith('-chdir=')]
with open(fixture / 'terraform.log', 'a') as log:
    log.write(' '.join(args) + '\n')
ordered = (fixture / 'ordered').exists()
command = args[0]
if command == 'init':
    sys.exit(0)
if command == 'state':
    partial = fixture / 'partial'
    print('cherryservers_server.helper\ncherryservers_server.node' if ordered else
          partial.read_text() if partial.exists() else '')
    sys.exit(0)
if command == 'import':
    (fixture / 'ordered').write_text('')
    sys.exit(0)
replacing = '-replace=cherryservers_server.helper' in args
if command == 'plan':
    if os.environ.get('FIXTURE_SWITCHES') and ordered and not replacing:
        print('Error: Resource precondition failed ... The node and the helper are not on the same private network.')
        sys.exit(1)
    plan = next(a.split('=', 1)[1] for a in args if a.startswith('-out='))
    Path(plan).write_text('replace' if replacing else 'plan')
    sys.exit(0 if ordered and not replacing else 2)
if command == 'show':
    if Path(args[-1]).read_text() == 'replace':
        changes = [{'address': 'cherryservers_server.helper', 'change': {'actions': ['delete', 'create']}}]
    else:
        changes = [{'address': a, 'change': {'actions': ['create']}}
                   for a in ('cherryservers_server.helper', 'cherryservers_server.node')]
    print(json.dumps({'resource_changes': changes}))
    sys.exit(0)
if command == 'apply':
    print('cherryservers_server.node: Creation complete after 14m2s [id=1047102]')
    if os.environ.get('FIXTURE_APPLY_TIMEOUT'):
        # The node is recorded; the helper Cherry is still delivering is not.
        print('Error: unable to deploy CherryServers server\n\ncontext deadline exceeded')
        (fixture / 'partial').write_text('cherryservers_ssh_key.rig[0]\ncherryservers_server.node\n')
        sys.exit(1)
    (fixture / 'ordered').write_text('')
    sys.exit(0)
if command == 'output':
    if not ordered:
        print('No outputs found', file=sys.stderr)
        sys.exit(1)
    print(os.environ['FIXTURE_VALUES'])
    sys.exit(0)
sys.exit('unexpected terraform call: ' + ' '.join(args))
'''

FAKE_SSH = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
fixture = Path(os.environ['FIXTURE_DIR'])
host, command = sys.argv[-2], sys.argv[-1]
stdin = sys.stdin.read() if command.startswith('python3 -') or command == 'bash -s' or 'systemd-run' in command else ''
with open(fixture / 'ssh.log', 'a') as log:
    log.write(f'{host} {command.splitlines()[0]}\n')
started = fixture / 'bootstrap-started'
if command == 'true':
    sys.exit(0)
if 'MIRROR_READY' in command:
    print('ready' if started.exists() else 'none')
elif 'systemd-run' in command:
    started.write_text(stdin)
elif command.startswith('python3 -') and '/sys/class/dmi/id' in stdin:
    identity = json.loads(os.environ['FIXTURE_IDENTITY'])
    root = command.split(' ', 2)[2] if command.count(' ') > 1 else ''
    identity.update(root_device=root, root_path='/dev/nvme1n1' if root.endswith('pci-0000:01:00.0-nvme-1') else '')
    print(json.dumps(identity))
elif command == 'python3 -':
    rebooted = (fixture / 'rebooted').exists()
    print(os.environ['FIXTURE_OBSERVATION' if rebooted else 'FIXTURE_FIRST_OBSERVATION'])
elif command == 'systemctl reboot':
    (fixture / 'rebooted').write_text('')
    sys.exit(255)
elif command.startswith('tail') or command.startswith('journalctl'):
    print('mirror-registry install finished')
elif command == 'cat /etc/rig-network.env':
    print(os.environ['FIXTURE_HELPER_ENV'], end='')
elif command == 'bash -s' and 'SEV-SNP host gate' in stdin:
    print('RESULT: ' + os.environ.get('FIXTURE_SNP', 'SEV-SNP host prerequisites passed.'))
    sys.exit(0 if 'FIXTURE_SNP' not in os.environ else 1)
else:
    sys.exit('unexpected ssh command: ' + command)
'''

FAKE_SSH_KEYGEN = '#!/bin/sh\necho "256 SHA256:fixture root@host (ED25519)"\n'


class WholeRun(unittest.TestCase):
    """make order-rig from nothing to a rig file, then again: the rerun orders nothing."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='coco-order-rig-')
        self.addCleanup(self.tmp.cleanup)
        # Resolved, as the script resolves COCO_STATE_DIR: macOS's temporary directory is a symlink.
        base = Path(self.tmp.name).resolve()
        self.fixture, self.state, stubs = base / 'fixture', base / 'state', base / 'stubs'
        for d in (self.fixture, self.state, stubs):
            d.mkdir()
        for name, text in (('terraform', FAKE_TERRAFORM), ('ssh', FAKE_SSH), ('ssh-keygen', FAKE_SSH_KEYGEN)):
            (stubs / name).write_text(text.replace('/usr/bin/env python3', sys.executable))
            (stubs / name).chmod(0o755)
        self.key = base / 'id_ed25519'
        self.key.write_text('private key fixture\n')
        Path(str(self.key) + '.pub').write_text(PUBLIC_KEY)
        self.pull_secret = base / 'pull-secret.json'
        self.pull_secret.write_text(json.dumps({'auths': {'registry.redhat.io': {'auth': 'Zml4dHVyZQ=='}}}))
        env = {'PATH': f'{stubs}:{os.environ["PATH"]}', 'COCO_STATE_DIR': str(self.state),
               'CHERRY_SERVERS_API_KEY': 'fixture-key', 'FIXTURE_DIR': str(self.fixture),
               'FIXTURE_VALUES': json.dumps(VALUES), 'FIXTURE_OBSERVATION': json.dumps(OBSERVATION),
               'FIXTURE_FIRST_OBSERVATION': json.dumps(OBSERVATION),
               'FIXTURE_HELPER_ENV': HELPER_ENV, 'FIXTURE_IDENTITY': json.dumps(IDENTITY)}
        patcher = patch.dict(os.environ, env)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.api_calls = []
        self.project_servers, self.server_polls = [], []

    def api(self, path, auth=True):
        self.api_calls.append(path)
        if path.startswith('/servers/'):
            return self.server_polls.pop(0)
        responses = {
            '/plans': PLANS,
            '/teams': [{'id': 11, 'name': 'Red Hat NA SSA'}],
            '/teams/11/projects': [{'id': 295530, 'name': 'coco'}, {'id': 300001, 'name': 'other'}],
            '/projects/295530/servers': self.project_servers,
            '/projects/300001/servers': [{'id': 1}],
            '/ssh-keys': [{'id': 20026, 'key': PUBLIC_KEY}],
        }
        return responses[path]

    def run_order_rig(self, *args):
        output, errors = io.StringIO(), io.StringIO()
        with patch.object(order_rig.Cherry, 'get', lambda _, path, auth=True: self.api(path, auth)), \
                patch.object(order_rig.time, 'sleep', lambda _: None), \
                patch.object(sys, 'stdin', io.StringIO('')), \
                contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            code = order_rig.main(list(args))
        return code, output.getvalue(), errors.getvalue()

    def test_a_whole_run_then_a_rerun(self):
        code, out, err = self.run_order_rig('--region', 'US-Chicago', '--project', '295530', '--ssh-key', str(self.key),
                                            '--pull-secret', str(self.pull_secret), '--confirm-order')
        self.assertEqual(code, 0, out + err)
        tfvars = (self.state / 'cherry.tfvars').read_text()
        self.assertIn('ssh_key_ids  = ["20026"]', tfvars)
        self.assertIn('project_id   = 295530', tfvars)
        self.assertIn('Together about 1.24 EUR/hour', out)
        rig = yaml.safe_load((self.state / 'rig.yml').read_text())
        self.assertEqual(rig['node_server_id'], '1047102')
        self.assertEqual(rig['private_link_known_hosts'], str(self.state / 'known_hosts'))
        self.assertEqual(rig['raw_node_ssh_key'], str(self.key))
        self.assertEqual(rig['pull_secret_src'], str(self.state / 'credentials/pull-secret.json'))
        for path in ('rig.yml', 'cherry.tfvars', 'credentials/pull-secret.json', 'rig-order.json', 'known_hosts'):
            with self.subTest(path=path):
                self.assertEqual((self.state / path).stat().st_mode & 0o077, 0)
        # The helper got the renderer's default bootstrap, which installs the manifest's pinned archive.
        rendered = subprocess.run([sys.executable, str(ROOT / 'scripts/render-helper-bootstrap.py')],
                                  capture_output=True, text=True, check=True).stdout
        self.assertEqual((self.fixture / 'bootstrap-started').read_text(), rendered)
        self.assertEqual(self.api_calls.count('/ssh-keys'), 1)
        applies = (self.fixture / 'terraform.log').read_text().count('apply ')
        self.assertEqual(applies, 1)

        token = rig['boot_artifacts_token']
        code, out, err = self.run_order_rig()
        self.assertEqual(code, 0, out + err)
        self.assertIn('Both servers are already ordered.', out)
        self.assertIn('already written for this rig', out)
        # The node may be in its BIOS by now, so a finished rig is not contacted again.
        self.assertEqual((self.fixture / 'ssh.log').read_text().count('84.32.220.45 python3 -'), 1)
        self.assertEqual((self.fixture / 'terraform.log').read_text().count('apply '), 1)
        self.assertEqual(yaml.safe_load((self.state / 'rig.yml').read_text())['boot_artifacts_token'], token)

    def test_nothing_is_ordered_without_confirmation(self):
        code, out, err = self.run_order_rig('--region', 'US-Chicago', '--project', '295530', '--ssh-key', str(self.key),
                                            '--pull-secret', str(self.pull_secret))
        self.assertEqual(code, 1)
        self.assertIn('--confirm-order', err)
        self.assertFalse((self.fixture / 'ordered').exists())
        self.assertFalse((self.state / 'rig.yml').exists())

    def test_a_pull_secret_without_the_red_hat_registry_is_refused(self):
        self.pull_secret.write_text(json.dumps({'auths': {'quay.io': {}}}))
        code, _, err = self.run_order_rig('--region', 'US-Chicago', '--project', '295530', '--ssh-key', str(self.key),
                                          '--pull-secret', str(self.pull_secret), '--confirm-order')
        self.assertEqual(code, 1)
        self.assertIn('registry.redhat.io', err)
        self.assertFalse((self.fixture / 'ordered').exists())

    def answers(self, *extra):
        return ('--region', 'US-Chicago', '--project', '295530', '--ssh-key', str(self.key),
                '--pull-secret', str(self.pull_secret), '--confirm-order', *extra)

    def test_a_bond_member_that_missed_the_first_boot_gets_one_reboot(self):
        one_member = dict(OBSERVATION, links=[x for x in LINKS if x['ifname'] != 'enp5s0f1']
                          + [link('enp5s0f1np1', address='7c:c2:55:ab:73:7b')])
        os.environ['FIXTURE_FIRST_OBSERVATION'] = json.dumps(one_member)
        code, out, err = self.run_order_rig(*self.answers())
        self.assertEqual(code, 1)
        self.assertIn('enp5s0f1np1 (7c:c2:55:ab:73:7b) did not join it', out)
        self.assertIn('--reboot-node', err)
        self.assertFalse((self.state / 'rig.yml').exists())
        code, out, err = self.run_order_rig(*self.answers('--reboot-node'))
        self.assertEqual(code, 0, out + err)
        self.assertTrue((self.fixture / 'rebooted').exists())
        self.assertEqual(len(yaml.safe_load((self.state / 'rig.yml').read_text())['node_bond_ports']), 2)

    def test_a_helper_on_another_switch_is_replaced_only_when_asked(self):
        code, out, err = self.run_order_rig(*self.answers())
        self.assertEqual(code, 0, out + err)
        (self.state / 'rig.yml').unlink()
        os.environ['FIXTURE_SWITCHES'] = '1'
        code, out, err = self.run_order_rig()
        self.assertEqual(code, 1)
        self.assertIn('different switches', out)
        self.assertIn('--replace-helper', err)
        code, out, err = self.run_order_rig('--replace-helper', '--confirm-order')
        self.assertEqual(code, 0, out + err)
        self.assertIn('replace the helper, 2x-intel-gold-6330', out)
        self.assertIn('-replace=cherryservers_server.helper', (self.fixture / 'terraform.log').read_text())

    def orphaned_helper(self, **fields):
        order = json.loads((self.state / 'rig-order.json').read_text())
        return dict({'id': 1047390, 'hostname': 'sno-coco-helper', 'plan': {'slug': order['helper']['plan']},
                     'region': {'slug': order['region']}, 'state': 'provisioning', 'status': 'unknown'}, **fields)

    def test_a_server_terraform_stopped_waiting_for_is_taken_over_not_ordered_again(self):
        os.environ['FIXTURE_APPLY_TIMEOUT'] = '1'
        code, out, err = self.run_order_rig(*self.answers())
        self.assertEqual(code, 1)
        self.assertIn('takes over that server instead of ordering another', err)
        del os.environ['FIXTURE_APPLY_TIMEOUT']
        # Cherry lists the helper Terraform never recorded, and delivers it two polls later.
        self.project_servers.append({'id': 1047390, 'hostname': 'sno-coco-helper', 'state': 'provisioning'})
        self.server_polls.extend([self.orphaned_helper(), self.orphaned_helper(),
                                  self.orphaned_helper(state='active', status='deployed')])
        code, out, err = self.run_order_rig()
        self.assertEqual(code, 0, out + err)
        self.assertIn('Cherry is still delivering the helper (server 1047390, provisioning)', out)
        self.assertIn('Taking over the helper (server 1047390)', out)
        self.assertIn('Both servers are already ordered.', out)
        log = (self.fixture / 'terraform.log').read_text()
        self.assertIn(f'import -input=false -no-color -var-file={self.state / "cherry.tfvars"} '
                      'cherryservers_server.helper 1047390', log)
        self.assertEqual(log.count('apply '), 1)
        self.assertEqual(self.server_polls, [])
        self.assertTrue((self.state / 'rig.yml').is_file())

    def test_a_server_cherry_could_not_deliver_or_another_plan_is_not_taken_over_or_ordered_again(self):
        os.environ['FIXTURE_APPLY_TIMEOUT'] = '1'
        self.assertEqual(self.run_order_rig(*self.answers())[0], 1)
        del os.environ['FIXTURE_APPLY_TIMEOUT']
        self.project_servers.append({'id': 1047390, 'hostname': 'sno-coco-helper', 'state': 'provisioning'})
        self.server_polls.append(self.orphaned_helper(status='failed deployment'))
        code, out, err = self.run_order_rig()
        self.assertEqual(code, 1)
        self.assertIn('Cherry could not deliver the helper (server 1047390). Delete it in the Cherry portal', err)
        log = (self.fixture / 'terraform.log').read_text()
        self.assertNotIn('import ', log)
        self.assertEqual(log.count('apply '), 1)
        # Two unrecorded helpers are not guessed between, and another plan is not taken for the ordered one.
        self.project_servers.append({'id': 1047391, 'hostname': 'sno-coco-helper', 'state': 'active'})
        code, out, err = self.run_order_rig()
        self.assertEqual(code, 1)
        self.assertIn('(1047390, 1047391); delete all but one', err)
        del self.project_servers[0]
        self.server_polls.append(self.orphaned_helper(id=1047391, plan={'slug': 'e5-1620v4'}))
        code, out, err = self.run_order_rig()
        self.assertEqual(code, 1)
        self.assertIn('server 1047391 in project 295530 is named sno-coco-helper but is a e5-1620v4', err)
        self.assertEqual(self.server_polls, [])
        self.assertEqual((self.fixture / 'terraform.log').read_text().count('apply '), 1)

    def test_the_hostnames_it_looks_for_are_the_terraform_defaults(self):
        variables = (ROOT / 'infra/cherry/variables.tf').read_text()
        for role, hostname in order_rig.HOSTNAMES.items():
            with self.subTest(role=role):
                self.assertRegex(variables, rf'variable "{role}_hostname" {{[^}}]*default\s*=\s*"{hostname}"')
        self.assertIn(f'create = "{order_rig.DELIVERY_HOURS}h"', (ROOT / 'infra/cherry/main.tf').read_text())

    def test_the_snp_check_runs_on_the_node_and_keeps_its_output(self):
        code, out, err = self.run_order_rig('check-snp')
        self.assertEqual(code, 1)
        self.assertIn('make order-rig first', err)
        self.assertEqual(self.run_order_rig(*self.answers())[0], 0)
        code, out, err = self.run_order_rig('check-snp')
        self.assertEqual(code, 0, out + err)
        self.assertIn('PASS  booted in UEFI mode', out)
        self.assertIn('PASS  SEV-SNP host check', out)
        # The rig file names the install disk, so the check describes it.
        self.assertIn('= /dev/nvme1n1, 960 GB', out)
        evidence, = (self.state / 'evidence').glob('host-snp-check-1047102-*.txt')
        self.assertIn('server 1047102 at 84.32.220.45', evidence.read_text())
        self.assertIn('exit=0', evidence.read_text())
        os.environ['FIXTURE_SNP'] = 'host gate not passed'
        code, out, err = self.run_order_rig('check-snp')
        self.assertEqual(code, 1)
        self.assertIn('FAIL  the SEV-SNP host check did not pass', out)

    def test_host_keys_of_an_earlier_rig_are_moved_aside(self):
        (self.state / 'known_hosts').write_text('185.8.107.144 ssh-ed25519 AAAAold\n')
        (self.state / 'known_hosts.servers').write_text('1 2\n')
        code, out, err = self.run_order_rig('--region', 'US-Chicago', '--project', '295530', '--ssh-key', str(self.key),
                                            '--pull-secret', str(self.pull_secret), '--confirm-order')
        self.assertEqual(code, 0, out + err)
        self.assertEqual((self.state / 'known_hosts').read_text(), '')
        self.assertEqual(len(list(self.state.glob('known_hosts.*.old'))), 1)


class ControllerEnvironment(unittest.TestCase):
    """source scripts/env.sh on a controller that is already set up: it only sets variables."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='coco-env-')
        self.addCleanup(self.tmp.cleanup)
        base = Path(self.tmp.name)
        self.state, self.stubs = base / 'state', base / 'stubs'
        (self.state / 'controller-venv/bin').mkdir(parents=True)
        self.stubs.mkdir()
        for name in ('ssh', 'ssh-keygen'):
            (self.stubs / name).write_text('#!/bin/sh\nexit 0\n')
            (self.stubs / name).chmod(0o755)
        (self.state / 'controller-venv/bin/python3').symlink_to(sys.executable)
        (self.state / 'controller-venv/bin/activate').write_text('export VIRTUAL_ENV=fixture-venv\n')
        stamp = subprocess.run([sys.executable, '-c', 'import hashlib, sys; d = hashlib.sha256()\n'
                                'for p in sys.argv[1:]: d.update(open(p, "rb").read())\nprint(d.hexdigest())',
                                str(ROOT / 'requirements-dev.txt'), str(ROOT / 'install/release-manifest.json')],
                               capture_output=True, text=True, check=True).stdout
        (self.state / '.controller-ready').write_text(stamp)

    def source(self, state=None, script='source scripts/env.sh </dev/null'):
        env = dict(os.environ, PATH=f'{self.stubs}:{os.environ["PATH"]}', COCO_STATE_DIR=str(state or self.state))
        env.pop('CHERRY_SERVERS_API_KEY', None)
        report = '; echo "status=$?"; for v in CHERRY_SERVERS_API_KEY CHERRY_API_KEY TF_DATA_DIR VIRTUAL_ENV LAB; do echo "$v=${!v}"; done; echo "PATH=$PATH"'
        result = subprocess.run(['bash', '-c', script + report], cwd=ROOT, env=env, capture_output=True, text=True)
        return dict(line.split('=', 1) for line in result.stdout.splitlines() if '=' in line), result

    def test_a_set_up_controller_only_gets_its_variables(self):
        (self.state / 'cherry-api-key').write_text('fixture-key\n')
        (self.state / 'lab.env').write_text('export LAB=loaded\n')
        values, result = self.source()
        self.assertEqual(values['status'], '0', result.stderr)
        self.assertEqual((values['CHERRY_SERVERS_API_KEY'], values['CHERRY_API_KEY']), ('fixture-key', 'fixture-key'))
        self.assertEqual(values['TF_DATA_DIR'], str(self.state / 'terraform'))
        self.assertEqual(values['VIRTUAL_ENV'], 'fixture-venv')
        self.assertEqual(values['LAB'], 'loaded')
        self.assertTrue(values['PATH'].startswith(f'{self.state}/bin:'))
        self.assertNotIn('fixture-key', result.stdout.split('status=')[0])

    def test_the_first_setup_installs_the_tools_without_oc_mirror(self):
        stamp = (self.state / '.controller-ready').read_text()
        (self.state / '.controller-ready').unlink()
        calls = self.state.parent / 'calls'
        (self.stubs / 'python3').write_text(f'#!/bin/sh\nif [ "$1" = -m ] && [ "$2" = pip ]; then echo pip >> {calls}; exit 0; fi\n'
                                            f'exec {sys.executable} "$@"\n')
        (self.stubs / 'make').write_text(f'#!/bin/sh\necho "$* INSTALL_OC_MIRROR=${{INSTALL_OC_MIRROR:-unset}}" >> {calls}\n')
        for name in ('python3', 'make'):
            (self.stubs / name).chmod(0o755)
        values, result = self.source()
        self.assertEqual(values['status'], '0', result.stderr)
        self.assertEqual(calls.read_text().splitlines(), [
            'pip',
            f'-C {ROOT} --no-print-directory preflight INSTALL_OC_MIRROR=unset',
            f'-C {ROOT} --no-print-directory fetch-cli-tools INSTALL_OC_MIRROR=0',
        ])
        self.assertEqual((self.state / '.controller-ready').read_text(), stamp)

    def test_without_a_terminal_the_key_is_not_asked_for(self):
        values, result = self.source()
        self.assertEqual(values['status'], '0', result.stderr)
        self.assertEqual(values['CHERRY_SERVERS_API_KEY'], '')
        self.assertFalse((self.state / 'cherry-api-key').exists())

    def test_state_inside_the_checkout_and_running_instead_of_sourcing_are_refused(self):
        values, result = self.source(state=ROOT / 'state-in-checkout')
        self.assertNotEqual(values['status'], '0')
        self.assertIn('inside the checkout', result.stderr)
        self.assertFalse((ROOT / 'state-in-checkout').exists())
        _, result = self.source(script='bash scripts/env.sh')
        self.assertIn('source this file', result.stderr)


if __name__ == '__main__':
    unittest.main()
