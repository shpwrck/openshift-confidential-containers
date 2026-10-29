#!/usr/bin/env python3
"""Set up Trustee on the disposable lab in one command (make trustee-lab).

It runs the lab sequence of docs/trustee.md, in these steps:

  vcek        collect this node's VCEK certificate and publish it to Trustee
  bootstrap   create the TrusteeConfig and mark the lab namespaces as disposable
  mirror      copy the mirror registry's CA and password from the helper
  initdata    write the test workloads' initdata
  cmdline     read the guest kernel command line from a throwaway kata-cc pod
  veritas     calculate the launch reference with Veritas (podman, on the controller)
  references  build the reviewed reference set and ask you to approve it
  images      build and sign the test images on the helper
  configure   publish the resource policy, the references and the lab resources

Only `references` asks anything; APPROVE_REFERENCES=1 approves ahead. Then it
writes $COCO_STATE_DIR/trustee-lab.env with the capability tests' settings, which
`source scripts/env.sh` loads. After a failure, fix the cause and start again at
the failed step with `make trustee-lab FROM=<step>`.
"""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import shutil
import subprocess
import sys
import tarfile
import time
import urllib.request

import yaml  # From the controller requirements.

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from lab_access import HELPER_KEYS, Stop, helper_destination, load_rig, ssh_options, state_dir, write_private  # noqa: E402

REPO = Path(__file__).resolve().parent.parent
WORKLOAD_NS = "coco-validation"
TRUSTEE_NS = "trustee-operator-system"
DISPOSABLE = "coco.openshift.io/disposable"
KBS_RESOURCES = ("regcred attestation-cert attestation-status sample credential security-policy "
                 "registry-configuration sig-public-key")
PROBE_POD = "cmdline-probe"
# Prints the -append argument of every QEMU process on the node: the guest kernel command line.
CMDLINE_SCRIPT = ('for p in $(pgrep -f qemu); do tr "\\0" "\\n" < /proc/$p/cmdline'
                  ' | grep -A1 -x -- -append | tail -n 1; done')
# Where the helper builds the signed images; removed afterwards, signing key included.
HELPER_BUILD = "/var/tmp/coco-signed-images"
STEPS = ("vcek", "bootstrap", "mirror", "initdata", "cmdline", "veritas", "references", "images", "configure")
HWID = re.compile(r"^[0-9a-f]{128}$")


