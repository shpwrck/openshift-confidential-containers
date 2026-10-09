"""Both signed-image controls must enter the same guest signature-verification rule."""
import json
import os
from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
REQUIREMENT = [{'type': 'sigstoreSigned', 'keyPath': 'kbs:///default/sig-public-key/rung-signed'}]


class SignedPolicy(unittest.TestCase):
    def render(self, **overrides):
        env = dict(os.environ)
        for name in ('ARTIFACTORY_REGISTRY', 'MIRROR_REGISTRY', 'RUNG_SIGNED_IMAGE',
                     'RUNG_SIGNED_UNSIGNED_IMAGE', 'RUNG_SIGNED_POLICY_IMAGE_PREFIX'):
            env.pop(name, None)
        env.update(ARTIFACTORY_REGISTRY='mirror.example.test:8443', **overrides)
        result = subprocess.run(['bash', str(ROOT / 'scripts/seed-trustee-secrets.sh'),
                                 'render-rung-signed-policy'], env=env, cwd=ROOT,
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return json.loads(result.stdout)

    def test_default_controls_use_exact_repositories_with_same_requirement(self):
        policy = self.render()
        scopes = policy['transports']['docker']
        self.assertEqual(scopes['mirror.example.test:8443/coco/rung-b'], REQUIREMENT)
        self.assertEqual(scopes['mirror.example.test:8443/coco/rung-b-unsigned'], REQUIREMENT)
        self.assertNotIn('mirror.example.test:8443/coco', scopes)
        self.assertNotIn('mirror.example.test:8443', scopes)
        self.assertEqual(policy['default'], [{'type': 'reject'}])

    def test_configured_digest_and_tag_references_each_get_signature_scope(self):
        scopes = self.render(
            RUNG_SIGNED_IMAGE='signed.example.test:8443/project/accepted@sha256:' + 'a' * 64,
            RUNG_SIGNED_UNSIGNED_IMAGE='unsigned.example.test:9443/controls/rejected:test'
        )['transports']['docker']
        self.assertEqual(scopes['signed.example.test:8443/project/accepted'], REQUIREMENT)
        self.assertEqual(scopes['unsigned.example.test:9443/controls/rejected'], REQUIREMENT)

    def test_explicit_scope_override_still_protects_unsigned_repository(self):
        scopes = self.render(RUNG_SIGNED_POLICY_IMAGE_PREFIX='mirror.example.test:8443/reviewed-project')[
            'transports']['docker']
        self.assertEqual(scopes['mirror.example.test:8443/reviewed-project'], REQUIREMENT)
        self.assertEqual(scopes['mirror.example.test:8443/coco/rung-b'], REQUIREMENT)
        self.assertEqual(scopes['mirror.example.test:8443/coco/rung-b-unsigned'], REQUIREMENT)


if __name__ == '__main__':
    unittest.main()
