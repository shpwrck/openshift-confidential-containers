---
leave-behind: v1
state-scope: cherry-qualification
status: current
---

# Cherry qualification leave-behind

## Operability

### State and access

This temporary paid validation rig is installing OpenShift; a healthy cluster has not yet been verified. Task project 295533 (`coco-qualification-20261008`) owns AMD server 1025551 (`coco-snp-chicago-20261008`), mirror/helper server 1025601 (`coco-mirror-chicago-20261008`) and SSH key 19635 in US-Chicago. Pre-existing project 295530 is outside this scope. Resolve current addresses through the provider API before access; never reconnect to a released address.

Private controller state, task SSH key, pinned host keys, console credentials and raw evidence are outside the checkout at `/home/jskrzypek/.local/state/openshift-confidential-containers/cherry/trial/`. The API credential is supplied as `CHERRY_SERVERS_API_KEY` by the user's interactive shell. `rig.json` contains a boot publication token and must remain private. `deployment/` is this trial's `COCO_STATE_DIR`; protected logs and generated assets are retained separately. The helper uses AlmaLinux 9.8, an explicitly limited lab compatibility test rather than a supported RHEL mirror host.

The node has private address 10.182.89.36 and helper 10.182.89.26 on VLAN wire tag 2064. Both use `bond0` in 802.3ad mode with `enp5s0f0` and `enp5s0f1`. API VLAN object ID 1213 is not the wire tag. The helper serves private DNS, NTP and `mirror.rig.local:8443`. Reach the node through pinned SSH via the helper; no private SSH key is copied there. The Agent live key is preserved in `node-agent-known_hosts`. The installed node key was independently verified on the authenticated, certificate-pinned BMC console and is in `node-installed-known_hosts`; do not disable host verification after a later key change. `cluster-kubeconfig` and `cluster-env.sh` are protected controller inputs for the explicit `cherry-validation` context. The API uses a local SSH tunnel at 127.0.0.1:26443 with its real TLS server name retained.

### Template map

scripts/host-snp-check.sh -> read-only SSH execution on the selected node, protected SNP evidence

ansible/roles/render_configs/templates/agent-config.yaml.j2 -> helper /opt/install/cluster-assets/agent-config.yaml and private PXE assets

infra/latitude/bastion/cloud-init/mirror-registry.yaml -> helper registry bootstrap and /usr/local/sbin/ensure-mirror-tls.sh

ansible/roles/bastion_isolation/templates/bastion-isolation.sh.j2 -> helper /usr/local/sbin/coco-bastion-isolation.sh

ansible/roles/dns_ntp/templates/dnsmasq-cluster.conf.j2 -> helper /etc/dnsmasq.d/cluster.conf

Private trial/control.py -> task provider objects and private trial/state.json

### Re-run

Check provider ownership and the retirement deadline before access. Do not rerun allocation or issue another rebuild while this install is active. The repository's supplied-rig workflow and exact sequence are in [Cherry validation](../../cherry-validation.md): prepare, render fresh artifacts, qualify the private link, fresh-install, then verify. Load the external rig inputs and `CHERRY_SERVERS_API_KEY`; Cherry is not implemented by the Latitude Terraform modules.

An accepted fresh-install request is journaled in `/opt/install/provider-requests`; resuming unchanged inputs must reuse that request. A `sending` or ambiguous result requires provider-state inspection before explicitly permitting a retry. PXE source assets are private under `/opt/install`; only tokenized copies are published by nginx. Close the endpoint using the documented `pxe-stop` task when no accepted install still needs it. Registry rotation uses strict X.509 verification and preserves the existing CA and key; do not replace trust to hide arbitrary TLS errors.

Saved BIOS settings are SMEE Enabled, SNP Memory (RMP Table) Coverage Enabled for all memory, SEV-ES ASID Space Limit 100, IOMMU Enabled and SEV-SNP Support Enabled. SVM Mode and SEV Control were already Enabled. No firmware flash, defaults reset, interleaving change or boot-order change was performed. Installed RHCOS SNP verification passed; repeat it after the Kata/MCO rollout.

### Verify and recover

