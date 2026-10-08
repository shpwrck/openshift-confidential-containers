---
leave-behind: v1
state-scope: cherry-qualification
status: current
---

# Cherry validation leave-behind

## Operability

### State and access

The paid AMD validation rig now has a healthy OpenShift 4.20.39 cluster, OSC 1.13.1, Trustee 1.2.1 and a converged `kata-snp` runtime. All five CPU proofs passed individually and again in one fresh combined run, including verified cleanup and lock release. A clean software/setup repeat remains pending. Task project 295533 (`coco-qualification-20261008`) owns node 1025551, helper 1025601 and SSH key 19635 in US-Chicago. Pre-existing project 295530 is outside this scope. Verify current ownership/addresses through the API before access; never reconnect to a released address.

Protected controller state is `/home/jskrzypek/.local/state/openshift-confidential-containers/cherry/trial/`. It contains `id_ed25519`, pinned host-key files, console credentials, `rig.json`, kubeconfigs, logs and `deployment/` (`COCO_STATE_DIR`). `rig.json` includes the boot publication token. The API key is supplied by `CHERRY_SERVERS_API_KEY` in the owner's interactive shell. No secret values belong in Homelab, Git, receipts or this runbook.

Node private IP is 10.182.89.36 and helper 10.182.89.26 on VLAN wire tag 2064 (API object ID 1213). Both use `bond0`, 802.3ad, with `enp5s0f0`/`enp5s0f1`. Installed RHCOS uses br-ex over bond0.2064 and has no public/global IPv6 address. The helper provides DNS, NTP and `mirror.rig.local:8443`, with upstream DNS and private-to-public forwarding blocked. AlmaLinux 9.8 is an explicit helper compatibility test, not the supported RHEL mirror-registry host.

Use pinned SSH through the helper, without copying the task private key there. `node-installed-known_hosts` was independently checked on the authenticated, certificate-pinned BMC console. `node-ssh.py` uses that pin and the helper proxy. The protected `cluster-kubeconfig` selects `cherry-validation`, tunneled at 127.0.0.1:26443 while retaining the real API TLS server name. `cluster-env.sh` and `rung-env.sh` select the exact contexts, mirror inputs and immutable signed/unsigned controls. Public key files are in `deployment/rung-image-artifacts`; the private signing key and password remain on the helper under `/opt/coco-state` and must be preserved before wiping it.

### Template map

ansible/roles/render_configs/templates/agent-config.yaml.j2 -> helper /opt/install/cluster-assets/agent-config.yaml and protected PXE assets

infra/latitude/bastion/cloud-init/mirror-registry.yaml -> helper bootstrap and /usr/local/sbin/ensure-mirror-tls.sh

ansible/roles/bastion_isolation/templates/bastion-isolation.sh.j2 -> helper /usr/local/sbin/coco-bastion-isolation.sh

ansible/roles/dns_ntp/templates/dnsmasq-cluster.conf.j2 -> helper /etc/dnsmasq.d/cluster.conf

scripts/apply-trustee.sh and scripts/lib/trustee_config.py -> TrusteeConfig-owned KbsConfig/ConfigMaps and checked serving pods

scripts/run-proofs.py -> protected deployment/proofs/<new-run>/results.json and recovery/denial evidence

Private trial/control.py -> owned provider objects and protected trial/state.json

### Re-run

Check provider ownership, costs and automatic-retirement state first. The supplied-rig installation sequence is in [Cherry validation](../../cherry-validation.md): prepare, fresh artifacts, private-link qualification, explicit fresh-install, then verify. The accepted installation completed; boot publication is closed. Do not issue another provider rebuild to rerun a proof or verify the existing cluster. An interrupted accepted request resumes through `--mode resume-install` with unchanged inputs and its accepted journal. Changed installs require deliberate new inputs and the documented reinstall gate. Cherry provisioning is not implemented by the Latitude Terraform modules.

