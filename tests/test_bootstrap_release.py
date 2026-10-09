"""Ansible must consume and validate the same selected release as shell entry points."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which('ansible-playbook'), 'requires local Ansible')
class BootstrapRelease(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='coco-bootstrap-release-')
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.config = self.base / 'ansible.cfg'
        self.config.write_text('[defaults]\nstdout_callback=default\nretry_files_enabled=False\n')
        self.env = dict(os.environ, ANSIBLE_CONFIG=str(self.config),
                        ANSIBLE_LOCAL_TEMP=str(self.base / 'local'), ANSIBLE_REMOTE_TEMP=str(self.base / 'remote'))
        for key in ('RELEASE_MANIFEST', 'IMAGESET_CONFIG', 'TEE', 'OCP_VERSION', 'OCP_RELEASE_IMAGE'):
            self.env.pop(key, None)

    def run_play(self, variables, tasks, expected=0):
        play = [{'hosts': 'localhost', 'connection': 'local', 'gather_facts': False,
                 'vars_files': [str(ROOT / 'ansible/group_vars/all.yml')],
                 'tasks': tasks}]
        path = self.base / 'test.yml'
        path.write_text(yaml.safe_dump(play, sort_keys=False))
        result = subprocess.run(['ansible-playbook', '-i', 'localhost,', str(path), '-e', json.dumps(variables)], env=self.env,
                                cwd=self.base, capture_output=True, text=True, timeout=45)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def test_manifest_and_profile_determine_the_consumed_inputs(self):
        bom = json.loads((ROOT / 'install/release-manifest.json').read_text())
        bom['platform'].update(version='4.20.40', releaseImage='example.invalid/release@sha256:' + 'b' * 64)
        bom['profiles']['snp']['imageSet'] = 'install/fixture-snp-images.yaml'
        bom['profiles']['tdx'] = {'imageSet': 'install/fixture-tdx-images.yaml'}
        path = self.base / 'release.json'
        path.write_text(json.dumps(bom))
        self.env.update(RELEASE_MANIFEST=str(path), TEE='tdx')
        out = self.base / 'consumed.json'
        self.run_play({}, [{'ansible.builtin.copy': {
            'dest': str(out), 'mode': '0600', 'content':
            "{{ {'version':ocp_version, 'payload':ocp_release_image, 'images':imageset_config_absolute, 'tee':tee} | to_json }}"}}])
        consumed = json.loads(out.read_text())
        self.assertEqual(consumed['version'], '4.20.40')
        self.assertEqual(consumed['payload'], bom['platform']['releaseImage'])
        self.assertEqual(consumed['tee'], 'tdx')
        self.assertTrue(consumed['images'].endswith('/install/fixture-tdx-images.yaml'))

    def test_direct_playbook_rejects_effective_version_override(self):
        task = next(task for task in yaml.safe_load((ROOT / 'ansible/playbooks/site.yml').read_text())[0]['tasks']
                    if task['name'] == 'Validate the effective Ansible release and profile inputs')
        task['ansible.builtin.command']['argv'][1] = str(ROOT / 'scripts/verify-release.py')
        out = self.run_play({'release_manifest_path': str(ROOT / 'install/release-manifest.json'),
                            'imageset_config_absolute': str(ROOT / 'install/imageset-config.yaml'),
                            'ocp_version': '4.20.18', 'install_mode': 'verify'}, [task], 2)
        self.assertIn('OCP_VERSION override disagrees with BOM', out)


if __name__ == '__main__':
    unittest.main()
