"""Run the raw-host gate against fixtures without loading modules or touching firmware."""
import os
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'scripts/host-snp-check.sh'
GOOD_LOG = '''ccp 0000:44:00.1: SEV-SNP API:1.55 build:24
SEV-SNP: RMP table physical range [0x0000000100000000 - 0x0000000101000000]
kvm_amd: SEV-SNP enabled (ASIDs 1 - 99)
'''
MISSING_RMP = 'SEV-SNP: Memory for the RMP table has not been reserved by BIOS\n'
INIT_FAILED = 'ccp 0000:44:00.1: SEV: INIT failed 0x13, rc -5\n'


class HostSnpCheckTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='coco-host-snp-')
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name)
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        self.module = self.base / 'sys/module/kvm_amd'
        self.parameter = self.module / 'parameters/sev_snp'
        self.device = self.base / 'dev/sev'
        self.device.parent.mkdir()
        self.device.touch()
        self.parameter.parent.mkdir(parents=True)
        self.parameter.write_text('Y\n')
        self.log = self.base / 'dmesg.txt'
        self.log.write_text(GOOD_LOG)
        self.metadata = self.base / 'modinfo.txt'
        self.metadata.write_text('sev:Enable SEV (bool)\nsev_snp:Enable SEV-SNP (bool)\n')
        self.calls = self.base / 'calls'
        self.script = self.base / 'host-snp-check.sh'
        # Substitute only fixed filesystem locations; execute the production
        # control flow and commands unchanged, with fixture command responses.
        self.script.write_text(SCRIPT.read_text().replace(
            '/sys/module/kvm_amd', str(self.module)).replace('/dev/sev', str(self.device)))
        self.bash = shutil.which('bash')
        self.executable('hostname', '#!/bin/sh\nprintf "%s\\n" fixture-node\n')
        self.executable('uname', '#!/bin/sh\nprintf "%s\\n" "${FIXTURE_KERNEL:-6.8.0-backport}"\n')
        self.executable('lscpu', '#!/bin/sh\nprintf "%s\\n" "Model name: AMD EPYC 9124"\n')
        self.executable('dmesg', '#!/bin/sh\n[ "${FIXTURE_LOG_DENIED:-0}" = 0 ] || exit 1\ncat "$FIXTURE_LOG"\n')
        self.executable('modinfo', '''#!/bin/sh
printf '%s\n' "modinfo $*" >> "$FIXTURE_CALLS"
[ "$*" = '-p kvm_amd' ] || exit 2
[ "${FIXTURE_NO_METADATA:-0}" = 0 ] || exit 1
cat "$FIXTURE_METADATA"
''')
        for name in ('modprobe', 'insmod', 'rmmod', 'reboot', 'shutdown'):
            self.executable(name, '#!/bin/sh\nprintf "%s\\n" "MUTATION $0 $*" >> "$FIXTURE_CALLS"\nexit 99\n')

    def executable(self, name, content):
        path = self.bin / name
        path.write_text(content)
        path.chmod(0o755)

    def run_gate(self, expected, **settings):
        environment = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                           FIXTURE_LOG=str(self.log), FIXTURE_METADATA=str(self.metadata),
                           FIXTURE_CALLS=str(self.calls), **settings)
        result = subprocess.run([self.bash, str(self.script)], env=environment,
                                text=True, capture_output=True, timeout=10)
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, expected, output)
        calls = self.calls.read_text() if self.calls.exists() else ''
        self.assertNotIn('MUTATION', calls, calls)
        return output

    def test_loaded_backport_passes_without_kernel_config_or_module_metadata(self):
        output = self.run_gate(0, FIXTURE_NO_METADATA='1')
        self.assertIn('6.8.0-backport', output)
        self.assertIn('host prerequisites passed', output)
        self.assertIn('attestation remain separate proofs', output)

    def test_capable_but_unloaded_module_is_not_a_bios_failure(self):
        shutil.rmtree(self.module)
        output = self.run_gate(1)
        self.assertIn('-> MODULE NOT LOADED:', output)
        self.assertIn('BIOS state is not established', output)
        self.assertNotIn('-> SNP NOT ENABLED', output)

    def test_running_module_without_snp_parameter_overrides_disk_metadata(self):
        self.parameter.unlink()
        self.assertIn('-> KERNEL/IMAGE:', self.run_gate(1))
        self.assertFalse(self.calls.exists(), 'running-module evidence must take precedence')

    def test_unloaded_module_without_snp_metadata_fails_kernel_capability(self):
        shutil.rmtree(self.module)
        self.metadata.write_text('sev:Enable SEV (bool)\n')
        self.assertIn('-> KERNEL/IMAGE:', self.run_gate(1, FIXTURE_KERNEL='6.20.0'))

    def test_unavailable_module_metadata_leaves_capability_unknown(self):
        shutil.rmtree(self.module)
        self.assertIn('-> CAPABILITY UNKNOWN:', self.run_gate(1, FIXTURE_NO_METADATA='1'))

    def test_loaded_disabled_parameter_requires_options_and_firmware_diagnosis(self):
        self.parameter.write_text('N\n')
        output = self.run_gate(1)
        self.assertIn('-> SNP NOT ENABLED', output)
        self.assertIn('kernel command-line/module options', output)
        self.assertNotIn('-> MODULE NOT LOADED', output)

    def test_unrelated_error_0x3_does_not_fail_snp(self):
        self.log.write_text(GOOD_LOG + 'nvme 0000:11:00.0: Error: 0x3\n')
        self.run_gate(0)

    def test_relevant_error_0x3_blocks_without_inventing_memory_interleaving_cause(self):
        for driver in ('ccp 0000:44:00.1: SEV', 'psp', 'SEV'):
            with self.subTest(driver=driver):
                self.log.write_text(GOOD_LOG + driver + ': Error: 0x3\n')
                output = self.run_gate(1)
                self.assertIn('-> PSP INVALID_CONFIG (0x3)', output)
                self.assertIn('this error alone does not identify the cause', output)
                self.assertNotIn('Memory Interleaving is enabled', output)

    def test_other_relevant_hex_code_is_not_misread_as_0x3(self):
        self.log.write_text(GOOD_LOG + 'ccp 0000:44:00.1: SEV: Error: 0x30\n')
        self.run_gate(0)

    def test_unreadable_log_is_missing_evidence_not_bios_diagnosis(self):
        self.assertIn('-> INSUFFICIENT EVIDENCE:', self.run_gate(1, FIXTURE_LOG_DENIED='1'))

    def test_missing_device_blocks_without_provider_veto(self):
        self.device.unlink()
        self.assertIn('-> INCOMPLETE HOST EVIDENCE:', self.run_gate(1))

    def test_missing_rmp_or_api_evidence_blocks(self):
        for absent in ('RMP table', 'SEV-SNP API'):
            with self.subTest(absent=absent):
                self.log.write_text('\n'.join(line for line in GOOD_LOG.splitlines() if absent not in line))
                self.assertIn('-> INCOMPLETE HOST EVIDENCE:', self.run_gate(1))

    def test_live_missing_rmp_and_init_error_cannot_count_as_positive_evidence(self):
        self.log.write_text(MISSING_RMP + 'AMD-Vi: Extended features: PPR PC SNP\n'
                            + 'ccp 0000:44:00.1: sev enabled\n' + INIT_FAILED
                            + 'kvm_amd: SEV disabled (ASIDs 100 - 509)\n')
        self.parameter.write_text('N\n')
        output = self.run_gate(1)
        self.assertIn('FAIL  RMP physical allocation range reported', output)
        self.assertIn('FAIL  no CCP/PSP/SEV initialization failure', output)
        self.assertIn('-> PSP INITIALIZATION FAILED:', output)

    def test_missing_rmp_error_alone_fails_even_with_positive_api_and_enabled_parameter(self):
        self.log.write_text('\n'.join(line for line in GOOD_LOG.splitlines()
                                      if 'RMP table' not in line) + '\n' + MISSING_RMP)
        output = self.run_gate(1)
        self.assertIn('FAIL  RMP physical allocation range reported', output)
        self.assertIn('-> RMP RESERVATION/MAPPING FAILED:', output)

    def test_rmp_failure_overrides_an_earlier_positive_range(self):
        for error in (MISSING_RMP, 'SEV-SNP: RMP configuration not valid: base=0x2000, end=0x1000\n',
                      'SEV-SNP: Memory reserved for the RMP table does not cover full system RAM\n',
                      'SEV-SNP: Failed to map RMP table\n'):
            with self.subTest(error=error):
                self.log.write_text(GOOD_LOG + error)
                self.assertIn('FAIL  no RMP reservation/mapping failure', self.run_gate(1))

    def test_psp_init_failure_overrides_otherwise_positive_host_evidence(self):
        for error in (INIT_FAILED, 'ccp 0000:44:00.1: SEV: failed to INIT error 0x13, rc -5\n',
                      'ccp 0000:44:00.1: SEV-SNP: failed to INIT rc -5, error 0x13\n'):
            with self.subTest(error=error):
                self.log.write_text(GOOD_LOG + error)
                self.assertIn('-> PSP INITIALIZATION FAILED:', self.run_gate(1))

    def test_positive_range_formats_pass_but_vague_phrases_do_not(self):
        for message in ('SEV-SNP: RMP table physical range [0x100000 - 0x200000]',
                        'SEV-SNP: RMP table physical address [0x100000 - 0x200000]',
                        'SEV-SNP: RMP table physical address 0x100000 - 0x200000'):
            with self.subTest(message=message):
                self.log.write_text(GOOD_LOG.replace(GOOD_LOG.splitlines()[1], message))
                self.run_gate(0)
        self.log.write_text(GOOD_LOG.replace(GOOD_LOG.splitlines()[1],
                                            'SEV-SNP: RMP table physical range unavailable'))
        self.assertIn('FAIL  RMP physical allocation range reported', self.run_gate(1))


class ClusterSnpCheckTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='coco-cluster-snp-')
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name)
        self.log = self.base / 'dmesg.txt'
        self.log.write_text(GOOD_LOG)
        self.calls = self.base / 'calls.jsonl'
        oc = self.base / 'oc'
        oc.write_text(f'#!{sys.executable}\n' + '''import json, os, pathlib, sys
args = sys.argv[1:]
with open(os.environ['FIXTURE_CALLS'], 'a') as stream:
    stream.write(json.dumps(args) + '\\n')
assert args[:2] == ['--context=fixture-worker', '--request-timeout=30s'], args
assert args[2:-1] == ['debug', 'node/fixture-node', '--quiet', '--', 'chroot', '/host', 'bash', '-c'], args
command = args[-1]
if command == 'dmesg':
    print(pathlib.Path(os.environ['FIXTURE_LOG']).read_text())
    sys.exit(int(os.environ.get('FIXTURE_LOG_EXIT', '0')))
if command.startswith('cat /sys/module/kvm_amd/parameters/sev_snp'):
    print(os.environ.get('FIXTURE_PARAMETER', 'Y'))
elif command.startswith('lscpu '):
    print('AMD EPYC fixture')
elif command == 'test -e /dev/sev':
    sys.exit(0)
else:
    raise AssertionError(command)
''')
        oc.chmod(0o755)

    def run_gate(self, expected, **settings):
        environment = dict(os.environ, PATH=str(self.base) + os.pathsep + os.environ['PATH'],
                           WORKER_CONTEXT='fixture-worker', OC_REQUEST_TIMEOUT='30s',
                           FIXTURE_LOG=str(self.log), FIXTURE_CALLS=str(self.calls), **settings)
        result = subprocess.run(['bash', str(ROOT / 'scripts/verify-snp-host.sh'), 'fixture-node'],
                                env=environment, text=True, capture_output=True, timeout=10)
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, expected, output)
        self.assertNotIn('AssertionError', output)
        return output

    def test_positive_host_uses_selected_context_and_node(self):
        self.assertIn('host checks passed', self.run_gate(0))
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        self.assertEqual(len(calls), 4)
        self.assertTrue(all('node/fixture-node' in call for call in calls))

    def test_missing_rmp_error_cannot_replace_positive_allocation_evidence(self):
        self.log.write_text('\n'.join(line for line in GOOD_LOG.splitlines()
                                      if 'RMP table' not in line) + '\n' + MISSING_RMP)
        output = self.run_gate(1)
        self.assertIn('FAIL  RMP physical allocation range reported', output)
        self.assertIn('FAIL  no RMP reservation/mapping failure', output)

    def test_real_failure_lines_block_with_device_present(self):
        self.log.write_text(MISSING_RMP + INIT_FAILED + 'ccp 0000:44:00.1: sev enabled\n')
        output = self.run_gate(1, FIXTURE_PARAMETER='N')
        self.assertIn('FAIL  RMP physical allocation range reported', output)
        self.assertIn('FAIL  no CCP/PSP/SEV initialization failure', output)

    def test_init_failure_cannot_hide_behind_positive_api_and_range(self):
        self.log.write_text(GOOD_LOG + INIT_FAILED)
        self.assertIn('FAIL  no CCP/PSP/SEV initialization failure', self.run_gate(1))

    def test_rmp_error_cannot_hide_behind_an_earlier_positive_range(self):
        self.log.write_text(GOOD_LOG + 'SEV-SNP: Failed to map RMP table\n')
        self.assertIn('FAIL  no RMP reservation/mapping failure', self.run_gate(1))

    def test_log_command_failure_is_not_swallowed(self):
        self.assertIn('FAIL  kernel log readable', self.run_gate(1, FIXTURE_LOG_EXIT='1'))


if __name__ == '__main__':
    unittest.main()