BIOS setup is an accepted manual prerequisite. Saved values are SMEE Enabled, full-memory SNP/RMP Coverage Enabled, IOMMU Enabled, SEV-SNP Support Enabled and SEV-ES ASID Space Limit 100. SVM/SEV were already Enabled. No firmware flash, defaults reset, interleaving or boot-order change was performed. The Redfish BIOS endpoint requires a licence and rejected reads; the included console was used. Repeat the host SNP gate after any reinstall, firmware change or Kata rollout.

Load the protected environment scripts before running maintained entry points. The current lab deliberately uses `TRUSTEE_PROFILE=Permissive TRUSTEE_LAB=1`, co-located HTTP, plus the vendor restrictive EAR resource policy. `deployment/rvps-reviewed.json` contains the independently computed non-GPU launch and current typed hardware TCB values with a 30-day expiry. `deployment/enforcing-resource-policy.rego` is the vendor policy. Both policy/reference files and explicit `KBS_RESOURCE_NAMES` are required when publishing this enforcement. Missing one file was tested to stop without changing ConfigMap versions. Permissive's default resource policy alone cannot prove initdata/RVPS enforcement.

Reference generation ran on the connected helper with Python 3.12.14 and an external virtual environment. The exact reviewed runtime command line includes `agent.launch_process_timeout=6`, absent from coco-tools 0.5.1's default. Pass it as one `VERITAS_KERNEL_CMDLINE` argument. The independent result matched the verified SNP quote. Do not copy an observed launch hash into the approved set without calculating it from the selected artifacts. Add actual approved hardware TCB records separately. The generator's unused SHA-384 initdata record was omitted; this workflow binds the declared SHA-256 bytes through the CPU extension.

For proofs, select `NS=coco-workloads`, `TRUSTEE_NS=trustee-operator-system`, `COCO_DISPOSABLE_TEST=1` and `PROOF_NODE=sno-coco-node`. Both namespaces are explicitly marked disposable. Derive `VCEK_SECRET_NAME` from the selected KbsConfig's current cache entry for this worker before the endorsement test. Run `scripts/test-rung.sh <case>` or `all`; each run acquires the Trustee namespace lock and uses new workloads. Do not run another shared-policy mutation while the lock is held. The combined run uses a 90-second negative observation window and excludes encryption.

### Verify and recover

Verified October 8, 2026: EPYC 9124, H13SST-G, BIOS 3.7 built January 23, 2026, UEFI, SNP API 1.58 build 2. Raw Ubuntu/snphost 0.7.0, Agent-live RHCOS, installed RHCOS and post-Kata gates passed. Installed RHCOS is 9.6.20260914-0, kernel 5.14.0-570.141.1.el9_6.x86_64, with `/dev/sev`, `sev_snp=Y` and initialized RMP `0x93700000–0xa3cfffff`. Verified guest TCB is bootloader 12, microcode 88, SNP 28, TEE 0. The current lower-case VCEK bundle was re-collected on installed RHCOS; an uppercase raw-Ubuntu copy is preserved outside the active bundle, without weakening seed validation.

Installer completed at 18:14:28 UTC. Exact OCP payload is `sha256:7bcf96bd0766436fcc30ac30d4bba565d27bfe5772d48177f1afd65878209850`. All 34 core Operators are Available with none Progressing/Degraded; master MCP has one Ready machine and no degradation. All five selected CSVs succeeded: OSC 1.13.1, Trustee 1.2.1, NFD 4.20.0-202609201357, cert-manager 1.20.1, Gatekeeper 3.21.1. `kata-cc` uses `kata-snp`. OSC and Trustee must-gather images ran successfully through the mirrors; protected diagnostics are under `deployment/diagnostics`.

Offline SNP resource release, measured-initdata rejection, launch-reference removal, guest signature enforcement and corrupted-VCEK rejection each passed positive, attributable negative and recovery controls. [The CPU receipt](../../validation/cherry-cpu-proofs-2026-10-08.json) records source/implementation/report hashes. Protected case directories retain recovery data and negative evidence. The runner correlates generic guest errors with a specific Trustee denial beside a request from that guest IP since pod creation. A bare startup failure or unrelated peer error cannot pass.