class Lab:
    def __init__(self, environ):
        if environ.get("TRUSTEE_LAB") != "1":
            raise Stop("trustee-lab is only for the disposable lab: run make connect, then source scripts/env.sh "
                       "(it sets TRUSTEE_LAB=1)")
        context = environ.get("WORKER_CONTEXT", "")
        if not context or environ.get("TRUSTEE_CONTEXT") != context:
            raise Stop("trustee-lab needs identical WORKER_CONTEXT and TRUSTEE_CONTEXT, as lab.env sets them")
        self.context = context
        self.state = state_dir()
        self.rig = load_rig(self.state, (*HELPER_KEYS, "node_server_id"))
        self.helper = helper_destination(self.rig)
        self.bom = json.loads(Path(environ.get("RELEASE_MANIFEST") or REPO / "install/release-manifest.json").read_text())
        defaults = yaml.safe_load((REPO / "ansible/group_vars/all.yml").read_text())
        self.mirror_root = self.rig.get("mirror_root") or defaults["mirror_root"]
        self.mirror_user = self.rig.get("mirror_user") or defaults["mirror_user"]
        self.registry = environ.get("ARTIFACTORY_REGISTRY") or environ.get("MIRROR_REGISTRY") or "mirror.rig.local:8443"
        # One bundle per node, so a certificate from an earlier rig is never published.
        self.bundle = self.state / f"vcek-bundle-{self.rig['node_server_id']}"
        self.artifacts = Path(environ.get("ARTIFACT_DIR") or self.state / "rung-image-artifacts")
        self.files = {name: self.state / name for name in (
            "mirror-ca.pem", "mirror-password", "initdata.toml", "guest-cmdline.txt", "rvps-generated.yaml",
            "rvps-reviewed.yaml", "resource-policy.rego", "trustee-lab.env")}
        self.env = dict(environ, TRUSTEE_PROFILE="Permissive", TRUSTEE_LAB="1", TEE="snp",
                        TRUSTEE_CONTEXT=context, VCEK_BUNDLE=str(self.bundle), TRUSTEE_NS=TRUSTEE_NS,
                        MIRROR_CA=str(self.files["mirror-ca.pem"]),
                        MIRROR_PASSWORD_FILE=str(self.files["mirror-password"]))
        self._node = None

    # ---- helpers ---------------------------------------------------------
    def run(self, command, what, input=None, capture=False, **env):
        """Run a command with the lab settings; stop with `what` when it fails."""
        sys.stdout.flush()  # Keeps this script's lines ahead of the command's output in a piped log.
        result = subprocess.run(command, cwd=REPO, env={**self.env, **env}, input=input,
                                stdout=subprocess.PIPE if capture else None)
        if result.returncode != 0:
            raise Stop(f"{what} failed (exit {result.returncode}); the output above says why")
        return result.stdout

    def oc(self, *args, input=None, check=True):
        result = subprocess.run(["oc", f"--context={self.context}", "--request-timeout=60s", *args], input=input,
                                capture_output=True, env=self.env)
        if check and result.returncode != 0:
            raise Stop(f"oc {' '.join(args[:3])} failed: {result.stderr.decode(errors='replace').strip()}")
        return result

    def ssh(self, command, what, input=None):
        result = subprocess.run([*ssh_options(self.rig), self.helper, command], input=input, capture_output=True)
        if result.returncode != 0:
            raise Stop(f"{what} on the helper {self.helper} failed: {result.stderr.decode(errors='replace').strip()}")
        return result.stdout

    def node(self):
        if self._node is None:
            nodes = json.loads(self.oc("get", "nodes", "-o", "json").stdout)["items"]
            if len(nodes) != 1:
                raise Stop(f"the lab is a single-node cluster, but {len(nodes)} nodes are listed")
            self._node = nodes[0]["metadata"]["name"]
        return self._node

    def hwids(self):
        """Chip IDs in this node's bundle that have a downloaded certificate."""
        if not self.bundle.is_dir():
            return []
        return sorted(p.name for p in self.bundle.iterdir() if HWID.match(p.name) and (p / "vcek.der").is_file())

    def hwid(self):
        found = self.hwids()
        if len(found) != 1:
            raise Stop(f"{self.bundle} holds {len(found)} certificates; it must hold exactly this node's one. "
                       "Run make trustee-lab FROM=vcek")
        return found[0]

    def need(self, path, step):
        if not path.is_file() or path.stat().st_size == 0:
            raise Stop(f"{path} is missing; run make trustee-lab FROM={step}")
        return path

    def render(self, **env):
        return self.run([sys.executable, "scripts/render-workload.py", "kbs"], "rendering the test workload",
                        capture=True, NS=WORKLOAD_NS, **env)

    # ---- steps -----------------------------------------------------------
    def vcek(self):
        self.run(["bash", "scripts/collect-vcek.sh", self.node()], "collecting the VCEK")
        found = self.hwids()
        if len(found) != 1:
            raise Stop(f"{self.bundle} holds {len(found)} downloaded certificates for this node, not one. The "
                       "controller must reach kdsintf.amd.com to download it; see docs/trustee.md")
        self.run(["bash", "scripts/collect-vcek.sh", "--seed"], "publishing the VCEK", NS=TRUSTEE_NS)

    def bootstrap(self):
        self.run([sys.executable, "scripts/verify-release.py", "--require-resolved", "--tee", "snp"], "the release check")
        self.run(["bash", "scripts/apply-trustee.sh", "bootstrap"], "the Trustee bootstrap", NS=TRUSTEE_NS,
                 HWIDS=self.hwid(), SHOW_NEXT="0")
        if self.oc("get", "namespace", WORKLOAD_NS, "--ignore-not-found", "-o", "name").stdout.strip() == b"":
            self.oc("create", "namespace", WORKLOAD_NS)
        # The capability tests and make reset-lab act only on namespaces carrying this label.
        for ns in (WORKLOAD_NS, TRUSTEE_NS):
            self.oc("label", "namespace", ns, f"{DISPOSABLE}=true", "--overwrite")
        print(f"Marked {WORKLOAD_NS} and {TRUSTEE_NS} with {DISPOSABLE}=true.")

    def mirror(self):
        ca = self.ssh(f"sudo cat {shlex.quote(self.mirror_root + '/ca/rootCA.pem')}", "reading the mirror CA")
        if b"-----BEGIN CERTIFICATE-----" not in ca:
            raise Stop("the helper's mirror CA is not a PEM certificate")
        password = self.ssh(f"sudo cat {shlex.quote(self.mirror_root + '/mirror-admin-password')}",
                            "reading the mirror password")
        if not password.strip():
            raise Stop("the helper's mirror password file is empty")
        write_private(self.files["mirror-ca.pem"], ca)
        write_private(self.files["mirror-password"], password)
        print(f"Wrote {self.files['mirror-ca.pem']} and {self.files['mirror-password']}.")

    def initdata(self):
        self.need(self.files["mirror-ca.pem"], "mirror")
        write_private(self.files["initdata.toml"], self.render(EMIT_INITDATA="1"))
        print(f"Wrote {self.files['initdata.toml']}.")

    def cmdline(self):
        self.need(self.files["mirror-ca.pem"], "mirror")
        self.oc("-n", WORKLOAD_NS, "delete", "pod", PROBE_POD, "--ignore-not-found", "--wait=true", "--timeout=5m")
        self.oc("create", "-f", "-", input=self.render(RENDER_ONLY="1", POD_NAME=PROBE_POD))
        print("Started a throwaway kata-cc pod to read the guest kernel command line. It never attests;")
        print("its VM only has to start, which takes about a minute.")
        deadline = time.monotonic() + int(self.env.get("CMDLINE_TIMEOUT", "600"))
        try:
            while True:
                probe = self.oc("debug", f"node/{self.node()}", "--", "chroot", "/host", "sh", "-c", CMDLINE_SCRIPT,
                                check=False)
                lines = sorted({line.strip() for line in probe.stdout.decode(errors="replace").splitlines()
                                if line.strip()})
                if len(lines) == 1:
                    break
                if len(lines) > 1:
                    raise Stop(f"{len(lines)} confidential VMs run on the node; delete the other kata-cc pods "
                               "and run make trustee-lab FROM=cmdline")
                if time.monotonic() > deadline:
                    raise Stop("the probe pod's VM did not start; check it with "
                               f"oc -n {WORKLOAD_NS} describe pod {PROBE_POD}")
                print("  Waiting for the VM to start...")
                time.sleep(15)
        finally:
            self.oc("-n", WORKLOAD_NS, "delete", "pod", PROBE_POD, "--ignore-not-found", "--wait=false", check=False)
        write_private(self.files["guest-cmdline.txt"], lines[0] + "\n")
        print(f"Guest kernel command line:\n  {lines[0]}\nWrote {self.files['guest-cmdline.txt']}.")

    def veritas(self):
        if shutil.which("podman") is None:
            raise Stop("Veritas runs in podman on the controller; install podman and run make trustee-lab FROM=veritas")
        pull_secret = Path(os.path.expanduser(self.env.get("PULL_SECRET") or self.rig.get("pull_secret_src") or ""))
        if not pull_secret.is_file():
            raise Stop(f"no pull secret at '{pull_secret}'; set pull_secret_src in the rig file or PULL_SECRET")
        image = self.bom["images"]["cocoTools"]["ref"]
        self.run(["podman", "pull", "--authfile", str(pull_secret), image], "pulling the Veritas image")
        cmdline = self.need(self.files["guest-cmdline.txt"], "cmdline").read_text().strip()
        self.run(["bash", "scripts/gen-rvps-veritas.sh"], "Veritas", NODE="", PULL_SECRET=str(pull_secret),
                 INITDATA=str(self.need(self.files["initdata.toml"], "initdata")),
                 OUT=str(self.files["rvps-generated.yaml"]), VERITAS_KERNEL_CMDLINE=cmdline)

    def references(self):
        reviewed = self.files["rvps-reviewed.yaml"]
        self.run([sys.executable, "scripts/review-references.py",
                  str(self.need(self.files["rvps-generated.yaml"], "veritas")), str(reviewed), "--drop", "init_data"],
                 "building the reference set", HWIDS=self.hwid(), SHOW_NEXT="0")
        print()
        print("Trustee releases secrets only to guests that match these values. snp_launch_measurement is")
        print("the one Veritas calculated for this release and initdata; the four firmware levels are the")
        print("ones in this node's VCEK request. Approve them only for this node.")
        if self.env.get("APPROVE_REFERENCES") == "1":
            print("Approved ahead with APPROVE_REFERENCES=1.")
        else:
            if not sys.stdin.isatty():
                reviewed.unlink()
                raise Stop("without a terminal, set APPROVE_REFERENCES=1 to approve the reference values")
            if input("Type yes to approve these reference values: ").strip() != "yes":
                reviewed.unlink()
                raise Stop("reference values not approved; nothing was published")

    def images(self):
        cosign = self.bom["tools"]["cosign"]
        password_file = self.artifacts / "cosign-password"
        key = self.artifacts / "cosign.key"
        self.artifacts.mkdir(parents=True, exist_ok=True, mode=0o700)
        if self.env.get("COSIGN_PASSWORD"):
            password = self.env["COSIGN_PASSWORD"]
        elif password_file.is_file():
            password = password_file.read_text().strip()
        elif key.exists():
            if not sys.stdin.isatty():
                raise Stop(f"{key} is from an earlier build; set COSIGN_PASSWORD to its password")
            import getpass
            password = getpass.getpass(f"Password of the signing key in {self.artifacts}: ")
        else:
            # A new key pair: its password stays in the state directory, so later runs need no answer.
            password = secrets.token_urlsafe(24)
            write_private(password_file, password + "\n")
        print(f"Installing skopeo and cosign {cosign['version']} on the helper, which reaches the mirror by name.")
        self.ssh("sudo bash -s", "installing the image tools", input=f'''set -euo pipefail
command -v skopeo >/dev/null || dnf -y -q install skopeo
command -v jq >/dev/null || dnf -y -q install jq
want={shlex.quote(cosign["sha256"])}
if ! printf '%s  %s\\n' "$want" /usr/local/bin/cosign | sha256sum -c --status 2>/dev/null; then
  tmp="$(mktemp)"
  curl -fsSL --retry 3 -o "$tmp" {shlex.quote(cosign["url"])}
  printf '%s  %s\\n' "$want" "$tmp" | sha256sum -c --quiet
  install -m 0755 "$tmp" /usr/local/bin/cosign
  rm -f "$tmp"
fi
'''.encode())
        # The scripts and, when there is one, the existing key pair.
        bundle = io.BytesIO()
        with tarfile.open(fileobj=bundle, mode="w:gz") as tar:
            for path in ("scripts", "install/release-manifest.json"):
                tar.add(REPO / path, arcname=f"repo/{path}", filter=lambda t: None if "__pycache__" in t.name else t)
            for name in ("cosign.key", "cosign.pub"):
                if (self.artifacts / name).is_file():
                    tar.add(self.artifacts / name, arcname=f"artifacts/{name}")
        work = shlex.quote(HELPER_BUILD)
        root = self.mirror_root
        try:
            self.ssh(f"sudo bash -c 'rm -rf {work} && mkdir -m 0700 {work} && tar -C {work} -xzf -'",
                     "copying the build scripts", input=bundle.getvalue())
            print(f"Building and signing the test images on the helper (in {HELPER_BUILD}).")
            build = subprocess.run([*ssh_options(self.rig), self.helper, "sudo bash -s"], input=f'''set -euo pipefail
umask 077
W={work}
export PATH="/usr/local/bin:$PATH"
export ARTIFACT_DIR="$W/artifacts" COCO_STATE_DIR="$W/state" REGISTRY_AUTH_FILE="$W/auth.json" DOCKER_CONFIG="$W/docker"
export SSL_CERT_FILE={shlex.quote(root + "/ca/rootCA.pem")}
export MIRROR_REGISTRY={shlex.quote(self.registry)} ARTIFACTORY_REGISTRY={shlex.quote(self.registry)}
export RUNG_SIGNED_IMAGE={shlex.quote(self.registry + "/coco/rung-b:signed")}
export RUNG_SIGNED_UNSIGNED_IMAGE={shlex.quote(self.registry + "/coco/rung-b-unsigned:unsigned")}
export COSIGN_PASSWORD={shlex.quote(password)}
mkdir -p "$ARTIFACT_DIR" "$COCO_STATE_DIR" "$DOCKER_CONFIG"
skopeo login --authfile "$REGISTRY_AUTH_FILE" -u {shlex.quote(self.mirror_user)} --password-stdin {shlex.quote(self.registry)} < {shlex.quote(root + "/mirror-admin-password")}
cosign login -u {shlex.quote(self.mirror_user)} --password-stdin {shlex.quote(self.registry)} < {shlex.quote(root + "/mirror-admin-password")}
bash "$W/repo/scripts/build-rung-images.sh" sign-rung-signed-only < /dev/null
'''.encode())
            if build.returncode != 0:
                raise Stop(f"building the signed images on the helper failed (exit {build.returncode}); "
                           "the output above says why")
            back = self.ssh(f"sudo tar -C {work}/artifacts -cf - cosign.key cosign.pub rung-signed-manifest.json",
                            "copying the signing results back")
        finally:
            subprocess.run([*ssh_options(self.rig), self.helper, f"sudo rm -rf {work}"], capture_output=True)
        with tarfile.open(fileobj=io.BytesIO(back)) as tar:
            for member in tar.getmembers():
                write_private(self.artifacts / Path(member.name).name, tar.extractfile(member).read())
        manifest_path = self.artifacts / "rung-signed-manifest.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["rung_signed"]["cosign_pub"] = str(self.artifacts / "cosign.pub")
        write_private(manifest_path, json.dumps(manifest) + "\n")
        signed = manifest["rung_signed"]
        write_private(self.artifacts / "rung-signed.env", "".join(f"export {k}={shlex.quote(v)}\n" for k, v in (
            ("RUNG_SIGNED_IMAGE", signed["digest_ref"]), ("RUNG_SIGNED_UNSIGNED_IMAGE", signed["unsigned_digest_ref"]),
            ("RUNG_SIGNED_COSIGN_PUB", signed["cosign_pub"]), ("RUNG_IMAGE_MANIFEST", str(manifest_path)))))
        print(f"Signed {signed['digest_ref']}; the unsigned control is {signed['unsigned_digest_ref']}.")
        print(f"Wrote {self.artifacts / 'rung-signed.env'}; the signing key stays in {self.artifacts}.")

    def signed_env(self):
        manifest = json.loads(self.need(self.artifacts / "rung-signed-manifest.json", "images").read_text())["rung_signed"]
        return {"RUNG_SIGNED_IMAGE": manifest["digest_ref"], "RUNG_SIGNED_UNSIGNED_IMAGE": manifest["unsigned_digest_ref"],
                "RUNG_SIGNED_COSIGN_PUB": manifest["cosign_pub"],
                "RUNG_IMAGE_MANIFEST": str(self.artifacts / "rung-signed-manifest.json")}

    def configure(self):
        pin = self.bom["tools"]["trusteeResourcePolicy"]
        policy = self.files["resource-policy.rego"]
        if not policy.is_file() or hashlib.sha256(policy.read_bytes()).hexdigest() != pin["sha256"]:
            # The Operator's own Permissive policy enforces no appraisal; this one does.
            with urllib.request.urlopen(pin["url"], timeout=60) as response:
                data = response.read()
            if hashlib.sha256(data).hexdigest() != pin["sha256"]:
                raise Stop(f"{pin['url']} does not match the SHA-256 in the release manifest")
            write_private(policy, data)
        self.run(["bash", "scripts/apply-trustee.sh", "configure"], "the Trustee configure", NS=TRUSTEE_NS,
                 HWIDS=self.hwid(), TRUSTEE_RESOURCE_POLICY_FILE=str(policy),
                 TRUSTEE_RVPS_FILE=str(self.need(self.files["rvps-reviewed.yaml"], "references")),
                 KBS_RESOURCE_NAMES=KBS_RESOURCES, **self.signed_env())

    def write_env(self):
        hwid = self.hwid()
        mounts = json.loads(self.run([sys.executable, "scripts/lib/trustee_config.py", "mounts", "--hwids", hwid],
                                     "naming the VCEK Secret", capture=True))
        values = {"TRUSTEE_PROFILE": "Permissive", "TEE": "snp", "COCO_DISPOSABLE_TEST": "1",
                  "VCEK_BUNDLE": str(self.bundle), "HWIDS": hwid, "VCEK_SECRET_NAME": mounts[0]["secretName"],
                  "PROOF_NODE": self.node(), "MIRROR_CA": self.env["MIRROR_CA"],
                  "MIRROR_PASSWORD_FILE": self.env["MIRROR_PASSWORD_FILE"], **self.signed_env()}
        write_private(self.files["trustee-lab.env"],
                      "# Written by make trustee-lab; source scripts/env.sh loads it after lab.env.\n"
                      + "".join(f"export {k}={shlex.quote(v)}\n" for k, v in values.items()))
        print(f"Wrote {self.files['trustee-lab.env']}.")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--from", dest="start", choices=STEPS, default=STEPS[0], help="the step to start at")
    args = parser.parse_args(argv)
    lab = Lab(os.environ)
    todo = STEPS[STEPS.index(args.start):]
    for number, step in enumerate(todo, STEPS.index(args.start) + 1):
        print(f"\n== {number}/{len(STEPS)} {step}: {DESCRIPTIONS[step]} ==", flush=True)
        getattr(lab, step)()
    lab.write_env()
    print("\nTrustee is set up. In this terminal, run: source scripts/env.sh")
    print("Then run the capability tests: make test-rung WHICH=all")
    return 0


DESCRIPTIONS = {
    "vcek": "collecting this node's VCEK certificate",
    "bootstrap": "creating the TrusteeConfig",
    "mirror": "copying the mirror CA and password from the helper",
    "initdata": "writing the test workloads' initdata",
    "cmdline": "reading the guest kernel command line",
    "veritas": "calculating the launch reference with Veritas",
    "references": "building the reference set for your approval",
    "images": "building and signing the test images on the helper",
    "configure": "publishing the resource policy, references and lab resources",
}


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Stop as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)