Verified October 8, 2026: EPYC 9124, H13SST-G, BIOS 3.7 built January 23, 2026 and UEFI. Ubuntu 26.04.1 host checks and digest-verified `snphost` 0.7.0 exited zero after the five BIOS changes. `/dev/sev` and `sev_snp=Y` are present, SNP API is 1.58 build 2, RMP initialized with no aliasing addresses, and TCB values match. Retain the initial Auto-setting failure evidence. The Agent-live RHCOS 9.6.20260818-0 kernel 5.14.0-570.135.1.el9_6.x86_64 independently passed the repository host gate with RMP range `0x93700000–0xa3cfffff`. Installed RHCOS 9.6.20260914-0, kernel 5.14.0-570.141.1.el9_6.x86_64, independently passed the same host gate and UEFI check. These remain host prerequisites rather than guest attestation.

Bidirectional private ping and the exact prepared-artifact DNS/NTP/registry TLS gate passed. oc-mirror completed the selected OCP 4.20.39 and Operator content. Fresh installation wrote RHCOS to disk, registered a Ready node and reached the main API/etcd rollout; inspect `/opt/install/cluster-assets/.openshift_install.log` on the helper and protected `fresh-install.log` locally. A brief NTP warning recovered before installation. The helper API mapping originally ran after the wait; moving it before the wait and applying only that task let the installer discover the live API. A startup API installer pod failed, then normal controllers created later revisions without manual pod or datastore repair. Main API and etcd are now available; authentication, monitoring and remaining core services are still converging. Cluster acceptance has not passed. Follow actual status rather than treating a warning or accepted provider request as success.

The Agent-live network has only private IPv4 and no public/global IPv6. Public IPv4 TCP timed out, IPv6 was unreachable, public registry DNS was denied, and the private registry remained reachable. The helper's persistent nft rule drops private-VLAN forwarding to the public underlay even though Podman enables forwarding; a forced-route probe produced four attributable packet drops and was removed. DNS upstream forwarding is disabled. The installed node retained these denial results and trusted registry access after OVN moved its address to br-ex; bond0.2064 remains the underlying private VLAN. Repeat checks from pods and confidential guests. Provider iPXE boot-artifact delivery used the tokenized public helper endpoint; fully private boot delivery from power-on is not established. No guest attestation, signature enforcement, encrypted image, customer upgrade or clean-repeat result is claimed.

The mandatory retirement deadline remains **2026-10-08 19:38:10 UTC (3:38 p.m. EDT)**. An extension was requested but has not been approved. `coco-cherry-budget.timer` runs `control.py guard` every minute in local WSL user systemd; WSL must remain running and this is not a provider-side spending cap. For early retirement, run `control.py cleanup-plan`, then `control.py cleanup` through the interactive shell that loads the key. The controller deletes only the two exact task servers, then confirms their absence before retiring the task SSH key/project. Preserve diagnostics and remove the timer/service after confirmed retirement. Actual Cherry deletion has not yet been exercised.

## Decision log

### Decisions

Qualify one hourly Genoa node before renting its helper. Both allocated rates are €0.53/hour before extras; the conservative catalogue quote is €0.61/hour. The original four-hour two-server ceiling is €4.24 at allocated rates, with the helper created later. Qualification remains within $20 and the overall $150 cap across providers. Do not silently extend the time window or change recharge settings.

The included HTML5 BMC console enabled BIOS configuration without engineering assistance. The licensed Redfish BIOS endpoint rejected reads; no licence was purchased or gate bypassed. Cherry's genuine private VLAN and LACP bond passed the prerequisite that failed at Latitude. The node's Agent configuration omits public IPs, while helper forwarding and DNS rules prevent it from becoming an egress path.

Preparation defects were repaired and exercised: reuse installed curl/curl-minimal, issue separate firewalld operations, and replace the malformed generated mirror-registry 2.0.12 server leaf using the existing lab CA/key and supported rotation command. The API hostname mapping now precedes the installer wait, and managed DNS/NTP firewall failures are no longer ignored. Base64 iPXE submission includes real newline bytes and the preserved API hostname. Provider identity checks bind numeric server ID, project, hostname and current addresses before rebuild.

### How to drive it

Check the deadline and provider ownership, monitor the existing installation, and preserve its diagnostics. Verify the completed exact payload and cluster health, close PXE publication, then recheck installed-node SNP and isolation. Install resolved OSC 1.13.1 / Trustee 1.2.1 using explicit contexts and disposable SNO lab selection; rebind endorsement collateral to the actual RHCOS TCB before attestation. Record positive, attributable denial and recovery for each rung. A clean repeat remains required before declaring the workflow validated. Update [the sanitized receipt](../../validation/cherry-qualification-2026-10-08.json) and this runbook at each material change, or mark retired after confirmed cleanup.
