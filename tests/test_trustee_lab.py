"""make trustee-lab: the order of the steps, what each one hands the next, the single approval
and the signed-image build on the helper, against a fake oc, ssh and podman and stand-in
repository scripts. No helper or cluster is contacted."""
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import stat
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

import yaml

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("trustee_lab", ROOT / "scripts/trustee-lab.py")
trustee_lab = importlib.util.module_from_spec(spec)
spec.loader.exec_module(trustee_lab)

HWID = "a" * 128
CMDLINE = "console=hvc0 agent.log=debug cc_init_data=fixture"
POLICY = b"package policy\ndefault allow = false\n"
SIGNED = {"digest_ref": "mirror.rig.local:8443/coco/rung-b@sha256:" + "b" * 64,
          "unsigned_digest_ref": "mirror.rig.local:8443/coco/rung-b-unsigned@sha256:" + "c" * 64,
          "cosign_pub": "/var/tmp/coco-signed-images/artifacts/cosign.pub", "cosign_pub_sha256": "d" * 64}

FAKE_OC = r'''#!/usr/bin/env python3
import json, os, sys
fake = os.environ["FAKE_DIR"]
args = [a for a in sys.argv[1:] if not a.startswith(("--context=", "--request-timeout="))]
data = sys.stdin.read() if args[:2] == ["create", "-f"] else ""
with open(os.path.join(fake, "calls"), "a") as log:
    log.write(json.dumps(["oc", *args]) + "\n")
if args[:2] == ["get", "nodes"]:
    print(json.dumps({"items": [{"metadata": {"name": "node-a"}}]}))
elif args[:2] == ["get", "namespace"]:
    pass  # The workload namespace does not exist yet.
elif args[:2] == ["create", "-f"]:
    open(os.path.join(fake, "created-pod.yaml"), "w").write(data)
elif args[0] == "debug":
    # The probe VM needs one wait before QEMU runs.
    count = os.path.join(fake, "debug-count")
    seen = int(open(count).read()) if os.path.exists(count) else 0
    open(count, "w").write(str(seen + 1))
    if seen:
        print(os.environ["FAKE_CMDLINE"])
elif args[:2] in (["create", "namespace"], ["label", "namespace"]) or "delete" in args:
    pass
else:
    sys.exit("unexpected oc call: " + repr(args))
'''
FAKE_SSH = r'''#!/usr/bin/env python3
import io, json, os, sys, tarfile
fake = os.environ["FAKE_DIR"]
command = sys.argv[-1]
data = sys.stdin.buffer.read() if command.startswith("sudo bash") else b""
with open(os.path.join(fake, "calls"), "a") as log:
    log.write(json.dumps(["ssh", command]) + "\n")
if command.startswith("sudo cat") and command.endswith("/ca/rootCA.pem"):
    print("-----BEGIN CERTIFICATE-----\nZml4dHVyZQ==\n-----END CERTIFICATE-----")
elif command.startswith("sudo cat") and command.endswith("/mirror-admin-password"):
    print("fixture-mirror-password")
elif command == "sudo bash -s":
    count = len([n for n in os.listdir(fake) if n.startswith("helper-script-")])
    open(os.path.join(fake, f"helper-script-{count}"), "wb").write(data)
elif command.startswith("sudo bash -c") and "tar -C" in command:
    open(os.path.join(fake, "shipped.tgz"), "wb").write(data)
elif command.startswith("sudo tar -C"):
    out = io.BytesIO()
    with tarfile.open(fileobj=out, mode="w") as tar:
        for name, text in (("cosign.key", "fixture key"), ("cosign.pub", "fixture pub"),
                           ("rung-signed-manifest.json", json.dumps({"rung_signed": json.loads(os.environ["FAKE_SIGNED"])}))):
            info = tarfile.TarInfo(name)
            info.size = len(text.encode())
            tar.addfile(info, io.BytesIO(text.encode()))
    sys.stdout.buffer.write(out.getvalue())
elif command.startswith("sudo rm -rf"):
    pass
else:
    sys.exit("unexpected ssh call: " + command)
'''
FAKE_PODMAN = '''#!/usr/bin/env bash
echo "podman $*" >> "$FAKE_DIR/calls"
'''
# Stand-ins for the repository scripts that trustee-lab drives; each records what it was given.
STUBS = {
    "scripts/collect-vcek.sh": '''#!/usr/bin/env bash
echo "collect-vcek $* NS=${NS:-} BUNDLE=$VCEK_BUNDLE" >> "$FAKE_DIR/calls"
if [[ "$1" != --seed ]]; then
  for id in $FAKE_HWIDS; do mkdir -p "$VCEK_BUNDLE/$id"; echo der > "$VCEK_BUNDLE/$id/vcek.der"; done
fi
''',
    "scripts/apply-trustee.sh": '''#!/usr/bin/env bash
echo "apply-trustee $1 NS=$NS HWIDS=$HWIDS PROFILE=$TRUSTEE_PROFILE LAB=$TRUSTEE_LAB POLICY=${TRUSTEE_RESOURCE_POLICY_FILE:-} RVPS=${TRUSTEE_RVPS_FILE:-} RESOURCES=${KBS_RESOURCE_NAMES:-} SIGNED=${RUNG_SIGNED_IMAGE:-} PUB=${RUNG_SIGNED_COSIGN_PUB:-} MIRROR_CA=$MIRROR_CA MIRROR_PASSWORD_FILE=$MIRROR_PASSWORD_FILE SHOW_NEXT=${SHOW_NEXT:-}" >> "$FAKE_DIR/calls"
''',
    "scripts/verify-release.py": '''import os, sys
open(os.environ["FAKE_DIR"] + "/calls", "a").write("verify-release " + " ".join(sys.argv[1:]) + "\\n")
''',
    "scripts/render-workload.py": '''import os, sys
open(os.environ["FAKE_DIR"] + "/calls", "a").write(f"render {sys.argv[1]} NS={os.environ['NS']} MIRROR_CA={os.environ.get('MIRROR_CA', '')} EMIT={os.environ.get('EMIT_INITDATA', '')} POD={os.environ.get('POD_NAME', '')}\\n")
if os.environ.get("EMIT_INITDATA") == "1":
    sys.stdout.write('algorithm = "sha256"\\nversion = "0.1.0"\\n')
else:
    sys.stdout.write(f"apiVersion: v1\\nkind: Pod\\nmetadata:\\n  name: {os.environ['POD_NAME']}\\n  namespace: {os.environ['NS']}\\n")
''',
    "scripts/gen-rvps-veritas.sh": '''#!/usr/bin/env bash
echo "veritas NODE=[$NODE] PULL_SECRET=$PULL_SECRET INITDATA=$INITDATA CMDLINE=$VERITAS_KERNEL_CMDLINE" >> "$FAKE_DIR/calls"
echo "generated" > "$OUT"
''',
    "scripts/review-references.py": '''import os, sys
open(os.environ["FAKE_DIR"] + "/calls", "a").write(f"review {' '.join(sys.argv[1:])} HWIDS={os.environ['HWIDS']} SHOW_NEXT={os.environ.get('SHOW_NEXT', '')}\\n")
open(sys.argv[2], "w").write("reviewed\\n")
print("snp_launch_measurement  [\\"fixture\\"]  (expires 2027-01-01; Veritas)")
''',
    "scripts/lib/trustee_config.py": '''import json, sys
print(json.dumps([{"secretName": "vcek-snp-aaaaaaaaaaaaaaaa-fixture", "mountPath": "/fixture"}]))
''',
}


class TrusteeLabTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.tmp = Path(temporary.name)
        self.state = self.tmp / "state"
        self.state.mkdir()
        self.fake = self.tmp / "fake"
        self.fake.mkdir()
        for name, text in (("oc", FAKE_OC), ("ssh", FAKE_SSH), ("podman", FAKE_PODMAN)):
            (self.fake / name).write_text(text)
            (self.fake / name).chmod(0o755)
        self.repo = self.tmp / "repo"
        for path in ("ansible/group_vars/all.yml", "install/release-manifest.json"):
            (self.repo / path).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(ROOT / path, self.repo / path)
        manifest = json.loads((self.repo / "install/release-manifest.json").read_text())
        manifest["tools"]["trusteeResourcePolicy"]["sha256"] = hashlib.sha256(POLICY).hexdigest()
        (self.repo / "install/release-manifest.json").write_text(json.dumps(manifest))
        for path, text in STUBS.items():
            (self.repo / path).parent.mkdir(parents=True, exist_ok=True)
            (self.repo / path).write_text(text)
        (self.repo / "scripts/__pycache__").mkdir()
        (self.repo / "scripts/__pycache__/stale.pyc").write_text("")
        (self.tmp / "pull-secret.json").write_text("{}")
        self.rig = {"bastion_ssh_user": "root", "bastion_ansible_host": "203.0.113.10",
                    "bastion_ssh_key": str(self.tmp / "helper-key"), "private_link_known_hosts": str(self.tmp / "known_hosts"),
                    "node_server_id": "1047102", "pull_secret_src": str(self.tmp / "pull-secret.json")}
        self.env = {"PATH": f"{self.fake}:{os.environ['PATH']}", "COCO_STATE_DIR": str(self.state), "HOME": str(self.tmp),
                    "FAKE_DIR": str(self.fake), "FAKE_HWIDS": HWID, "FAKE_CMDLINE": CMDLINE, "FAKE_SIGNED": json.dumps(SIGNED),
                    "WORKER_CONTEXT": "validation", "TRUSTEE_CONTEXT": "validation", "TRUSTEE_LAB": "1",
                    "APPROVE_REFERENCES": "1"}

    def run_lab(self, *argv, stdin=None, **env):
        (self.state / "rig.yml").write_text(yaml.safe_dump(self.rig))
        out, err = io.StringIO(), io.StringIO()
        policy = contextlib.nullcontext(io.BytesIO(POLICY))
        with patch.dict(os.environ, {**self.env, **env}, clear=True), patch.object(trustee_lab, "REPO", self.repo), \
                patch.object(trustee_lab.time, "sleep"), patch.object(trustee_lab.urllib.request, "urlopen", return_value=policy), \
                patch.object(trustee_lab.sys, "stdin", stdin or io.StringIO()), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err), self.child_output() as children:
            try:
                code = trustee_lab.main(list(argv))
            except trustee_lab.Stop as error:
                code, err = 1, io.StringIO(str(error))
        return code, out.getvalue() + children.read_text(), err.getvalue()

    @contextlib.contextmanager
    def child_output(self):
        """Keep what the stand-in scripts print out of the test output."""
        path = self.tmp / "children.out"
        saved = os.dup(1)
        with open(path, "w") as handle:
            os.dup2(handle.fileno(), 1)
        try:
            yield path
        finally:
            os.dup2(saved, 1)
            os.close(saved)

    def calls(self):
        path = self.fake / "calls"
        return [json.loads(line) if line.startswith("[") else line for line in path.read_text().splitlines()] if path.exists() else []

    def text_calls(self, prefix):
        return [c for c in self.calls() if isinstance(c, str) and c.startswith(prefix)]

    def test_a_whole_run_hands_each_step_what_it_needs(self):
        code, out, err = self.run_lab()
        self.assertEqual(0, code, out + err)
        bundle = self.state / "vcek-bundle-1047102"
        # One bundle per node, so a certificate left from an earlier rig is never published.
        self.assertEqual([f"collect-vcek node-a NS= BUNDLE={bundle}", f"collect-vcek --seed NS=trustee-operator-system BUNDLE={bundle}"],
                         self.text_calls("collect-vcek"))
        trustee = self.text_calls("apply-trustee")
        self.assertEqual(2, len(trustee))
        self.assertTrue(trustee[0].startswith(f"apply-trustee bootstrap NS=trustee-operator-system HWIDS={HWID} PROFILE=Permissive LAB=1"))
        # The lab runs the next steps itself, so the bootstrap's hint for a manual run stays quiet.
        self.assertTrue(trustee[0].endswith(" SHOW_NEXT=0"), trustee[0])
        for part in (f"POLICY={self.state / 'resource-policy.rego'}", f"RVPS={self.state / 'rvps-reviewed.yaml'}",
                     "RESOURCES=regcred attestation-cert attestation-status sample credential security-policy registry-configuration sig-public-key",
                     f"SIGNED={SIGNED['digest_ref']}", f"PUB={self.state / 'rung-image-artifacts/cosign.pub'}",
                     f"MIRROR_CA={self.state / 'mirror-ca.pem'}", f"MIRROR_PASSWORD_FILE={self.state / 'mirror-password'}"):
            self.assertIn(part, trustee[1])
        self.assertEqual(POLICY, (self.state / "resource-policy.rego").read_bytes())

        oc = [c[1:] for c in self.calls() if isinstance(c, list) and c[0] == "oc"]
        self.assertIn(["create", "namespace", "coco-validation"], oc)
        for ns in ("coco-validation", "trustee-operator-system"):
            self.assertIn(["label", "namespace", ns, "coco.openshift.io/disposable=true", "--overwrite"], oc)
        self.assertEqual(2, sum(1 for c in oc if c[0] == "debug"))
        self.assertIn("name: cmdline-probe", (self.fake / "created-pod.yaml").read_text())
        # The probe pod goes once the command line is read.
        self.assertIn(["-n", "coco-validation", "delete", "pod", "cmdline-probe", "--ignore-not-found", "--wait=false"], oc)

        for name in ("mirror-ca.pem", "mirror-password", "initdata.toml", "guest-cmdline.txt", "trustee-lab.env"):
            self.assertEqual(0o600, stat.S_IMODE((self.state / name).stat().st_mode), name)
        self.assertEqual(CMDLINE + "\n", (self.state / "guest-cmdline.txt").read_text())
        self.assertIn(f"podman pull --authfile {self.tmp / 'pull-secret.json'} quay.io/openshift_sandboxed_containers/coco-tools@sha256:",
                      "\n".join(self.text_calls("podman")))
        self.assertEqual([f"veritas NODE=[] PULL_SECRET={self.tmp / 'pull-secret.json'} INITDATA={self.state / 'initdata.toml'} CMDLINE={CMDLINE}"],
                         self.text_calls("veritas"))
        self.assertEqual([f"review {self.state / 'rvps-generated.yaml'} {self.state / 'rvps-reviewed.yaml'} --drop init_data HWIDS={HWID} SHOW_NEXT=0"],
                         self.text_calls("review"))
        self.assertIn("Approved ahead with APPROVE_REFERENCES=1.", out)

        env = (self.state / "trustee-lab.env").read_text()
        for line in ("export COCO_DISPOSABLE_TEST=1", "export TRUSTEE_PROFILE=Permissive", f"export HWIDS={HWID}",
                     "export VCEK_SECRET_NAME=vcek-snp-aaaaaaaaaaaaaaaa-fixture", "export PROOF_NODE=node-a",
                     f"export VCEK_BUNDLE={bundle}", f"export MIRROR_CA={self.state / 'mirror-ca.pem'}",
                     f"export RUNG_SIGNED_IMAGE={SIGNED['digest_ref']}", f"export RUNG_SIGNED_UNSIGNED_IMAGE={SIGNED['unsigned_digest_ref']}"):
            self.assertIn(line + "\n", env)
        self.assertIn("Then run the capability tests: make test-rung WHICH=all", out)

    def prepared(self):
        """A whole run, so that a later step can start on its outputs."""
        code, out, err = self.run_lab()
        self.assertEqual(0, code, out + err)
        for path in self.fake.iterdir():
            if path.name == "calls" or path.name.startswith(("helper-script-", "shipped")):
                path.unlink()

    def test_signed_images_are_built_on_the_helper_and_only_the_results_come_back(self):
        code, out, err = self.run_lab()
        self.assertEqual(0, code, out + err)
        install, build = (self.fake / "helper-script-0").read_text(), (self.fake / "helper-script-1").read_text()
        cosign = json.loads((ROOT / "install/release-manifest.json").read_text())["tools"]["cosign"]
        self.assertIn(f"want={cosign['sha256']}", install)
        self.assertIn(cosign["url"], install)
        self.assertIn("sha256sum -c --quiet", install)
        # sudo's PATH leaves out /usr/local/bin, where cosign goes.
        self.assertIn('export PATH="/usr/local/bin:$PATH"', build)
        self.assertIn("export RUNG_SIGNED_IMAGE=mirror.rig.local:8443/coco/rung-b:signed", build)
        self.assertIn("export SSL_CERT_FILE=/opt/mirror/ca/rootCA.pem", build)
        self.assertIn("--password-stdin mirror.rig.local:8443 < /opt/mirror/mirror-admin-password", build)
        self.assertIn('bash "$W/repo/scripts/build-rung-images.sh" sign-rung-signed-only < /dev/null', build)
        # A new key pair gets a generated password, kept with it for later runs.
        password = (self.state / "rung-image-artifacts/cosign-password").read_text().strip()
        self.assertGreaterEqual(len(password), 24)
        self.assertIn(f"export COSIGN_PASSWORD={password}", build)
        with tarfile.open(self.fake / "shipped.tgz") as tar:
            names = tar.getnames()
        self.assertIn("repo/scripts/collect-vcek.sh", names)
        self.assertIn("repo/install/release-manifest.json", names)
        self.assertFalse(any("__pycache__" in n or n.startswith("artifacts/") for n in names), names)
        ssh = [c[1] for c in self.calls() if isinstance(c, list) and c[0] == "ssh"]
        self.assertEqual("sudo rm -rf /var/tmp/coco-signed-images", ssh[-1])  # The helper keeps no key.
        artifacts = self.state / "rung-image-artifacts"
        manifest = json.loads((artifacts / "rung-signed-manifest.json").read_text())
        self.assertEqual(str(artifacts / "cosign.pub"), manifest["rung_signed"]["cosign_pub"])
        self.assertEqual(0o600, stat.S_IMODE((artifacts / "cosign.key").stat().st_mode))
        self.assertIn(f"export RUNG_IMAGE_MANIFEST={artifacts / 'rung-signed-manifest.json'}\n", (artifacts / "rung-signed.env").read_text())

        # A second run sends the existing key pair and reuses its password.
        (self.fake / "helper-script-0").unlink()
        (self.fake / "helper-script-1").unlink()
        (self.fake / "calls").unlink()
        code, out, err = self.run_lab("--from", "images")
        self.assertEqual([], self.text_calls("collect-vcek"))
        self.assertEqual(0, code, out + err)
        with tarfile.open(self.fake / "shipped.tgz") as tar:
            self.assertIn("artifacts/cosign.key", tar.getnames())
        self.assertIn(f"export COSIGN_PASSWORD={password}", (self.fake / "helper-script-1").read_text())

    def test_a_key_from_an_earlier_build_needs_its_password(self):
        self.prepared()
        (self.state / "rung-image-artifacts/cosign-password").unlink()  # As after an earlier manual build.
        code, out, err = self.run_lab("--from", "images")
        self.assertEqual(1, code)
        self.assertIn("set COSIGN_PASSWORD to its password", err)
        self.assertFalse((self.fake / "shipped.tgz").exists())
        code, out, err = self.run_lab("--from", "images", COSIGN_PASSWORD="chosen-earlier")
        self.assertEqual(0, code, out + err)
        self.assertIn("export COSIGN_PASSWORD=chosen-earlier", (self.fake / "helper-script-1").read_text())

    def test_references_wait_for_one_approval(self):
        self.prepared()
        reviewed = self.state / "rvps-reviewed.yaml"
        code, out, err = self.run_lab("--from", "references", APPROVE_REFERENCES="")
        self.assertEqual(1, code)
        self.assertIn("without a terminal, set APPROVE_REFERENCES=1", err)
        self.assertFalse(reviewed.exists())
        self.assertEqual([], self.text_calls("apply-trustee"))

        class Terminal(io.StringIO):
            def isatty(self):
                return True

        code, out, err = self.run_lab("--from", "references", stdin=Terminal("no\n"), APPROVE_REFERENCES="")
        self.assertEqual(1, code)
        self.assertIn("reference values not approved; nothing was published", err)
        self.assertFalse(reviewed.exists())
        code, out, err = self.run_lab("--from", "references", stdin=Terminal("yes\n"), APPROVE_REFERENCES="")
        self.assertEqual(0, code, out + err)
        self.assertIn("snp_launch_measurement", out)
        self.assertEqual(1, len(self.text_calls("apply-trustee configure")))

    def test_only_this_nodes_certificate_is_used(self):
        code, out, err = self.run_lab(FAKE_HWIDS=f"{HWID} {'b' * 128}")
        self.assertEqual(1, code)
        self.assertIn("holds 2 downloaded certificates for this node, not one", err)
        self.assertEqual([], self.text_calls("collect-vcek --seed"))
        code, out, err = self.run_lab(FAKE_HWIDS="")
        self.assertEqual(1, code)
        self.assertIn("kdsintf.amd.com", err)

    def test_a_later_step_needs_the_earlier_ones_output(self):
        code, out, err = self.run_lab("--from", "veritas")
        self.assertEqual(1, code)
        self.assertIn("guest-cmdline.txt is missing; run make trustee-lab FROM=cmdline", err)
        self.assertEqual([], self.text_calls("veritas"))

    def test_refuses_outside_the_lab_before_any_call(self):
        for env in ({"TRUSTEE_LAB": ""}, {"TRUSTEE_CONTEXT": "other"}):
            with self.subTest(env=env):
                code, out, err = self.run_lab(**env)
                self.assertEqual(1, code)
                self.assertEqual([], self.calls())


if __name__ == "__main__":
    unittest.main()
