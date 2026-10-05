"""Exercise signature-result classification with local command fixtures only."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class SignatureVerifier(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='coco-signature-')
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                        ARTIFACT_DIR=str(self.base), RUNG_SIGNED_IMAGE='example.invalid/signed:fixture',
                        RUNG_SIGNED_UNSIGNED_IMAGE='example.invalid/unsigned:fixture',
                        FIXTURE_SKOPEO_LOG=str(self.base / 'skopeo-calls'),
                        COSIGN_UNSIGNED_ERROR='no matching signatures', COSIGN_SIGNED_RC='0', COSIGN_UNSIGNED_RC='1')
        (self.base / 'cosign.pub').write_text('fixture-public-key')
        self.executable('skopeo', '''#!/usr/bin/env python3
import json,os,sys
with open(os.environ['FIXTURE_SKOPEO_LOG'],'a') as stream: stream.write(json.dumps(sys.argv[1:])+'\\n')
print(json.dumps({"Digest":"sha256:"+"a"*64}))
''')
        self.executable('cosign', '''#!/usr/bin/env python3
import os,sys
negative='/unsigned@' in sys.argv[-1]
if negative: print(os.environ['COSIGN_UNSIGNED_ERROR'],file=sys.stderr)
raise SystemExit(int(os.environ['COSIGN_UNSIGNED_RC' if negative else 'COSIGN_SIGNED_RC']))
''')

    def executable(self, name, text):
        path = self.bin / name
        path.write_text(text)
        path.chmod(0o755)

    def run_verifier(self, expected):
        result = subprocess.run(['bash', str(ROOT / 'scripts/verify-rung-signed-signature.sh')],
                                cwd=self.base, env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def test_recognized_signature_rejection_passes(self):
        self.assertIn('attributable signature rejection', self.run_verifier(0))

    def test_accepted_unsigned_image_fails(self):
        self.env['COSIGN_UNSIGNED_RC'] = '0'
        self.assertIn('unexpectedly verifies', self.run_verifier(1))

    def test_transport_and_unknown_errors_never_pass(self):
        for error in ('no matching signatures: no such host', 'signature verification failed: x509 certificate',
                      'no signatures found: 403 Forbidden', 'connection refused', 'unknown verifier failure',
                      'no signatures found: context deadline exceeded'):
            with self.subTest(error=error):
                self.env['COSIGN_UNSIGNED_ERROR'] = error
                out = self.run_verifier(3)
                self.assertIn('INCOMPLETE', out)
                self.assertNotIn('verification OK', out)

    def test_failed_positive_is_incomplete(self):
        self.env['COSIGN_SIGNED_RC'] = '1'
        self.assertIn('positive control', self.run_verifier(3))

    def test_signed_only_build_checks_negative_and_exports_safe_paths(self):
        # Existing fixture key pair avoids key generation; no real key or registry is used.
        (self.base / 'cosign.key').write_text('fixture-key')
        pub = self.base / 'public key with spaces.pub'
        pub.write_text('fixture-public-key')
        self.env.update(COSIGN_PASSWORD='fixture', COSIGN_KEY=str(self.base / 'cosign.key'),
                        COSIGN_PUB=str(pub), MIRROR_REGISTRY='example.invalid')
        for key in ('SOURCE_IMAGE', 'SOURCE_IMAGE_REF', 'ARTIFACTORY_REGISTRY', 'RELEASE_MANIFEST'):
            self.env.pop(key, None)
        script = ['bash', str(ROOT / 'scripts/build-rung-images.sh'), 'sign-rung-signed-only']
        result = subprocess.run(script, cwd=self.base, env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        bom = json.loads((ROOT / 'install/release-manifest.json').read_text())
        expected_source = 'docker://example.invalid/' + bom['images']['ubiMinimal']['ref'].split('/', 1)[1]
        copies = [json.loads(line) for line in (self.base / 'skopeo-calls').read_text().splitlines()
                  if json.loads(line)[0] == 'copy']
        self.assertEqual(len(copies), 2)
        self.assertTrue(all(expected_source in args for args in copies))
        manifest = json.loads((self.base / 'rung-signed-manifest.json').read_text())
        self.assertEqual(manifest['rung_signed']['cosign_pub'], str(pub))
        sourced = subprocess.run(['bash', '-c', 'source "$1"; printf "%s" "$RUNG_SIGNED_COSIGN_PUB"',
                                  'fixture', str(self.base / 'rung-signed.env')], capture_output=True, text=True)
        self.assertEqual(sourced.returncode, 0, sourced.stderr)
        self.assertEqual(sourced.stdout, str(pub))
        self.env['COSIGN_UNSIGNED_RC'] = '0'
        result = subprocess.run(script, cwd=self.base, env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('unexpectedly verifies', result.stderr)

    def test_builder_preserves_partial_cosign_identity(self):
        key = self.base / 'custom.key'
        key.write_text('existing-fixture-key')
        self.env.update(COSIGN_PASSWORD='fixture', COSIGN_KEY=str(key),
                        COSIGN_PUB=str(self.base / 'missing.pub'))
        result = subprocess.run(['bash', str(ROOT / 'scripts/build-rung-images.sh'), 'sign-rung-signed-only'],
                                cwd=self.base, env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn('restore the missing companion', result.stderr)
        self.assertEqual(key.read_text(), 'existing-fixture-key')

    def test_builder_rejects_homelab_root_even_with_external_key_paths(self):
        self.env.update(ARTIFACT_DIR='/mnt/c/homelab', COSIGN_KEY=str(self.base / 'key'),
                        RUNG_ENCRYPTED_KEY_FILE=str(self.base / 'image-key'))
        result = subprocess.run(['bash', str(ROOT / 'scripts/build-rung-images.sh'), 'digest-ref',
                                 'example/image:tag', 'sha256:' + 'a' * 64],
                                cwd=self.base, env=self.env, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('outside the repository and Homelab', result.stderr)


if __name__ == '__main__':
    unittest.main()
