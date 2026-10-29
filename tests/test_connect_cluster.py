"""make connect: the kubeconfig it writes, the tunnel it opens and the lab.env it leaves,
against a fake ssh and oc. No helper or cluster is contacted."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import yaml

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("connect_cluster", ROOT / "scripts/connect-cluster.py")
connect = importlib.util.module_from_spec(spec)
spec.loader.exec_module(connect)

# The installer's kubeconfig, as the helper holds it.
INSTALLER_KUBECONFIG = {
    "apiVersion": "v1", "kind": "Config",
    "clusters": [{"name": "sno-coco", "cluster": {"server": "https://api.sno-coco.coco.lab.local:6443",
                                                  "certificate-authority-data": "Zml4dHVyZQ=="}}],
    "contexts": [{"name": "admin", "context": {"cluster": "sno-coco", "user": "admin"}}],
    "current-context": "admin",
    "users": [{"name": "admin", "user": {"client-certificate-data": "Zml4dHVyZQ==", "client-key-data": "Zml4dHVyZQ=="}}],
}
# Logs each call; `-f -N` marks the tunnel open, and oc's /readyz answers once it is.
FAKE_SSH = r'''#!/usr/bin/env python3
import json, os, sys
log = os.path.join(os.environ["FAKE_DIR"], "calls")
with open(log, "a") as handle:
    handle.write(json.dumps(["ssh", *sys.argv[1:]]) + "\n")
if sys.argv[-1] == "sudo cat /opt/install/cluster-assets/auth/kubeconfig":
    sys.stdout.write(open(os.path.join(os.environ["FAKE_DIR"], "installer-kubeconfig")).read())
elif "-N" in sys.argv:
    open(os.path.join(os.environ["FAKE_DIR"], "tunnel-open"), "w").close()
else:
    sys.exit("unexpected ssh call")
'''
FAKE_OC = r'''#!/usr/bin/env python3
import json, os, sys
with open(os.path.join(os.environ["FAKE_DIR"], "calls"), "a") as handle:
    handle.write(json.dumps(["oc", *sys.argv[1:], "KUBECONFIG=" + os.environ.get("KUBECONFIG", "")]) + "\n")
if sys.argv[-2:] == ["--raw", "/readyz"]:
    sys.exit(0 if os.path.exists(os.path.join(os.environ["FAKE_DIR"], "tunnel-open")) else 1)
if sys.argv[-2:] == ["get", "nodes"]:
    print("NAME      STATUS   ROLES")
'''
FAKE_BASELINE = '''#!/usr/bin/env bash
echo "baseline BASELINE_WAIT=$BASELINE_WAIT WORKER_CONTEXT=$WORKER_CONTEXT KUBECONFIG=$KUBECONFIG" >> "$FAKE_DIR/calls"
echo "SNO baseline validation OK"
'''


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


class ConnectClusterTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.tmp = Path(temporary.name)
        self.state = self.tmp / "state"
        self.state.mkdir()
        self.fake = self.tmp / "fake"
        self.fake.mkdir()
        for name, text in (("ssh", FAKE_SSH), ("oc", FAKE_OC)):
            (self.fake / name).write_text(text)
            (self.fake / name).chmod(0o755)
        (self.fake / "installer-kubeconfig").write_text(yaml.safe_dump(INSTALLER_KUBECONFIG))
        # A copy of the repository parts the script reads, with a stand-in baseline.
        self.repo = self.tmp / "repo"
        (self.repo / "ansible/group_vars").mkdir(parents=True)
        shutil.copy(ROOT / "ansible/group_vars/all.yml", self.repo / "ansible/group_vars/all.yml")
        (self.repo / "scripts").mkdir()
        (self.repo / "scripts/validate-sno-baseline.sh").write_text(FAKE_BASELINE)
        self.rig = {"bastion_ssh_user": "root", "bastion_ansible_host": "203.0.113.10",
                    "bastion_ssh_key": str(self.tmp / "helper-key"), "private_link_known_hosts": str(self.tmp / "known_hosts"),
                    "node_vlan_ip": "10.0.0.7"}
        self.port = free_port()

    def run_connect(self, **env):
        (self.state / "rig.yml").write_text(yaml.safe_dump(self.rig))
        environment = {"PATH": f"{self.fake}:{os.environ['PATH']}", "COCO_STATE_DIR": str(self.state),
                       "FAKE_DIR": str(self.fake), "API_PORT": str(self.port), "HOME": str(self.tmp), **env}
        out, err = io.StringIO(), io.StringIO()
        with patch.dict(os.environ, environment, clear=True), patch.object(connect, "REPO", self.repo), \
                patch.object(connect.time, "sleep"), contextlib.redirect_stdout(out), contextlib.redirect_stderr(err), \
                self.child_output() as children:
            try:
                code = connect.main()
            except connect.Stop as error:
                code, err = 1, io.StringIO(str(error))
        return code, out.getvalue() + children.read_text(), err.getvalue()

    @contextlib.contextmanager
    def child_output(self):
        """Keep what oc and the baseline print to the terminal out of the test output."""
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
        return [json.loads(line) if line.startswith("[") else line.strip()
                for line in path.read_text().splitlines()] if path.exists() else []

    def test_first_connect_writes_the_kubeconfig_opens_the_tunnel_and_checks_the_cluster(self):
        code, out, err = self.run_connect()
        self.assertEqual(0, code, out + err)
        kubeconfig = self.state / "kubeconfig"
        self.assertEqual(0o600, stat.S_IMODE(kubeconfig.stat().st_mode))
        config = yaml.safe_load(kubeconfig.read_text())
        cluster = config["clusters"][0]["cluster"]
        self.assertEqual(f"https://127.0.0.1:{self.port}", cluster["server"])
        # The API's own name for TLS, so no /etc/hosts line is needed.
        self.assertEqual("api.sno-coco.coco.lab.local", cluster["tls-server-name"])
        self.assertEqual("Zml4dHVyZQ==", cluster["certificate-authority-data"])
        self.assertEqual(["validation"], [c["name"] for c in config["contexts"]])
        self.assertEqual("validation", config["current-context"])

        calls = self.calls()
        tunnels = [c for c in calls if isinstance(c, list) and "-N" in c]
        self.assertEqual(1, len(tunnels))
        tunnel = tunnels[0]
        self.assertIn(f"127.0.0.1:{self.port}:10.0.0.7:6443", tunnel)
        self.assertEqual("root@203.0.113.10", tunnel[-1])
        for option in ("StrictHostKeyChecking=yes", f"UserKnownHostsFile={self.tmp / 'known_hosts'}",
                       "ExitOnForwardFailure=yes", "BatchMode=yes"):
            self.assertIn(option, tunnel)
        self.assertEqual(str(self.tmp / "helper-key"), tunnel[tunnel.index("-i") + 1])
        oc_calls = [c for c in calls if isinstance(c, list) and c[0] == "oc"]
        self.assertTrue(all(c[1] == "--context=validation" for c in oc_calls), oc_calls)
        self.assertTrue(all(c[-1] == f"KUBECONFIG={kubeconfig}" for c in oc_calls), oc_calls)
        self.assertIn(f"baseline BASELINE_WAIT=900 WORKER_CONTEXT=validation KUBECONFIG={kubeconfig}", calls)

        lab_env = self.state / "lab.env"
        self.assertEqual(0o600, stat.S_IMODE(lab_env.stat().st_mode))
        text = lab_env.read_text()
        self.assertIn(f"export KUBECONFIG={kubeconfig}\n", text)
        self.assertIn("export WORKER_CONTEXT=validation TRUSTEE_CONTEXT=validation\n", text)
        self.assertIn("export TRUSTEE_LAB=1 INSTALL_TOPOLOGY=sno\n", text)
        self.assertIn("Opened the tunnel", out)
        self.assertIn("\nConnected. In this terminal, run: source scripts/env.sh\n", out)
        self.assertIn("SNO baseline validation OK", out)

    def test_piped_output_keeps_its_order(self):
        # A log or a remote session reads the output through a pipe, where Python buffers its own lines.
        shutil.copy(ROOT / "scripts/connect-cluster.py", self.repo / "scripts/connect-cluster.py")
        shutil.copytree(ROOT / "scripts/lib", self.repo / "scripts/lib", ignore=shutil.ignore_patterns("__pycache__"))
        (self.state / "rig.yml").write_text(yaml.safe_dump(self.rig))
        environment = {**os.environ, "PATH": f"{self.fake}:{os.environ['PATH']}", "COCO_STATE_DIR": str(self.state),
                       "FAKE_DIR": str(self.fake), "API_PORT": str(self.port), "HOME": str(self.tmp)}
        environment.pop("PYTHONUNBUFFERED", None)
        (self.fake / "tunnel-open").touch()
        result = subprocess.run([sys.executable, str(self.repo / "scripts/connect-cluster.py")], env=environment,
                                capture_output=True, text=True)
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        lines = [line for line in result.stdout.splitlines() if line]
        order = [next(i for i, line in enumerate(lines) if line.startswith(start))
                 for start in ("Wrote", "NAME", "Checking the cluster", "SNO baseline validation OK", "Connected.")]
        self.assertEqual(sorted(order), order, result.stdout)

    def test_an_open_tunnel_is_reused(self):
        (self.fake / "tunnel-open").touch()
        code, out, err = self.run_connect()
        self.assertEqual(0, code, out + err)
        self.assertIn("is already open", out)
        self.assertFalse(any(isinstance(c, list) and "-N" in c for c in self.calls()))

    def test_another_listener_on_the_port_stops_with_a_hint(self):
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", self.port))
            listener.listen()
            code, out, err = self.run_connect()
        self.assertEqual(1, code)
        self.assertIn(f"something else listens on 127.0.0.1:{self.port}", err)
        self.assertIn("API_PORT", err)
        self.assertFalse(any(isinstance(c, list) and "-N" in c for c in self.calls()))
        self.assertFalse((self.state / "lab.env").exists())

    def test_rig_names_and_missing_values(self):
        self.rig.update(cluster_name="lab2", base_domain="example.test")
        code, out, err = self.run_connect()
        self.assertEqual(0, code, out + err)
        config = yaml.safe_load((self.state / "kubeconfig").read_text())
        self.assertEqual("api.lab2.example.test", config["clusters"][0]["cluster"]["tls-server-name"])

        (self.fake / "calls").unlink()
        del self.rig["node_vlan_ip"], self.rig["bastion_ssh_key"]
        code, out, err = self.run_connect()
        self.assertEqual(1, code)
        self.assertIn("the rig file has no bastion_ssh_key, node_vlan_ip", err)
        self.assertEqual([], self.calls())

    def test_no_rig_file_points_to_env_and_order_rig(self):
        code, out, err = self.run_connect(COCO_STATE_DIR=str(self.tmp / "empty"))
        self.assertEqual(1, code)
        self.assertIn("source scripts/env.sh", err)
        self.assertEqual([], self.calls())


if __name__ == "__main__":
    unittest.main()
