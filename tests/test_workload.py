import base64
import gzip
from pathlib import Path
import sys
import tempfile
import tomllib
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts/lib'))
from workload import initdata, render


class WorkloadTests(unittest.TestCase):
    def test_private_mirror_chain_is_split_into_certificates(self):
        with tempfile.TemporaryDirectory() as temp:
            chain = Path(temp) / 'ca.pem'
            first = '-----BEGIN CERTIFICATE-----\nAAA\n-----END CERTIFICATE-----\n'
            second = first.replace('AAA', 'BBB')
            chain.write_text(first + second)
            raw = initdata({'TRUSTEE_LAB': '1', 'TRUSTEE_PROFILE': 'Permissive', 'MIRROR_CA': str(chain)}, 'kbs')
            cdh = tomllib.loads(tomllib.loads(raw.decode())['data']['cdh.toml'])
            self.assertEqual(cdh['image']['extra_root_certificates'], [first, second])
            chain.write_text(first + 'broken certificate')
            with self.assertRaisesRegex(ValueError, 'only PEM'):
                initdata({'TRUSTEE_LAB': '1', 'TRUSTEE_PROFILE': 'Permissive', 'MIRROR_CA': str(chain)}, 'kbs')

    def test_https_certificate_reaches_both_clients_and_policy_is_preserved(self):
        with tempfile.TemporaryDirectory() as temp:
            cert, policy = Path(temp) / 'ca.pem', Path(temp) / 'policy.rego'
            cert.write_text('-----BEGIN CERTIFICATE-----\nAAA\n-----END CERTIFICATE-----\n')
            policy.write_text('package agent_policy\ndefault ExecProcessRequest := false\n')
            raw = initdata({'KBS_URL': 'https://trustee.example', 'KBS_CA_FILE': str(cert), 'AGENT_POLICY_FILE': str(policy)}, 'kbs')
            data = tomllib.loads(raw.decode())['data']
            aa = tomllib.loads(data['aa.toml'])['token_configs']['kbs']
            cdh = tomllib.loads(data['cdh.toml'])['kbc']
            self.assertEqual(aa['cert'], cdh['kbs_cert'])
            self.assertEqual(data['policy.rego'], policy.read_text())

    def test_customer_http_and_missing_policy_are_rejected(self):
        with self.assertRaisesRegex(ValueError, 'HTTP Trustee'):
            initdata({'TRUSTEE_LAB': '1', 'TRUSTEE_PROFILE': 'Restricted'}, 'kbs')
        with self.assertRaisesRegex(ValueError, 'HTTP Trustee'):
            initdata({}, 'kbs')
        with self.assertRaisesRegex(ValueError, 'AGENT_POLICY_FILE'):
            initdata({'KBS_URL': 'https://trustee.example'}, 'kbs')

    def test_same_bytes_emit_render_and_tamper_without_changing_configuration(self):
        env = {'TRUSTEE_LAB': '1', 'TRUSTEE_PROFILE': 'Permissive'}
        raw = initdata(env, 'kbs')
        pod = render(env, 'kbs')
        encoded = pod['metadata']['annotations']['io.katacontainers.config.hypervisor.cc_init_data']
        self.assertEqual(raw, gzip.decompress(base64.b64decode(encoded)))
        tampered = initdata({**env, 'TAMPER_INITDATA': '1'}, 'kbs')
        self.assertNotEqual(raw, tampered)
        self.assertEqual(tomllib.loads(raw.decode()), tomllib.loads(tampered.decode()))
        self.assertIn('-o /dev/null', pod['spec']['initContainers'][0]['command'][-1])

    def test_approved_bytes_are_reused_and_wrong_rung_policy_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'initdata.toml'
            raw = initdata({'TRUSTEE_LAB': '1', 'TRUSTEE_PROFILE': 'Permissive'}, 'kbs') + b'\n# approved bytes\n'
            path.write_bytes(raw)
            env = {'TRUSTEE_LAB': '1', 'TRUSTEE_PROFILE': 'Permissive', 'INITDATA_FILE': str(path)}
            self.assertEqual(initdata(env, 'kbs'), raw)
            with self.assertRaisesRegex(ValueError, 'policy URI'):
                initdata(env, 'signed')

    def test_negative_plain_pod_drops_runtime_contract(self):
        pod = render({'TRUSTEE_LAB': '1', 'TRUSTEE_PROFILE': 'Permissive', 'CONFIDENTIAL': '0'}, 'kbs')
        self.assertNotIn('runtimeClassName', pod['spec'])
        self.assertNotIn('coco-resource-default', pod['metadata']['labels'])

    def test_signed_requires_digest_and_does_not_need_encryption_inputs(self):
        with self.assertRaisesRegex(ValueError, 'immutable'):
            render({'TRUSTEE_LAB': '1', 'TRUSTEE_PROFILE': 'Permissive', 'RUNG_SIGNED_IMAGE': 'test:signed'}, 'signed')
        pod = render({'TRUSTEE_LAB': '1', 'TRUSTEE_PROFILE': 'Permissive', 'RUNG_SIGNED_IMAGE': 'test@sha256:' + 'a' * 64}, 'signed')
        self.assertEqual(pod['spec']['containers'][0]['imagePullPolicy'], 'Always')


if __name__ == '__main__':
    unittest.main()
