# Troubleshooting

Start with the last successful checkpoint. Keep logs and recovery files in protected
external storage; they can contain credentials or workload data. Use explicit worker
and Trustee contexts, and correlate the same pod UID/IP and time window across logs.

## Installation

| Symptom | Check and next action |
|---|---|
| Raw-host SNP fails | Use [firmware preflight](amd-firmware-preflight.md). Check actual board, kernel and RMP evidence; do not guess from one PSP code. |
| Helper ready but node cannot reach it | Keep the raw provider OS. Verify VLAN wire tag, actual NIC/bond members, direct route, ARP, registry TLS, DNS and NTP from the node. |
| Registry TLS fails | Check hostname/SAN, validity, server leaf/intermediates and trusted CA. Keep verification enabled. Preparation can repair the known malformed mirror-registry leaf while preserving its CA/key. |
| Mirror transfer fails | Check external auth, disk space and exact selected ImageSet. A completion marker only applies to unchanged inputs. |
| Install wait cannot find API | Verify `api`/`api-int` DNS from both node and helper before diagnosing payload health. |
| Rebuild result is ambiguous | Inspect provider state and the protected request journal before retrying. Do not regenerate assets to erase the request. |
| Controller stopped after accepted rebuild | Use `--mode resume-install` with unchanged inputs and accepted journal. It sends no new rebuild. |
| CSV/InstallPlan mismatch | Compare actual catalog, CSV, bundle digest and `bundleLookups` with the release manifest; do not approve an unrelated plan. |
| MCP degraded or runtime wrong | Stop the rollout. Inspect MCO/operator logs and NFD labels; `kata-cc` must use `kata-snp`. Do not hand-label hardware to hide discovery failure. |

Provider request journals normally live at helper `/opt/install/provider-requests`,
outside replaceable assets. Reusing an existing cluster's assets with changed inputs
requires a deliberate reinstall or a new assets directory; it is not an upgrade.

Boot publication uses `/var/www/coco-boot-artifacts`, separate from the private
`/opt/install` source/assets. Keep private directories/files at `0700`/`0600`.
Once no accepted request needs the files, close publication after an interrupted run:

```bash
ANSIBLE_CONFIG="$PWD/ansible/ansible.cfg" ansible-playbook \
  ansible/playbooks/site.yml --tags pxe-stop -e "@$COCO_STATE_DIR/rig.yml"
```

Confirm the old endpoint is unreachable without printing its token. Only the qualified private-network path is supported.

## A confidential workload will not start

Check pod/admission events, then Trustee and registry logs for the same attempt.
A `DeadlineExceeded` or `ttrpc` message alone does not identify the failed component.

```bash
oc --context="$WORKER_CONTEXT" -n coco-validation describe pod '<pod>'
oc --context="$WORKER_CONTEXT" -n coco-validation get events --sort-by=.lastTimestamp
oc --context="$TRUSTEE_CONTEXT" -n trustee-operator-system \
  logs deploy/trustee-deployment --all-containers --since=30m
oc --context="$WORKER_CONTEXT" get nodes,mcp,runtimeclass
oc --context="$WORKER_CONTEXT" get csv -A
```

Replace namespace/deployment names with the actual objects. Then locate the stage:

| Evidence | Investigate |
|---|---|
| Admission denial; pod never created | Gatekeeper/API caller or owning controller events. Shipped CoCo workloads need `coco-resource-default: "true"` for the memory guard. |
| QEMU exits or host OOM | Guest-memory annotation versus pod limits, node capacity and host CRI-O/kubelet logs. An explicit undersized limit is not fixed by a missing-value mutation. |
| No Trustee request | Delivered initdata, KBS URL/CA, DNS/network and agent policy. Keep `aa.toml` and the exact annotation key. |
| Attestation rejected | Selected worker VCEK/TCB, offline cache, launch references and verifier error. |
| Attestation succeeds but resources fail | Token signer/trust for token errors; resource policy and appraisals for policy denial. Verify every URI referenced by initdata. |
| Resources succeed but registry sees no pull | Guest remaps, pause/app image paths, DNS and registry trust. Host mirror rules do not configure the guest. |
| Registry authentication fails | Credential entry keyed to the remapped host, repository existence/access and refreshed resource mounts. |
| Manifests/blobs arrive but workload fails | Unpack/memory, effective runtime timeouts and guest policy. Keep default administrator exec denied. |

See [guest registry access](guest-images.md) for CA chains and Artifactory. Discover
host configuration from the installed runtime before reading logs; do not edit
MCO-managed files to make an experiment pass. The narrow
`make repair-sno-baseline NODE='<node>'` helper handles only the explicitly diagnosed
`/etc/kubernetes/kubelet.conf` content mismatch, with a backup and baseline recheck.

## Failed proof or stale configuration

A matching negative must include a working positive control. DNS, registry auth,
missing image or unrelated Trustee errors cannot prove enforcement. A generic CDH
error needs a specific denial for that guest in the matching window.

On interrupted restoration, inspect the proof's external recovery files, namespace
lock and actual object versions. Preserve concurrent changes. Use
[the checked refresh](maintenance.md#configuration-refresh) to prove the restored
ConfigMaps/resources are served before recovery. Do not rerun a stale PASS.

## Collect diagnostics

Collect pod events, exact payload/CSV/runtime identities, node CRI-O/kubelet logs,
Trustee logs and matching registry requests. Use the selected must-gather identities
from the manifest so the mirrored images match this release:

```bash
OSC_GATHER="$(python3 scripts/verify-release.py --get images.oscMustGather.ref)"
oc --context="$WORKER_CONTEXT" adm must-gather --image="$OSC_GATHER" \
  --dest-dir="$COCO_STATE_DIR/diagnostics/osc"
TRUSTEE_GATHER="$(python3 scripts/verify-release.py --get images.trusteeMustGather.ref)"
oc --context="$TRUSTEE_CONTEXT" adm must-gather --image="$TRUSTEE_GATHER" \
  --dest-dir="$COCO_STATE_DIR/diagnostics/trustee"
```

Recheck host, ordinary-pod and guest isolation after reboots/rollouts, with private
positive controls. A failed host curl or a firewall service's active state alone
does not prove isolation at every layer.