Trustee's Operator replaces the complete pod template and removes `oc rollout restart` annotations. The maintained refresh command verifies deployment/ReplicaSet ownership, replaces identified pods with UID preconditions and normal termination, then verifies new Ready UIDs, mounted ConfigMap versions and collateral/resources. Never infer resource refresh from an event or fixed sleep. On failed restoration, inspect protected recovery files and the namespace lock before removing it; do not overwrite a concurrent change or clear finalizers blindly.

Installed-node, ordinary-pod and confidential-guest fresh TCP/DNS probes passed, with trusted private registry TLS/401 as positive control. A guest calibration substituted the reachable private registry and correctly exited 42. Guest `ExecProcessRequest` was denied; startup exit probes retained that agent restriction. Guest stdout was empty; no cause is asserted. Temporary diagnostic/retained incomplete-control pods were preserved locally and removed. Provider iPXE fetched tokenized public boot artifacts before the private-only Agent OS; fully private delivery from power-on is not established. The published copies/nginx stanza were removed and port 8080 was closed; protected source assets and kubeconfig remain.

The update graph is unreachable as expected in this isolated cluster. CVO's next-minor `Upgradeable=False` is the 4.21 Sigstore-release-signature AdminAck gate, not a failing current payload. No acknowledgement or upgrade was performed. Existing customer upgrade, separate Trustee trust domain, encrypted images, Intel and GPU validation are outside these demonstrated results. A clean setup repeat is still required before claiming reproducible installation.

Automatic retirement was disabled at owner direction on October 8. Fresh read-back at 19:18 UTC confirmed the timer/service remain masked and inactive and private deadline fields are unset. The former 19:38:10 UTC deadline is not armed; do not restore it without a new explicit instruction. At 19:21 UTC, both `pricing.unit_price` values were €0.53/hour before extras (€1.06/hour total). `price_total` is accrued billing: node €2.10 plus helper €1.58 at that check; it is not an hourly-rate increase or a final invoice. The overall $150 cap remains and no provider-side cap exists.

For owner-authorized manual retirement, preserve unique signing keys/passwords, public verification material, CA/server identity, registry control artifacts and diagnostics in protected storage first. Use `control.py cleanup-plan`, then `cleanup` through the interactive shell that loads the API key. It deletes only the two exact task servers, verifies absence, then retires the task SSH key/project. Cherry deletion has not yet been exercised. No recharge settings or pre-existing project changes were made.

## Decision log

### Decisions

Keep one hourly Genoa node and its mirror/admin helper as the test environment. Real private VLAN/LACP networking resolved the prerequisite that failed at Latitude. Connected preparation and firmware/BMC boot delivery are recorded separately from private Agent/RHCOS/pod/guest operation. The manual BIOS step is accepted; no engineering engagement or BIOS API licence is required for the demonstrated path.

Repairs were driven by live failures: curl/curl-minimal conflict, separate firewalld operations, malformed mirror-registry 2.0.12 leaf with strict-valid rotation preserving CA/key, helper API mapping before installer wait, bundle-lookup OLM provenance, accepted-request resume, Operator-safe Trustee refresh, exact runtime command line and attributable policy/signature error matching. Default customer configuration remains Restricted. The trial's stronger EAR enforcement within Permissive is explicitly scoped to disposable lab validation.

Unused untracked scripts/tests for the discontinued public-routed workaround were backed up with hashes under protected `abandoned-public-experiment` state and removed from the checkout. Historical evidence remains labelled. Public receipts contain identifiers, hashes and outcomes; credential-bearing assets/logs remain protected.

### How to drive it

The combined proof run passed with cleanup/lock release verified. Rehearse a clean CoCo software reset/reinstall on this disposable platform, preserving inputs and unique helper state first. A software reset is distinct from a second fresh OCP/physical-infrastructure installation; report that limit. Recheck host SNP, exact CSV/runtime identities, configuration serving and isolation after reinstallation. Update this complete runbook and the dated receipts at material checkpoints. Keep the draft PR's validation and remaining acceptance aligned with the live state; do not present the lab as a customer upgrade or full separate-trust-domain deployment.
