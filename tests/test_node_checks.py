"""The read-only node checks that run before the AMD node is erased."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts/lib'))
import node_checks  # noqa: E402

ROOT_DEVICE = '/dev/disk/by-path/pci-0000:01:00.0-nvme-1'
FACTS = {'hostname': 'sno-coco-node', 'cpu': 'AMD EPYC 9254 24-Core Processor',
         'system': 'Supermicro Super Server', 'board': 'H13SST-G', 'bios_version': '3.7',
         'bios_date': '06/12/2025', 'uefi': True, 'root_device': ROOT_DEVICE, 'root_path': '/dev/nvme1n1',
         'disks': [{'name': 'nvme0n1', 'path': '/dev/nvme0n1', 'type': 'disk', 'size': 960197124096,
                    'serial': '241848968827', 'model': 'Micron_7450', 'tran': 'nvme'},
                   {'name': 'nvme1n1', 'path': '/dev/nvme1n1', 'type': 'disk', 'size': 960197124096,
                    'serial': '24184896895E', 'model': 'Micron_7450', 'tran': 'nvme'},
                   {'name': 'sda', 'path': '/dev/sda', 'type': 'disk', 'size': 0, 'tran': 'usb'}]}


def fake_ssh(facts=FACTS, snp_rc=0, identity_rc=0):
    calls = []

    def ssh(command, stdin):
        calls.append(command)
        if command.startswith('python3 -'):
            assert '/sys/class/dmi/id' in stdin
            return subprocess.CompletedProcess(command, identity_rc, json.dumps(facts) if identity_rc != 255 else '',
                                               'Connection refused' if identity_rc == 255 else '')
        assert command == 'bash -s' and 'SEV-SNP host gate' in stdin
        return subprocess.CompletedProcess(command, snp_rc, 'RESULT: fixture\n', '')
    ssh.calls = calls
    return ssh


class NodeChecks(unittest.TestCase):
    def test_a_good_node_passes_and_its_install_disk_is_described(self):
        ssh = fake_ssh()
        report = node_checks.check_node(ssh, 'sno-coco-node', ROOT_DEVICE)
        self.assertTrue(report['passed'], report['problems'])
        self.assertEqual(ssh.calls, ['python3 - ' + ROOT_DEVICE, 'bash -s'])
        text = '\n'.join(report['lines'])
        self.assertIn('BIOS 3.7 (06/12/2025)', text)
        self.assertIn('= /dev/nvme1n1, 960 GB, Micron_7450, serial 24184896895E', text)
        self.assertIn('left as it is: /dev/nvme0n1', text)
        self.assertNotIn('/dev/sda', text)  # the BMC's virtual media

    def test_each_failed_check_is_named(self):
        cases = (
            (dict(facts=dict(FACTS, uefi=False)), 'did not boot in UEFI mode'),
            (dict(snp_rc=1), 'SEV-SNP host check did not pass'),
            (dict(facts=dict(FACTS, hostname='other')), 'calls itself other'),
            (dict(facts=dict(FACTS, root_path='')), f'install disk {ROOT_DEVICE} is not a disk'),
        )
        for kwargs, problem in cases:
            with self.subTest(problem=problem):
                report = node_checks.check_node(fake_ssh(**kwargs), 'sno-coco-node', ROOT_DEVICE)
                self.assertFalse(report['passed'])
                self.assertEqual(len(report['problems']), 1)
                self.assertIn(problem, report['problems'][0])
                self.assertIn('FAIL  ' + report['problems'][0], report['lines'])

    def test_no_ssh_means_nothing_was_checked(self):
        with self.assertRaisesRegex(node_checks.NodeUnreachable, 'Connection refused'):
            node_checks.check_node(fake_ssh(identity_rc=255), 'sno-coco-node', ROOT_DEVICE)

    def test_evidence_names_the_machine_and_is_private(self):
        report = node_checks.check_node(fake_ssh(), 'sno-coco-node', ROOT_DEVICE)
        with tempfile.TemporaryDirectory() as tmp:
            path = node_checks.save_evidence(report, Path(tmp) / 'evidence', '1047102', '84.32.220.45')
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            text = path.read_text()
            # A second check in the same second keeps both files.
            again = node_checks.save_evidence(report, Path(tmp) / 'evidence', '1047102', '84.32.220.45')
            self.assertNotEqual(again, path)
            self.assertEqual(len(list((Path(tmp) / 'evidence').iterdir())), 2)
        self.assertTrue(text.startswith('server 1047102 at 84.32.220.45\n'))
        self.assertIn('RESULT: fixture', text)
        self.assertTrue(text.endswith('exit=0\n'))

    def test_the_identity_script_runs_on_this_machine(self):
        # The script that runs on the node needs only Python, /sys and lsblk.
        if not sys.platform.startswith('linux') or not shutil.which('lsblk'):
            self.skipTest('needs Linux with lsblk')
        result = subprocess.run([sys.executable, '-', '/nonexistent'], input=node_checks.IDENTIFY,
                                capture_output=True, text=True, check=True)
        facts = json.loads(result.stdout)
        self.assertEqual(facts['root_path'], '')
        self.assertIsInstance(facts['uefi'], bool)
        self.assertTrue(all(d['type'] == 'disk' for d in facts['disks']))


if __name__ == '__main__':
    unittest.main()
