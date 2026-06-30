# Ansible — hands-off disconnected SNO air-gapped bring-up

This tree reproduces, hands-off, the proven disconnected single-node OpenShift (SNO) air-gapped
bring-up on Latitude — pausing only at the SEV-SNP BIOS step. It is a faithful Ansible translation
of the validated `scripts/*.sh`, `install/*.tmpl`, and `docs/runbooks/disconnected-sno-bringup.md`
(end-to-end on hardware, 2026-06-28).

It targets the **rig SNO path first** but is structured **portable** (inventory + group_vars +
roles), so extending to the customer's multi-node air-gapped cluster is a config change, not a
rewrite — see [Portability](#portability).

## TF owns infra / Ansible owns host + install

| Layer | Owns | Where |
|-------|------|-------|
| **Terraform** | bastion, SNP node, VLAN, inbound firewall, netboot (`operating_system = ipxe`, `ipxe_url`) | `infra/latitude/`, `infra/latitude/bastion/` |
| **Ansible** | bastion host config (egress, tools, mirror push, dns/ntp) + the OpenShift install (render, pxe-serve, reinstall+wait) | this tree |

`make bringup-sno-airgapped` (root Makefile) interleaves them; `ansible/up.sh` is the same sequence standalone.

## What runs, in phase order

`playbooks/site.yml` orchestrates (each phase is also a `--tags` selector):

1. **Phase A — bastion prep** (`--tags bastion-prep`), run after `terraform apply` of the bastion:
   - `bastion_egress` (**first**): drop the IPv6 default route, set the IPv4 default-route MTU to
     1400, add an nftables OUTPUT SYN MSS clamp to 1360. A fresh Latitude bastion's IPv6 egress to
     quay's CDN blackholes large oc-mirror blobs; oc-mirror is a Go binary so `/etc/gai.conf`
     IPv4-preference is ignored — v6 reachability must be removed.
   - `mirror_tools`: install pinned `oc`/`kubectl`/`openshift-install`/`oc-mirror` to
     `/usr/local/bin`, install `nmstate` (needed before `agent create pxe-files`), trust the mirror
     CA, build the merged `/root/.docker/config.json` (RH pull-secret + mirror creds).
   - `mirror_push`: `oc-mirror --v2` push with **resume-on-retry** (the v2 workspace is cacheable;
     `unset REGISTRY_AUTH_FILE` is enforced via the task environment).
   - `dns_ntp`: cluster dnsmasq records (`api`/`api-int` + `apps` wildcard) + chrony `allow`.
2. **STOP — SEV-SNP BIOS** (`pause`): prints the recipe; set it on the node via Latitude IPMI
   before it netboots. Skip the pause for unattended runs with `-e skip_bios_pause=true`.
3. **Phase B — discover** (`discover.yml`): query the Latitude API per machine, register the
   interface whose `role == internal` (the PXE/VLAN-parent NIC) as `parent_mac`, written to
   `group_vars/discovered.yml`. **MACs are never hardcoded.**
4. **Phase C — install**: `render_configs` (install-config + agent-config; `additionalNTPSources`
   goes in agent-config), `pxe_serve` (build pxe-files, tokenized nginx serve, verify HTTP 206),
   `install_drive` (Latitude **reinstall** to re-netboot — not a reboot; `wait-for install-complete`
   with a non-fatal bootstrap timeout; poll `clusterversion` until Available=True/Progressing=False;
   add cluster names to the bastion `/etc/hosts`), then `public_console` (default-on sslip.io
   console/OAuth edge through the bastion public IP).
5. **Post-install** (`--tags pxe-stop`): close the boot-artifact endpoint (the secret-bearing
   initrd must not stay public — issue #33).

## Prerequisites

- `terraform apply` of the bastion module has run (mirror registry up; CA + admin password on the
  bastion at `/opt/mirror/`).
- The **RH pull-secret** is on the bastion at `~/pull-secret.json` (Phase 0; never committed).
- The node SSH public key is on the bastion at `~/coco-rig.pub`.
- Environment: `export LATITUDESH_AUTH_TOKEN=...` (or `LATITUDE_API_TOKEN`) for the discover +
  reinstall API calls.

## Running

```bash
cd ansible

# generate a per-run unguessable token for the secret-bearing initrd path (issue #33)
TOKEN=$(openssl rand -hex 16)

# values from terraform output
BAS_IP=$(terraform -chdir=../infra/latitude/bastion output -raw bastion_public_ipv4)
VID=$(terraform -chdir=../infra/latitude/bastion output -raw virtual_network_vid)
SRV=$(terraform -chdir=../infra/latitude output -raw server_id)

ansible-playbook playbooks/site.yml \
  -e bastion_ansible_host=$BAS_IP \
  -e bastion_public_ipv4_override=$BAS_IP \
  -e vlan_vid_override=$VID \
  -e node_server_id=$SRV \
  -e boot_artifacts_token=$TOKEN
```

The public console edge is enabled by default after the cluster is Available. Opt out with
`-e public_console_enabled=false`; the role removes its managed nginx snippet on opt-out.

Or the single entrypoint (prints the TF commands; add `--apply-tf` to run them):

```bash
make bringup-sno-airgapped ARGS="-e bastion_ansible_host=$BAS_IP -e bastion_public_ipv4_override=$BAS_IP \
  -e vlan_vid_override=$VID -e node_server_id=$SRV -e boot_artifacts_token=$TOKEN"
```

After the node boots, close the endpoint: `make pxe-stop ARGS="-e bastion_ansible_host=$BAS_IP"`.

## Secrets

Never committed. The Latitude token is read from the environment; the mirror admin password and RH
pull-secret are read from files **on the bastion** at runtime. `.gitignore` excludes
`group_vars/discovered.yml` (runtime-generated), `group_vars/secrets.yml`, `*.local.yml`, and the
vault password file. If you want a local vault, put it at `group_vars/secrets.yml` (ignored) and
load it with `-e @group_vars/secrets.yml` or an `ansible-vault` setup.

## Portability

The `machines` LIST in `group_vars/all.yml` is the seam. For SNO it has one entry. For the
customer multi-node cluster:

- Add an entry per node (each with its own `server_id`, `role`, `hostname`, `vlan_ip`, `parent_if`,
  `root_device`); `discover.yml` fills each `parent_mac` from the API; `render_configs` iterates the
  list into agent-config `hosts:` and dnsmasq host-records.
- Set `control_plane_replicas: 3` and `compute_replicas: N`.
- The roles are unchanged.

### Documented extension TODOs (multi-node)

- **Per-node egress lockdown**: this tree hardens the *bastion's* egress (for oc-mirror). The
  *node's* air-gap egress lockdown (default-deny output except the bastion VLAN IP) is host-side
  nftables (runbook Phase 1) / the `gitops/base/airgap-egress` MachineConfig post-install — add a
  per-node egress role if you want Ansible to own it pre-OpenShift.
- **Per-socket VCEK collection**: hardware-bound attestation data (VCEK certs keyed by lowercase
  HWID, RVPS reference values) is collected per socket by `scripts/collect-vcek.sh` /
  `scripts/gen-rvps-veritas.sh` (runbook Phase 5). Wrap these in a role when automating attestation.

## Linting

```bash
make ansible-lint      # yamllint + ansible-lint + ansible-playbook --syntax-check playbooks/site.yml
```
