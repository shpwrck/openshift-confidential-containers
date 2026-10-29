#!/usr/bin/env python3
"""Order a Cherry Servers test rig and write its rig file (make order-rig).

It asks its questions first: which tested plans, which project, which SSH key and
where the pull secret is. After you confirm the order it runs on its own: it
orders both servers with the Terraform in infra/cherry, pins their SSH host keys,
starts the helper's mirror bootstrap, checks the node's network and disks, waits
for the mirror and writes $COCO_STATE_DIR/rig.yml. Run it again after any
failure: it skips what is already done. `order-rig.py plans` only lists the
tested plans in stock.
"""
import argparse
from datetime import datetime, timezone
import getpass
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from cherry_rig import (RigError, disk_facts, matching_key_id, network_facts, parse_env_file,  # noqa: E402
                        render_rig_file, render_tfvars, rig_options)
import node_checks  # noqa: E402

REPO = Path(__file__).resolve().parent.parent
TERRAFORM_DIR = REPO / "infra/cherry"
TESTED = TERRAFORM_DIR / "tested-plans.json"
API = os.environ.get("CHERRY_API_BASE", "https://api.cherryservers.com/v1")
PULL_SECRET_PAGE = "https://console.redhat.com/openshift/install/pull-secret"
MIRROR_ROOT = "/opt/mirror"
STAGES = 7
SWITCH_ERRORS = ("not on the same private network", "report different private VLANs")
# The hostname defaults in infra/cherry/variables.tf, and the create timeout in main.tf.
HOSTNAMES = {"node": "sno-coco-node", "helper": "sno-coco-helper"}
DELIVERY_HOURS = 3
# Run on the node's original OS (Ubuntu ships python3); prints what the rig file needs.
OBSERVE_NODE = r'''
import json, os, socket, subprocess
def run(*argv):
    return json.loads(subprocess.check_output(argv))
try:
    block = run("lsblk", "-J", "-b", "-o", "NAME,PATH,TYPE,SIZE,SERIAL,MODEL,TRAN,MOUNTPOINTS")
except subprocess.CalledProcessError:
    block = run("lsblk", "-J", "-b", "-o", "NAME,PATH,TYPE,SIZE,SERIAL,MODEL,TRAN,MOUNTPOINT")
    def lift(device):
        device["mountpoints"] = [device.pop("mountpoint", None)]
        for child in device.get("children", []):
            lift(child)
    for device in block["blockdevices"]:
        lift(device)
links = "/dev/disk/by-path"
by_path = {n: os.path.realpath(os.path.join(links, n)) for n in os.listdir(links)} if os.path.isdir(links) else {}
print(json.dumps({"hostname": socket.gethostname(), "links": run("ip", "-j", "-d", "link", "show"),
                  "addresses": run("ip", "-j", "address", "show"), "block": block, "by_path": by_path}))
'''
HELPER_STATUS = f'''if [ -e {MIRROR_ROOT}/MIRROR_READY ]; then echo ready
elif systemctl is-active --quiet helper-bootstrap; then echo running
elif [ -e {MIRROR_ROOT}/MIRROR_FAILED ] || systemctl is-failed --quiet helper-bootstrap; then echo failed
else echo none; fi'''
HELPER_LOG = "tail -n 25 /var/log/mirror-bootstrap.log 2>/dev/null || journalctl -u helper-bootstrap --no-pager -n 25"


class Stop(Exception):
    """A step failed in a way the operator has to look at."""


def stage(number, title):
    print(f"\n== {number}/{STAGES} {title} ==\n", flush=True)


def ask(prompt, default=None, given=None, flag=None):
    """Read an answer, or take the one given on the command line (for runs without a terminal)."""
    if given is not None:
        print(f"{prompt}: {given}")
        return str(given)
    if not sys.stdin.isatty():
        raise Stop(f"no terminal to ask \"{prompt}\"" + (f"; pass {flag}" if flag else ""))
    suffix = f" [{default}]" if default not in (None, "") else ""
    answer = input(f"{prompt}{suffix}: ").strip()
    return answer or (default or "")


def confirm(prompt, default=True, given=None, flag=None):
    if given is not None:
        print(f"{prompt} {'yes' if given else 'no'}")
        return given
    answer = ask(prompt + (" [Y/n]" if default else " [y/N]"), flag=flag).lower()
    return default if not answer else answer in ("y", "yes")


def flag_answer(value):
    """A yes/no flag answers its question when set, and leaves it to the terminal otherwise."""
    return True if value else None


