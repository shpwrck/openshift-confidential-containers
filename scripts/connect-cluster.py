#!/usr/bin/env python3
"""Connect the controller to the rig's cluster (make connect).

The cluster API is only reachable on the private VLAN. This copies the
installer's kubeconfig from the helper to $COCO_STATE_DIR/kubeconfig, points it
at an SSH tunnel through the helper (127.0.0.1, with the API's own name for
TLS, so no /etc/hosts line is needed), names its context `validation`, opens the
tunnel when it is not already open, and writes $COCO_STATE_DIR/lab.env, which
`source scripts/env.sh` loads in every terminal. Then it checks the cluster,
waiting while a new install settles. Run it again whenever the tunnel is gone.
"""
import os
from pathlib import Path
import shlex
import socket
import subprocess
import sys
import time

import yaml  # From the controller requirements.

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from lab_access import HELPER_KEYS, Stop, helper_destination, load_rig, ssh_options, state_dir, write_private  # noqa: E402

REPO = Path(__file__).resolve().parent.parent
CONTEXT = "validation"
KUBECONFIG_ON_HELPER = "/opt/install/cluster-assets/auth/kubeconfig"


def cluster_names(rig):
    """The API name the installer used: rig-file overrides, else the Ansible defaults."""
    defaults = yaml.safe_load((REPO / "ansible/group_vars/all.yml").read_text())
    cluster = rig.get("cluster_name") or defaults["cluster_name"]
    domain = rig.get("base_domain") or defaults["base_domain"]
    return f"api.{cluster}.{domain}"


def point_at_tunnel(kubeconfig, api_name, port):
    """The installer's kubeconfig, aimed at the local tunnel with one named context."""
    config = yaml.safe_load(kubeconfig)
    contexts = config.get("contexts") or []
    if len(contexts) != 1 or len(config.get("clusters") or []) != 1:
        raise Stop("the helper's kubeconfig does not hold exactly one cluster and context")
    cluster = config["clusters"][0]["cluster"]
    cluster["server"] = f"https://127.0.0.1:{port}"
    cluster["tls-server-name"] = api_name
    contexts[0]["name"] = CONTEXT
    config["current-context"] = CONTEXT
    return yaml.safe_dump(config, sort_keys=False)


def lab_env(kubeconfig):
    return ("# Written by make connect; source scripts/env.sh loads it in every terminal.\n"
            f"export KUBECONFIG={shlex.quote(str(kubeconfig))}\n"
            f"export WORKER_CONTEXT={CONTEXT} TRUSTEE_CONTEXT={CONTEXT}\n"
            "export TRUSTEE_LAB=1 INSTALL_TOPOLOGY=sno\n")


def main():
    state = state_dir()
    rig = load_rig(state, (*HELPER_KEYS, "node_vlan_ip"))
    port = int(os.environ.get("API_PORT", "6443"))
    helper = helper_destination(rig)
    ssh = ssh_options(rig)
    kubeconfig = state / "kubeconfig"
    env = dict(os.environ, KUBECONFIG=str(kubeconfig), WORKER_CONTEXT=CONTEXT, TRUSTEE_CONTEXT=CONTEXT,
               TRUSTEE_LAB="1", INSTALL_TOPOLOGY="sno")

    copied = subprocess.run([*ssh, helper, f"sudo cat {KUBECONFIG_ON_HELPER}"], capture_output=True, text=True)
    if copied.returncode != 0:
        raise Stop(f"could not read {KUBECONFIG_ON_HELPER} on the helper {helper}: {copied.stderr.strip()}")
    write_private(kubeconfig, point_at_tunnel(copied.stdout, cluster_names(rig), port))
    print(f"Wrote {kubeconfig}, context {CONTEXT}.")

    def api_answers():
        return subprocess.run(["oc", f"--context={CONTEXT}", "--request-timeout=10s", "get", "--raw", "/readyz"],
                              env=env, capture_output=True).returncode == 0

    if api_answers():
        print(f"The tunnel on 127.0.0.1:{port} is already open.")
    else:
        with socket.socket() as probe:
            in_use = probe.connect_ex(("127.0.0.1", port)) == 0
        if in_use:
            raise Stop(f"something else listens on 127.0.0.1:{port}, perhaps the tunnel of an earlier rig "
                       f"(pgrep -af '^ssh .*-L 127.0.0.1:{port}' finds it). Stop it, or set API_PORT to a free "
                       "port, and run make connect again")
        tunnel = subprocess.run([*ssh, "-f", "-N", "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=30",
                                 "-L", f"127.0.0.1:{port}:{rig['node_vlan_ip']}:6443", helper],
                                capture_output=True, text=True)
        if tunnel.returncode != 0:
            raise Stop(f"could not open the tunnel through {helper}: {tunnel.stderr.strip()}")
        for _ in range(12):
            if api_answers():
                break
            time.sleep(5)
        else:
            raise Stop(f"the tunnel is open, but the API at {rig['node_vlan_ip']}:6443 does not answer")
        print(f"Opened the tunnel 127.0.0.1:{port} -> {rig['node_vlan_ip']}:6443 through {helper}. "
              "It keeps running after this terminal closes.")
    write_private(state / "lab.env", lab_env(kubeconfig))
    # Flushed so that, piped into a log, these lines still come before the output of oc and the baseline.
    print(f"Wrote {state / 'lab.env'}.\n", flush=True)
    subprocess.run(["oc", f"--context={CONTEXT}", "get", "nodes"], env=env, check=False)
    print("\nChecking the cluster; a new install takes a few minutes to settle.", flush=True)
    baseline = subprocess.run(["bash", str(REPO / "scripts/validate-sno-baseline.sh")],
                              env=dict(env, BASELINE_WAIT=os.environ.get("BASELINE_WAIT", "900")))
    if baseline.returncode != 0:
        return baseline.returncode
    print("\nConnected. In this terminal, run: source scripts/env.sh")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Stop as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)