def state_dir():
    default = Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state"))) / "openshift-confidential-containers"
    path = Path(os.environ.get("COCO_STATE_DIR", str(default))).expanduser().resolve()
    if path == REPO or REPO in path.parents:
        raise Stop("COCO_STATE_DIR must be outside the checkout; it holds credentials")
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    return path


def write_private(path, text):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = path.with_name(f".{path.name}.tmp")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "w") as stream:
        stream.write(text)
    os.replace(temporary, path)


class Cherry:
    def __init__(self, key):
        self.key = key

    def get(self, path, auth=True):
        request = urllib.request.Request(API + path, headers={"Accept": "application/json"})
        if auth:
            if not self.key:
                raise Stop("no Cherry Servers API key: run `source scripts/env.sh` in this terminal first")
            request.add_header("Authorization", f"Bearer {self.key}")
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            raise Stop(f"Cherry Servers API {path}: HTTP {error.code}") from None
        except urllib.error.URLError as error:
            raise Stop(f"Cherry Servers API {path}: {error.reason}") from None


class Rig:
    """Paths and tools for one run, with Terraform and SSH pointed at COCO_STATE_DIR."""

    def __init__(self, state, cherry, args):
        self.state, self.cherry, self.args = state, cherry, args
        self.order_file = state / "rig-order.json"
        self.tfvars = state / "cherry.tfvars"
        self.tfplan = state / "cherry.tfplan"
        self.known_hosts = state / "known_hosts"
        self.rig_file = state / "rig.yml"
        self.pull_secret = state / "credentials/pull-secret.json"
        self.bootstrap = state / "helper-bootstrap.sh"
        self.env = dict(os.environ, CHERRY_API_KEY=cherry.key or "", TF_DATA_DIR=str(state / "terraform"),
                        TF_IN_AUTOMATION="1", CHECKPOINT_DISABLE="1")
        self.order = json.loads(self.order_file.read_text()) if self.order_file.is_file() else None

    # ---- Terraform ----------------------------------------------------------
    def terraform(self, *args, stream=False, check=True):
        argv = ["terraform", f"-chdir={TERRAFORM_DIR}", *args]
        if not stream:
            result = subprocess.run(argv, env=self.env, capture_output=True, text=True)
            output = result.stdout + result.stderr
        else:
            process = subprocess.Popen(argv, env=self.env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            lines = []
            for line in process.stdout:
                print(line, end="", flush=True)
                lines.append(line)
            result = subprocess.CompletedProcess(argv, process.wait())
            output = "".join(lines)
        if check and result.returncode not in (0,):
            if not stream:
                print(output, file=sys.stderr)
            raise Stop(f"terraform {args[0]} failed")
        return result.returncode, output

    def ordered(self):
        """Whether the Terraform state holds servers, even when their outputs failed a check."""
        code, output = self.terraform("state", "list", check=False)
        return code == 0 and "cherryservers_server." in output

    def rig_values(self):
        code, output = self.terraform("output", "-json", "rig_values", check=False)
        if code != 0:
            return None
        values = json.loads(output)
        return values if values.get("node_id") else None

    # ---- SSH ----------------------------------------------------------------
    def ssh_argv(self, host):
        return ["ssh", "-i", self.order["ssh_key"], "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
                "-o", "StrictHostKeyChecking=accept-new", "-o", f"UserKnownHostsFile={self.known_hosts}",
                "-o", "GlobalKnownHostsFile=/dev/null", "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=30",
                f"root@{host}"]

    def ssh(self, host, command, stdin=None, check=True, timeout=300):
        try:
            result = subprocess.run([*self.ssh_argv(host), command], input=stdin, capture_output=True, text=True,
                                    timeout=timeout)
        except subprocess.TimeoutExpired:
            raise Stop(f"SSH to {host} timed out") from None
        if check and result.returncode != 0:
            raise Stop(f"SSH to {host} failed: {result.stderr.strip() or result.stdout.strip()}")
        return result

    def wait_for_ssh(self, name, host, minutes=30):
        deadline, reported = time.monotonic() + minutes * 60, 0
        while True:
            result = self.ssh(host, "true", check=False, timeout=60)
            if result.returncode == 0:
                print(f"Reached the {name} at {host}.")
                return
            if "REMOTE HOST IDENTIFICATION HAS CHANGED" in result.stderr or "Host key verification failed" in result.stderr:
                raise Stop(f"the {name}'s SSH host key differs from the one pinned in {self.known_hosts}; "
                           "check that the address is still yours before removing that line")
            if time.monotonic() > deadline:
                raise Stop(f"no SSH to the {name} at {host} after {minutes} minutes: {result.stderr.strip()}")
            waited = int(minutes * 60 - (deadline - time.monotonic())) // 60
            if waited > reported:
                print(f"Waiting for SSH on the {name} ({waited} min)...", flush=True)
                reported = waited
            time.sleep(15)


# ---- 1. Choose ---------------------------------------------------------------
def print_options(options):
    print(f"   {'Region':<14} {'Node plan':<22} {'Helper plan':<22} EUR/hour")
    for number, option in enumerate(options, 1):
        notes = []
        if not option["node"]["tested"]:
            notes.append("node UNTESTED: its BIOS may not offer SEV-SNP")
        if not option["helper"]["tested"]:
            notes.append("helper untested")
        print(f"{number:>2} {option['region']:<14} {option['node']['plan']:<22} {option['helper']['plan']:<22} "
              f"{option['price']:.2f}" + (f"  ({'; '.join(notes)})" if notes else ""))


def plans_command(untested):
    tested = json.loads(TESTED.read_text())
    plans = Cherry(None).get("/plans", auth=False)
    options = rig_options(plans, tested, untested_nodes=untested)
    if not options:
        print("No pair of these plans is in stock in one region right now.")
        return 1
    print_options(options)
    return 0


def choose_project(cherry, wanted=None):
    projects = []
    for team in cherry.get("/teams"):
        for project in cherry.get(f"/teams/{team['id']}/projects"):
            servers = cherry.get(f"/projects/{project['id']}/servers")
            projects.append({"id": project["id"], "name": project.get("name", ""), "team": team.get("name", ""),
                             "servers": len(servers)})
    if not projects:
        raise Stop("your Cherry Servers account has no project; create one in the portal first")
    if wanted is not None:
        chosen = next((p for p in projects if str(p["id"]) == str(wanted)), None)
        if not chosen:
            raise Stop(f"no project {wanted} in your Cherry Servers account")
        print(f"Project: {chosen['name']} ({chosen['id']}), {chosen['servers']} servers already in it.")
        return chosen
    if len(projects) == 1:
        chosen = projects[0]
        print(f"Project: {chosen['name']} ({chosen['id']}).")
    else:
        print("Projects (use one with nothing else in it, so the private VLAN holds only this rig):")
        for number, project in enumerate(projects, 1):
            print(f"{number:>2} {project['name']} ({project['id']}, team {project['team']}): {project['servers']} servers")
        default = next((n for n, p in enumerate(projects, 1) if p["servers"] == 0), 1)
        chosen = projects[pick(len(projects), default, flag="--project") - 1]
    if chosen["servers"] and not confirm(f"Project {chosen['name']} already has {chosen['servers']} servers. Use it anyway?", False):
        raise Stop("choose or create an empty project, then run make order-rig again")
    return chosen


def pick(count, default, flag=None):
    while True:
        answer = ask("Number", str(default), flag=flag)
        if answer.isdigit() and 1 <= int(answer) <= count:
            return int(answer)
        print(f"Enter a number from 1 to {count}.")


def choose_key(cherry, given=None):
    default = next((str(p) for p in (Path.home() / ".ssh" / n for n in ("id_ed25519", "id_ecdsa", "id_rsa"))
                    if p.is_file()), None)
    if given is None and not sys.stdin.isatty():
        given = default
    key = Path(ask("SSH private key for both servers", default, given, "--ssh-key")).expanduser().resolve()
    public = Path(str(key) + ".pub")
    if not key.is_file() or not public.is_file():
        raise Stop(f"need both {key} and {public}")
    if subprocess.run(["ssh-keygen", "-y", "-P", "", "-f", str(key)], capture_output=True).returncode != 0:
        fingerprint = subprocess.run(["ssh-keygen", "-l", "-f", str(public)], capture_output=True, text=True).stdout.split()
        loaded = subprocess.run(["ssh-add", "-l"], capture_output=True, text=True).stdout
        if len(fingerprint) < 2 or fingerprint[1] not in loaded:
            raise Stop(f"{key} has a passphrase. Load it into an agent in this terminal, then run make order-rig again:\n"
                       f'  eval "$(ssh-agent -s)" && ssh-add {key}')
    key_id = matching_key_id(public.read_text(), cherry.get("/ssh-keys"))
    print(f"Cherry Servers already has this key (ID {key_id})." if key_id else "The key will be added to your Cherry Servers account.")
    return {"ssh_key": str(key), "ssh_public_key": str(public), "ssh_key_id": key_id}


def store_pull_secret(rig):
    if rig.pull_secret.is_file():
        print(f"Pull secret: {rig.pull_secret}")
        return
    source = Path(ask(f"Path to your Red Hat pull secret (download it from {PULL_SECRET_PAGE})",
                      given=rig.args.pull_secret, flag="--pull-secret")).expanduser()
    try:
        auths = json.loads(source.read_text())["auths"]
    except (OSError, ValueError, KeyError, TypeError):
        raise Stop(f"{source} is not a pull secret (a JSON file with an auths section)") from None
    if "registry.redhat.io" not in auths:
        raise Stop(f"{source} has no registry.redhat.io entry; download the pull secret again from {PULL_SECRET_PAGE}")
    write_private(rig.pull_secret, source.read_text())
    print(f"Copied it to {rig.pull_secret}.")


def choose(rig, args):
    stage(1, "Choose the servers")
    if rig.order and rig.ordered():
        print(f"Using the rig already ordered in {rig.order['region']}: node {rig.order['node']['plan']}, "
              f"helper {rig.order['helper']['plan']}.")
        store_pull_secret(rig)
        return
    # Without a terminal, a run that names no region reuses the earlier choice.
    reuse = None if sys.stdin.isatty() else not args.region
    if rig.order and confirm(f"Order the rig chosen earlier ({rig.order['node']['plan']} and {rig.order['helper']['plan']} "
                             f"in {rig.order['region']}, project {rig.order['project_id']})?", given=reuse):
        store_pull_secret(rig)
        return
    tested = json.loads(TESTED.read_text())
    plans = rig.cherry.get("/plans", auth=False)
    options = rig_options(plans, tested, untested_nodes=args.untested)
    if not options:
        raise Stop("no tested pair of plans is in stock in one region right now. Try again later, or list "
                   "untested SEV-SNP plans with: python3 scripts/order-rig.py plans --untested")
    print("Plans in stock, the recommended rig first:\n")
    print_options(options)
    print()
    if args.region:
        option = next((o for o in options if o["region"] == args.region), None)
        if not option:
            raise Stop(f"no rig in stock in {args.region}")
        print(f"Region: {args.region}")
    else:
        option = options[pick(len(options), 1, flag="--region") - 1]
    print()
    project = choose_project(rig.cherry, args.project)
    print()
    access = choose_key(rig.cherry, args.ssh_key)
    print()
    store_pull_secret(rig)
    rig.order = dict(option, project_id=project["id"], project_name=project["name"], **access)
    write_private(rig.order_file, json.dumps(rig.order, indent=2) + "\n")


# ---- 2. Order ----------------------------------------------------------------
def wait_for_delivery(rig, role, server):
    if server.get("state") == "active":
        return server
    print(f"Cherry is still delivering the {role} (server {server['id']}, {server.get('state') or server.get('status')}). "
          f"Waiting for it instead of ordering another, for up to {DELIVERY_HOURS} hours.", flush=True)
    started, reported = time.monotonic(), 0
    while True:
        if server.get("status") == "failed deployment":
            raise Stop(f"Cherry could not deliver the {role} (server {server['id']}). Delete it in the Cherry portal, "
                       "then run make order-rig again to order another")
        minutes = int(time.monotonic() - started) // 60
        if minutes >= DELIVERY_HOURS * 60:
            raise Stop(f"Cherry has not delivered the {role} (server {server['id']}) in {DELIVERY_HOURS} hours. "
                       "Ask Cherry support, or delete it in the Cherry portal and run make order-rig again")
        if minutes >= reported + 5:
            print(f"Still waiting for the {role} ({minutes} min)...", flush=True)
            reported = minutes
        time.sleep(30)
        server = rig.cherry.get(f"/servers/{server['id']}")
        if server.get("state") == "active":
            print(f"Cherry delivered the {role}.")
            return server


def adopt_servers(rig):
    """Take over a server Cherry created but Terraform never recorded.

    That happens when terraform apply stops waiting for a slow delivery or is
    interrupted. Planning again would order a second server and leave the first
    one billing, so wait for it and import it into the state instead.
    """
    _, listed = rig.terraform("state", "list", check=False)
    missing = [role for role in ("node", "helper") if f"cherryservers_server.{role}" not in listed.split()]
    if not missing:
        return
    project = rig.order["project_id"]
    servers = rig.cherry.get(f"/projects/{project}/servers")
    for role in missing:
        found = [server["id"] for server in servers
                 if server.get("hostname") == HOSTNAMES[role] and server.get("state") != "terminating"]
        if not found:
            continue
        if len(found) > 1:
            raise Stop(f"Terraform recorded none of the {len(found)} {role} servers in project {project} "
                       f"({', '.join(map(str, found))}); delete all but one in the Cherry portal, "
                       "then run make order-rig again")
        server = rig.cherry.get(f"/servers/{found[0]}")
        plan, region = (server.get("plan") or {}).get("slug"), (server.get("region") or {}).get("slug")
        if (plan, region) != (rig.order[role]["plan"], rig.order["region"]):
            raise Stop(f"server {found[0]} in project {project} is named {HOSTNAMES[role]} but is a {plan} in {region}, "
                       f"not the {rig.order[role]['plan']} in {rig.order['region']} ordered here; delete it in the "
                       "Cherry portal or order into an empty project")
        server = wait_for_delivery(rig, role, server)
        print(f"Taking over the {role} (server {server['id']}): Terraform stopped waiting before Cherry delivered it.")
        rig.terraform("import", "-input=false", "-no-color", f"-var-file={rig.tfvars}",
                      f"cherryservers_server.{role}", str(server["id"]))


def planned_changes(rig):
    _, output = rig.terraform("show", "-json", str(rig.tfplan))
    return [(c["address"], c["change"]["actions"]) for c in json.loads(output).get("resource_changes", [])
            if c["change"]["actions"] != ["no-op"]]


def order_servers(rig):
    stage(2, "Order the servers")
    tfvars = render_tfvars(rig.order)
    if rig.tfvars.is_file() and rig.tfvars.read_text() != tfvars:
        # An earlier rig's variables; Terraform needs them to destroy that rig.
        old = rig.tfvars.with_name(f"cherry.tfvars.{datetime.now(timezone.utc):%Y%m%dT%H%M%SZ}.old")
        rig.tfvars.rename(old)
        print(f"Moved the earlier Terraform variables to {old}.")
    write_private(rig.tfvars, tfvars)
    rig.terraform("init", "-input=false", "-no-color", f"-backend-config=path={rig.state / 'cherry.tfstate'}")
    adopt_servers(rig)
    replace = []
    for _ in range(2):
        code, output = rig.terraform("plan", "-input=false", "-no-color", "-detailed-exitcode",
                                     f"-var-file={rig.tfvars}", f"-out={rig.tfplan}", *replace, check=False)
        if code == 1 and any(text in output for text in SWITCH_ERRORS) and not replace:
            print("Cherry put the two servers on different switches, so they share no private VLAN.")
            if not confirm("Replace the helper with a new one (the old helper is deleted)?",
                           given=flag_answer(rig.args.replace_helper), flag="--replace-helper"):
                raise Stop("the servers share no private VLAN; replace the helper or ask Cherry support to move it")
            replace = ["-replace=cherryservers_server.helper"]
            continue
        if code == 1:
            print(output, file=sys.stderr)
            raise Stop("terraform plan failed")
        break
    if code == 0:
        print("Both servers are already ordered.")
    else:
        changes = planned_changes(rig)
        unexpected = [address for address, actions in changes
                      if "delete" in actions and not (replace and address == "cherryservers_server.helper")]
        if unexpected:
            raise Stop("the Terraform plan would delete " + ", ".join(unexpected) +
                       f"; review it by hand: terraform -chdir=infra/cherry plan -var-file={rig.tfvars}")
        node, helper = rig.order["node"], rig.order["helper"]
        print(f"This orders, in {rig.order['region']}, project {rig.order['project_id']}:")
        for address, actions in changes:
            what = {"cherryservers_server.node": f"the node, {node['plan']} ({node['price']:.2f} EUR/hour)",
                    "cherryservers_server.helper": f"the helper, {helper['plan']} ({helper['price']:.2f} EUR/hour)",
                    "cherryservers_ssh_key.rig[0]": "your SSH public key, added to the account",
                    }.get(address, address)
            verb = "replace" if "delete" in actions else "update" if "update" in actions else "create"
            print(f"  {verb} {what}")
        print(f"\nTogether about {rig.order['price']:.2f} EUR/hour, billed until you retire the rig "
              "(docs/maintenance.md#retire-the-infrastructure).\nDelivery usually takes 15 to 30 minutes and "
              f"sometimes over an hour; Terraform waits up to {DELIVERY_HOURS} hours.\n")
        if ask("Type yes to order", given="yes" if rig.args.confirm_order else None, flag="--confirm-order") != "yes":
            raise Stop("nothing was ordered")
        code, output = rig.terraform("apply", "-input=false", "-no-color", str(rig.tfplan), stream=True, check=False)
        rig.tfplan.unlink(missing_ok=True)
        if code != 0:
            if any(text in output for text in SWITCH_ERRORS):
                raise Stop("the servers landed on different switches; run make order-rig again to replace the helper")
            if "context deadline exceeded" in output:
                raise Stop(f"Cherry has not delivered a server in {DELIVERY_HOURS} hours. Ask Cherry support about it, "
                           "then run make order-rig again: it takes over that server instead of ordering another")
            raise Stop("terraform apply failed; fix the cause above and run make order-rig again")
    values = rig.rig_values()
    if not values:
        raise Stop("Terraform has no rig_values output; run make order-rig again")
    return values


# ---- 3. Reach ----------------------------------------------------------------
def reach(rig, values):
    stage(3, "Reach both servers and pin their host keys")
    servers = f"{values['node_id']} {values['helper_id']}\n"
    marker = rig.state / "known_hosts.servers"
    if rig.known_hosts.exists() and (not marker.is_file() or marker.read_text() != servers):
        # Host keys from an earlier rig; Cherry reuses addresses.
        old = rig.known_hosts.with_name(f"known_hosts.{datetime.now(timezone.utc):%Y%m%dT%H%M%SZ}.old")
        rig.known_hosts.rename(old)
        print(f"Moved the host keys of an earlier rig to {old}.")
    write_private(marker, servers)
    rig.known_hosts.touch(mode=0o600)
    rig.wait_for_ssh("helper", values["helper_public_ipv4"])
    rig.wait_for_ssh("node", values["node_public_ipv4"])
    print(f"\nHost keys pinned in {rig.known_hosts} on first contact:")
    listing = subprocess.run(["ssh-keygen", "-l", "-f", str(rig.known_hosts)], capture_output=True, text=True).stdout
    print(listing.rstrip())


# ---- 4. Start the helper bootstrap -------------------------------------------
def helper_status(rig, values):
    return rig.ssh(values["helper_public_ipv4"], HELPER_STATUS).stdout.strip()


def start_bootstrap(rig, values):
    stage(4, "Start the helper's mirror bootstrap")
    helper = values["helper_public_ipv4"]
    status = helper_status(rig, values)
    if status in ("ready", "running"):
        print("The bootstrap is already " + ("done." if status == "ready" else "running."))
        return
    if status == "failed":
        print(rig.ssh(helper, HELPER_LOG, check=False).stdout)
        if not confirm("The last bootstrap failed (log above). Start it again?", False,
                       given=flag_answer(rig.args.restart_bootstrap), flag="--restart-bootstrap"):
            raise Stop("fix the cause on the helper, then run make order-rig again")
    script = subprocess.run([sys.executable, str(REPO / "scripts/render-helper-bootstrap.py")],
                            capture_output=True, text=True)
    if script.returncode != 0:
        raise Stop(script.stderr.strip())
    write_private(rig.bootstrap, script.stdout)
    # A systemd unit, as cloud-init would run it: it survives the SSH session.
    rig.ssh(helper, f"rm -f {MIRROR_ROOT}/MIRROR_FAILED; systemctl reset-failed helper-bootstrap 2>/dev/null; "
                    "install -m 700 /dev/stdin /usr/local/sbin/helper-bootstrap.sh && "
                    "systemd-run --unit=helper-bootstrap /usr/local/sbin/helper-bootstrap.sh", stdin=script.stdout)
    print("Started. It installs packages, then downloads and sets up the mirror registry.")


# ---- 5. Check the node -------------------------------------------------------
def observe_node(rig, values):
    result = rig.ssh(values["node_public_ipv4"], "python3 -", stdin=OBSERVE_NODE)
    observation = json.loads(result.stdout)
    if observation["hostname"] != values["node_hostname"]:
        raise Stop(f"the server at {values['node_public_ipv4']} calls itself {observation['hostname']}, "
                   f"not {values['node_hostname']}; check the address in the Cherry portal")
    return observation


def check_node(rig, values):
    stage(5, "Check the node's network and disks")
    observation = observe_node(rig, values)
    network = network_facts(observation, values["node_private_ipv4"])
    if len(network["ports"]) < 2:
        loose = ", ".join(f"{name} ({network['loose_macs'][name]})" for name in network["loose_nics"])
        print(f"{network['bond']} has {len(network['ports'])} of its 2 members"
              + (f"; {loose} did not join it." if loose else ".")
              + " New Cherry nodes sometimes boot like this, and one reboot fixes it.")
        if not confirm("Reboot the node's original OS now?", given=flag_answer(rig.args.reboot_node), flag="--reboot-node"):
            raise Stop("the install needs both bond members; see docs/troubleshooting.md#installation")
        rig.ssh(values["node_public_ipv4"], "systemctl reboot", check=False, timeout=60)
        time.sleep(60)
        rig.wait_for_ssh("node", values["node_public_ipv4"], minutes=15)
        observation = observe_node(rig, values)
        network = network_facts(observation, values["node_private_ipv4"])
        if len(network["ports"]) < 2:
            raise Stop(f"{network['bond']} still has {len(network['ports'])} member after a reboot; "
                       "see docs/troubleshooting.md#installation")
    if values.get("vlan_tag") and network["vlan_tag"] != values["vlan_tag"]:
        raise Stop(f"the node's VLAN tag {network['vlan_tag']} differs from the {values['vlan_tag']} Cherry reports")
    disks = disk_facts(observation)
    print(f"Private VLAN {network['vlan_tag']} on {network['vlan_if']}; bond {network['bond']} with "
          + " and ".join(f"{p['name']} ({p['mac']})" for p in network["ports"]) + ".")
    for disk in disks:
        print(f"Disk {disk['name']}: {disk['size_gb']} GB, {disk['model']}, serial {disk['serial']}"
              + (", holds /boot/efi" if disk["holds_efi"] else ""))
    return network, disks


# ---- 6. Wait for the mirror --------------------------------------------------
def wait_for_mirror(rig, values, minutes=120):
    stage(6, "Wait for the helper's mirror registry")
    helper = values["helper_public_ipv4"]
    print("The node needs nothing more until the install, so you can set its BIOS while this runs\n"
          "(docs/quickstart.md#3-set-the-bios). The helper installs packages and the registry first.\n")
    deadline, last = time.monotonic() + minutes * 60, None
    while True:
        status = helper_status(rig, values)
        if status == "ready":
            print("The mirror registry is ready.")
            break
        if status in ("failed", "none"):
            print(rig.ssh(helper, HELPER_LOG, check=False).stdout)
            raise Stop("the helper bootstrap failed (log above); see docs/troubleshooting.md, "
                       "then run make order-rig again to restart it")
        line = rig.ssh(helper, "tail -n 1 /var/log/mirror-bootstrap.log 2>/dev/null || "
                               "journalctl -u helper-bootstrap --no-pager -n 1 -o cat", check=False).stdout.strip()
        if line and line != last:
            print(f"  {line[:150]}", flush=True)
            last = line
        if time.monotonic() > deadline:
            raise Stop(f"the mirror is still not ready after {minutes} minutes")
        time.sleep(30)
    return parse_env_file(rig.ssh(helper, "cat /etc/rig-network.env").stdout)


# ---- 7. Write the rig file ---------------------------------------------------
def read_rig_file(rig):
    import yaml  # From the controller requirements.
    return (yaml.safe_load(rig.rig_file.read_text()) or {}) if rig.rig_file.is_file() else {}


def finished(rig, values):
    """The rig file is written last, so one for these servers means every stage passed."""
    existing = read_rig_file(rig)
    if str(existing.get("node_server_id")) != str(values["node_id"]):
        return None
    print(f"\n{rig.rig_file} is already written for this rig, so the checks are done.\n"
          "To run them again and write a new rig file, delete it and run make order-rig again.")
    return existing


def write_rig_file(rig, values, network, disks, helper_env):
    stage(7, "Write the rig file")
    import yaml  # From the controller requirements.
    if rig.rig_file.is_file():
        old = rig.rig_file.with_name(f"rig.yml.{read_rig_file(rig).get('node_server_id', 'old')}.old")
        rig.rig_file.rename(old)
        print(f"Moved the rig file of an earlier rig to {old}.")
    access = {"ssh_key": rig.order["ssh_key"], "known_hosts": str(rig.known_hosts),
              "pull_secret": str(rig.pull_secret), "disk": disks[0], "disks": disks}
    text = render_rig_file(values, network, helper_env, access, secrets.token_hex(16),
                           datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC"))
    write_private(rig.rig_file, text)
    print(f"Wrote {rig.rig_file}.")
    return yaml.safe_load(text)


def summary(rig, values, rig_file):
    disk = rig_file.get("node_root_device")
    print(f"\n== Rig ready ==\n\n"
          f"Node {values['node_id']} ({rig.order['node']['plan']}) at {values['node_public_ipv4']}, "
          f"helper at {values['helper_public_ipv4']}, private VLAN {rig_file.get('vlan_vid_override')}.\n"
          f"Install disk: {disk} (to use another one, edit node_root_device in {rig.rig_file}).\n"
          f"Billing: about {rig.order['price']:.2f} EUR/hour until you retire the rig.\n\n"
          "Next: set the BIOS, quickstart step 3 (docs/quickstart.md#3-set-the-bios), then install with\n"
          "  bash ansible/up.sh --mode fresh-install")


def check_snp(state):
    """Run the read-only node checks on the node's original OS and keep their output."""
    rig = Rig(state, Cherry(None), None)
    values = rig.rig_values() if rig.order else None
    if not values:
        raise Stop("no ordered rig found; run make order-rig first")
    host = values["node_public_ipv4"]
    rig_file = read_rig_file(rig)
    same_rig = str(rig_file.get("node_server_id")) == str(values["node_id"])
    root_device = (rig_file.get("node_root_device") or "") if same_rig else ""

    def ssh(command, stdin):
        return rig.ssh(host, command, stdin=stdin, check=False, timeout=600)

    try:
        report = node_checks.check_node(ssh, values["node_hostname"], root_device)
    except node_checks.NodeUnreachable as error:
        raise Stop(f"no SSH to the node at {host}: {error}") from None
    print(report["snp_output"], end="")
    print("\n" + "\n".join(report["lines"]))
    evidence = node_checks.save_evidence(report, state / "evidence", values["node_id"], host)
    print(f"\nSaved in {evidence}.")
    return 0 if report["passed"] else 1


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", nargs="?", choices=("order", "plans", "check-snp"), default="order",
                        help="order (default) the rig; list the tested plans in stock; or check SEV-SNP on the node")
    parser.add_argument("--untested", action="store_true",
                        help="offer untested node plans whose CPU supports SEV-SNP (their BIOS may not)")
    answers = parser.add_argument_group("answers", "Answer a question ahead, for example when no terminal is attached")
    answers.add_argument("--region", help="order the rig offered in this region")
    answers.add_argument("--project", help="Cherry Servers project ID")
    answers.add_argument("--ssh-key", help="SSH private key for both servers (its .pub must be next to it)")
    answers.add_argument("--pull-secret", help="Red Hat pull secret to copy into COCO_STATE_DIR")
    answers.add_argument("--confirm-order", action="store_true", help="order without asking; this starts billing")
    answers.add_argument("--replace-helper", action="store_true", help="replace a helper on another switch")
    answers.add_argument("--reboot-node", action="store_true", help="reboot the node when its bond misses a member")
    answers.add_argument("--restart-bootstrap", action="store_true", help="start a failed helper bootstrap again")
    args = parser.parse_args(argv)
    try:
        if args.command == "plans":
            return plans_command(args.untested)
        if not shutil.which("terraform"):
            raise Stop("install Terraform 1.9 or later first: https://developer.hashicorp.com/terraform/install")
        state = state_dir()
        if args.command == "check-snp":
            return check_snp(state)
        key = os.environ.get("CHERRY_SERVERS_API_KEY") or (
            (state / "cherry-api-key").read_text().strip() if (state / "cherry-api-key").is_file() else "")
        rig = Rig(state, Cherry(key), args)
        choose(rig, args)
        values = order_servers(rig)
        rig_file = finished(rig, values)
        if rig_file is None:
            reach(rig, values)
            start_bootstrap(rig, values)
            network, disks = check_node(rig, values)
            helper_env = wait_for_mirror(rig, values)
            rig_file = write_rig_file(rig, values, network, disks, helper_env)
        summary(rig, values, rig_file)
    except (Stop, RigError) as error:
        print(f"\nERROR: {error}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("\nStopped. Run make order-rig again to continue.", file=sys.stderr)
        return 130
    return 0


if __name__ == "__main__":
    sys.exit(main())
