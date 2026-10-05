# Latitude validation of the current release

## Status and scope

**Raw-host SNP passed on the Miami replacement; OpenShift and guest proofs remain pending.** [Dated preflight evidence](validation/latitude-preflight-2026-10-05.json) records the completed preparation checks and their limits. Sequential hardware candidates are authorized under the approved $150 total cap. Authenticated artifact resolution, actual image mirroring, registry TLS and DNS checks completed. An unchanged preparation rerun passed with zero changes and skipped transfer. Signed-image host verification accepted the signed control and rejected the same-content unsigned control for a signature-specific reason; guest enforcement remains untested.

Installer artifacts were generated successfully. PXE publication initially failed because nginx could not traverse the private installer directory. Moving the public copies to `/var/www/coco-boot-artifacts` passed the nginx read check, public HTTP 206 Range check and root-path 404 check. A repeat run reused the artifacts. Cleanup removed the webroots and boot configuration, closed port 8080 and made the tokenized endpoint unreachable. These checks used SELinux Permissive and did not boot the node.

A [later live cleanup check](validation/latitude-pxe-cleanup-2026-10-05.json) exercised both entry points
and a deliberately failed Ansible readiness probe. Rescue returned failure and closed the endpoint;
private installer files and artifact hashes/mtimes were preserved. Protected source metadata remained
root-owned with a `0700` directory and `0600` file. SELinux enforcing mode remains unverified.

The first Dallas allocation delivered EPYC 7313P / H12SSW-NTR / BIOS 2.3 instead of the advertised EPYC 9124. Its saved settings did not produce RMP reservation or working SNP, and the exposed-menu sweep found no RMP coverage control. The node was destroyed and provider deletion verified. The [firmware investigation](amd-firmware-preflight.md) retains the failed result and its limits.

The [Miami replacement](validation/latitude-mia2-host-2026-10-05.json) delivered EPYC 9124 / H13SST-G / BIOS 1.6. After enabling the five required controls, it retained UEFI and passed the raw-host check: RMP allocation, SNP API 1.55 build 24, `/dev/sev` and `sev_snp=Y`. A recovered initialization retry is retained in the evidence. This is a functional lab acceptance; the old firmware remains below published security fixes and does not establish a current secure customer baseline.

The first Miami bastion completed image mirroring and local DNS preparation, but the node cannot reach it over the private VLAN. A [dated network check](validation/latitude-mia2-network-2026-10-05.json) records failed ARP on two VLANs, matching provider/NIC identities and unsuccessful assignment recovery.

A second Miami bastion completed [fresh-bootstrap validation](validation/latitude-fresh-bootstrap-2026-10-05.json): uploaded-key SSH works, the user password stays locked, all cloud-init module error lists are empty, and the mirror readiness marker and Quay service passed. A recoverable provider metadata warning is retained. The third-host comparison also failed private traffic, including between the two bastions in the same rack. Full release mirroring did not run on this second host; it was retired after preserving its evidence. The first Miami host retains its earlier cloud-init user-module error. A medium-class comparison disappeared from the provider inventory before deployment completed; its exact API GET returned 404. The cause is unknown. Its remaining firewall, user data and VLAN were removed and absence verified. The accepted AMD node and first Miami bastion remain.

The Dallas bastion's unique artifacts were backed up and cryptographically verified; Terraform destroy completed, and an exact-server API GET returned 404. No new OpenShift installation or guest proof has completed; earlier July results remain historical evidence. This run targets disposable AMD SEV-SNP CPU infrastructure. Customer upgrades, separate-cluster topologies, Intel and GPU work require separate validation.

The [public-route feasibility check](validation/latitude-mia2-public-route-2026-10-05.json)
passed trusted registry TLS from the accepted node and cluster-manifest generation with the
pinned OpenShift installer. The explicit [public-routed lab profile](public-routed-lab.md)
is a candidate workaround for product tests. Boot, public service controls and installed-node
connectivity remain unverified; it cannot establish private-network or disconnected acceptance.

A separate [live Chrony repair](validation/latitude-mia2-chrony-2026-10-05.json) fixed a missing
include that prevented the prepared bastion from serving NTP. The private-source local positive
control passed, both public-source controls were denied, and the unchanged rerun made zero
changes. This does not establish a working node-to-bastion private path.

## Inputs required before provisioning

1. Verify [the resolved BOM](../install/release-manifest.json), using [the resolution procedure](release-resolution.md) when refreshing pins: immutable catalog and bundle identities, exact CSVs/channels, related images and helper images. `python3 scripts/verify-release.py --require-resolved` must pass.
2. Confirm access to the Latitude project and current stock for the selected site/plan, the intended SSH key, billing mode, admin CIDR and firmware access. Record server IDs once provisioned; do not assume old IDs still exist.
3. Select a **versioned HTTPS mirror-registry archive and its published SHA-256**. Set `mirror_registry_url` and `mirror_registry_sha256` in the bastion inputs. Both are required; there is no `latest` or unchecked fallback. The current run has verified mirror-registry 2.0.12 against the published SHA-256; the bastion guide records the pin and host prerequisites.
4. Keep the Red Hat pull secret, provider credential, SSH keys and any later kubeconfigs in private external storage. The wrapper accepts `COCO_BASTION_TFVARS` and `COCO_NODE_TFVARS` as absolute file paths; never put secret-bearing files or state under Homelab.
5. Complete an external Ansible environment file with reviewed networking, disk, NIC and boot-token inputs as described in [the quickstart](current-quickstart.md).

Select by the exact CPU and firmware, not just Latitude's “Gen 4” family label. Its
[public catalog](https://www.latitude.sh/pricing) currently lists `m4.metal.medium`
with EPYC 9124 and `m4.metal.large` with EPYC 9254; these are candidates to check against
the selected Red Hat support matrix and required capacity. Other similarly named plans
use different CPU families. Public listings do not establish account stock, enabled SNP,
firmware access or the final infrastructure price. Confirm those before creating servers.

## Plan and provision in stages

Qualify the actual node before building a new mirror bastion. The node module supports a standalone
provider OS with `air_gap=false`; it does not need a bastion for firmware checks. Set the external
node inputs to the intended project/site/plan, `operating_system="rocky-10"`, `air_gap=false`,
`create_ssh_key=false` and the verified existing `ssh_key_ids`. Keep the provider credential in
`LATITUDESH_AUTH_TOKEN`.

```bash
export COCO_STATE_DIR="$HOME/.local/state/openshift-confidential-containers"
export COCO_BASTION_TFVARS="$COCO_STATE_DIR/bastion.tfvars"
export COCO_NODE_TFVARS="$COCO_STATE_DIR/node.tfvars"
umask 077
mkdir -p "$COCO_STATE_DIR"

# After filling and reviewing the external input files and resolving the BOM:
python3 scripts/verify-release.py --require-resolved
export COCO_NODE_STATE_DIR="$COCO_STATE_DIR/terraform/node"
mkdir -p "$COCO_NODE_STATE_DIR"
chmod 700 "$COCO_NODE_STATE_DIR"
export TF_DATA_DIR="$COCO_NODE_STATE_DIR/data"
terraform -chdir=infra/latitude init -input=false
terraform -chdir=infra/latitude plan \
  -state="$COCO_NODE_STATE_DIR/terraform.tfstate" -var-file="$COCO_NODE_TFVARS" \
  -out="$COCO_NODE_STATE_DIR/candidate.tfplan"
terraform -chdir=infra/latitude show "$COCO_NODE_STATE_DIR/candidate.tfplan"
# After reviewing the candidate plan:
terraform -chdir=infra/latitude apply \
  -state="$COCO_NODE_STATE_DIR/terraform.tfstate" "$COCO_NODE_STATE_DIR/candidate.tfplan"
terraform -chdir=infra/latitude output -state="$COCO_NODE_STATE_DIR/terraform.tfstate"
```

`TF_DATA_DIR` moves provider metadata, **not local state**. Every direct plan, apply, output and
destroy must select the same external state; applying a saved plan also needs `-state`.
If any state appears in the checkout, stop and reconcile its resource IDs and lineage before
continuing. Do not create a second state to manage the same server.

Match the returned server ID to SSH and the console, then complete [AMD firmware preflight](amd-firmware-preflight.md).
For a rejected candidate, retain its evidence and review a destroy plan using that same state and
input file. Apply the saved destroy plan with `-state`, and confirm the exact server is absent
from the provider before trying another allocation. Track cumulative cost, including deleted
candidates and any temporary overlap, against the total budget.

For an accepted candidate, retain its existing node state and unchanged server identity. Select
a bastion in the **same site**, then plan its infrastructure:

```bash
bash ansible/up.sh --mode prepare --plan-tf
```

The modules select Latitude provider 4.6.0 with committed lock files and `allow_reinstall=false`. If an existing checkout still has a 3.3 lock selection, update its provider installation with `terraform init -upgrade` using the same external `TF_DATA_DIR`, then review the new plan. A cloud-init change that requires a bastion reinstall must fail rather than silently replace its OS; handle that replacement as a separate deliberate operation.

Inspect the plan for the intended project, site, machine, VLAN, firewall and billing. A plan is not an apply. The wrapper's `--plan-tf` runs no Ansible tasks. Terraform init may download providers and planning may read provider state, but neither should provision resources.

Provision the bastion before enabling the node's VLAN dependency. Once the bastion plan is acceptable:

```bash
bash ansible/up.sh --mode prepare --apply-tf -e "@$COCO_STATE_DIR/rig.yml"
# Set air_gap=true in the SAME node input file, retaining its existing server inputs/state.
# The bastion state now permits the node's VLAN/firewall dependency to resolve.
bash ansible/up.sh --mode fresh-install --plan-tf
```

The node plan should preserve the accepted server and add only the intended VLAN and optional
firewall assignments. Investigate a replacement or reinstall instead of applying it. Keep the
provider OS input unchanged; Ansible's journaled installation step requests the later netboot.

If preparation stops because its new-host inputs are incomplete, preserve the external Terraform state, correct the inputs, and rerun preparation. Do not create a second state directory for the same project resources. Pull-secret staging accepts `pull_secret_src` from the external Ansible file. Check the bastion's `MIRROR_READY`/`MIRROR_FAILED` result and its protected bootstrap logs before retrying a failed bootstrap.

### Prove the private link before reinstall

Apply only the reviewed node infrastructure changes while its provider OS is still available.
Save and inspect the plan using the **same existing node state**; it must preserve the server and
change only the intended assignments. This does not run Ansible or request a provider reinstall:

```bash
export TF_DATA_DIR="$COCO_STATE_DIR/terraform/node/data"
terraform -chdir=infra/latitude plan \
  -state="$COCO_STATE_DIR/terraform/node/terraform.tfstate" -var-file="$COCO_NODE_TFVARS" \
  -var="bastion_state_path=$COCO_STATE_DIR/terraform/bastion/terraform.tfstate" \
  -out="$COCO_STATE_DIR/terraform/node/private-link.tfplan"
terraform -chdir=infra/latitude show "$COCO_STATE_DIR/terraform/node/private-link.tfplan"
# Apply only after confirming the server is unchanged:
terraform -chdir=infra/latitude apply \
  -state="$COCO_STATE_DIR/terraform/node/terraform.tfstate" \
  "$COCO_STATE_DIR/terraform/node/private-link.tfplan"
```

Before proceeding, retain these checks in private external evidence:

1. Match the current server ID and discovered private MAC to the actual node interface, and
   confirm both hosts' assigned network ID, VID and facility. Inspect `ip -d link` and select the
   private parent explicitly; do not assume an interface name. Record the existing public routes
   and resolver configuration.
2. On the raw node, temporarily configure the intended private address/prefix on that parent's
   VLAN. Use a dedicated NetworkManager profile with `connection.autoconnect no`,
   `ipv4.never-default yes`, `ipv4.ignore-auto-dns yes`, no gateway or DNS servers, and IPv6
   disabled. Inspect any existing profile before reusing it. Confirm public routes, resolver
   configuration and SSH remain unchanged.
3. From the **node**, prove ARP resolution to the bastion and reach the mirror by its certificate
   hostname using the correct CA obtained over verified bastion SSH; do not disable TLS
   verification. Query the bastion's DNS directly and make an NTP query without changing the
   node's clock or persistent time configuration. Confirm the expected DNS answers and an NTP
   response. An unauthenticated registry `/v2/` response of 401 can prove the TLS path, but does
   not prove an authenticated image pull.

Once the temporary VLAN profile is active, run the repository's
[read-only checker](../scripts/check-private-link.py) **on the raw Linux node** with Python 3 and `ip`
already installed. It needs sudo/root or the Linux network capabilities required for
`SO_BINDTODEVICE`; it fails if interface binding is unavailable or denied. Copy the script and
correct public CA there over verified SSH first. Replace
every placeholder with the reviewed values; the interface is the VLAN child, not its parent:

```bash
sudo install -d -m 0700 -o root -g root /root/coco-private-link-evidence
sudo python3 /path/to/check-private-link.py \
  --interface '<private-vlan-interface>' --vid '<VID>' \
  --node-ip '<intended-node-private-IPv4>' --bastion-ip '<bastion-private-IPv4>' \
  --mirror-hostname '<mirror-certificate-hostname>' --mirror-port 8443 \
  --ca-file /path/to/verified-mirror-ca.pem \
  --evidence /root/coco-private-link-evidence/result.json
```

The checker requires an existing owner-only evidence directory owned by its executing account
(root in this example) and writes JSON with mode `0600`.
It checks the VLAN, address and direct route before and after bounded probes; every UDP and TLS
socket binds to the reviewed interface and node address before connecting, with no unbound fallback.
After allocating each socket's source port, it checks that exact protocol/port flow's route is
direct on the reviewed interface. Unsupported iproute2 flow selectors fail the check without fallback.
DNS must return the mirror's direct A record pointing to the bastion. It changes no addresses,
routes, resolver settings or clock. Run it while networking is stable. A zero exit status proves these raw-host private-service
checks only, not an image pull, network enforcement or installed RHCOS behavior. This remains a
useful standalone check. Before each new reinstall request, the installer also runs a fresh
checker invocation on the raw provider OS; it never substitutes a cached PASS.

For that enforced check, set `raw_node_ssh_user`, `raw_node_ssh_key`, `bastion_ssh_key` and
`private_link_known_hosts` in the external Ansible input file. Key and known-hosts paths are
absolute controller paths outside the checkout. Verify both hosts' SSH keys before populating
the dedicated known-hosts file; the gate neither enrolls new keys nor disables host verification.
The raw SSH address comes from the current provider response, and sudo must work noninteractively.
If provider-OS NIC naming differs from the rendered name, set the machine's `raw_parent_if`;
its MAC must still match the current provider and prepared installer identities. The gate copies
only the checker and public CA, verifies that CA against the prepared installer trust, preserves
attempt evidence under `$COCO_STATE_DIR/validation/private-link`, and removes its temporary files.
It does not configure the VLAN or install missing packages. The supported gate topology is this
Latitude rig's mirror/DNS/NTP bastion; differing service endpoints require separate validation.

An accepted request for the same artifact revision resumes installation without raw-host SSH.
An ambiguous request still requires provider inspection and explicit retry; a retry must pass
a fresh check before another POST. Changed inputs also require the existing reinstall override
and fresh raw-host proof. A failed check records no new reinstall intent and preserves existing
journals. It closes published boot files only when no accepted or ambiguous request can need them.

**Stop before reinstall if any private-path check fails.** Provider `connected` status, a local
bastion DNS check or `MIRROR_READY` alone cannot pass this gate. Retain ARP state, interface/VID
details and the exact TLS/DNS/NTP errors in protected logs; a routing, DNS or TLS failure is not
an enforcement denial. The [Miami network evidence](validation/latitude-mia2-network-2026-10-05.json)
shows this boundary. Remove only the temporary diagnostic profile when it is no longer needed.

After this gate and [AMD firmware preflight](amd-firmware-preflight.md) pass for the actual
delivered board, UEFI boot path, firmware security fixes and raw-host SNP result, put the current
bastion IP, VLAN VID and server ID in the external Ansible file and start installation:

```bash
bash ansible/up.sh --mode fresh-install -e "@$COCO_STATE_DIR/rig.yml"
bash ansible/up.sh --mode verify -e "@$COCO_STATE_DIR/rig.yml"
```

Infrastructure is already applied, so this fresh-install invocation omits `--apply-tf`. Temporary VLAN preparation and firmware review remain manual; fresh install enforces private-link proof before a new provider request and retains its BIOS gate. The provider reinstall step compares the returned machine ID with the requested ID, persists request intent before sending it, and does not repeat an accepted request for unchanged inputs. If a request fails ambiguously, inspect the provider before any retry.

The wrapper passes non-secret Terraform outputs into Ansible after apply. When using already provisioned machines without `--apply-tf`, supply their current bastion IP, VLAN VID and server ID in the external Ansible file.

## Acceptance evidence

Save each run's dated evidence outside the repository. Report **PASS**, **FAIL**, or **INCOMPLETE** per checkpoint; failed connectivity or missing prerequisites do not count as denial proofs.

| Checkpoint | Evidence required |
|---|---|
| Identity and release | Git commit, resolved BOM digest, project/site/server IDs, firmware state, actual OCP version and payload digest, operator CSVs and related-image digests. |
| Bootstrap reliability | Tool hashes; a repeated unchanged run reuses artifacts; a changed input triggers the relevant mirror/PXE work; no unsupported fallback. Record first-run timings and intervention count. |
| Offline image path | Successful mirror, generated/applied mirror resources, target registry reachability, workload pulls through the mirror, and observed node egress policy. A local `MIRROR_READY` file alone is insufficient. |
| Network enforcement | Effective host rules and any provider-agent status; allowed/denied traffic from the node host, Trustee and relevant workload/guest contexts; private mirror/DNS/NTP controls; repeat after reinstall/reboot. An API assignment or failed `curl` alone is insufficient. |
| Runtime | Target CPU capability, RuntimeClass `kata-cc` resolving to handler `kata-snp`, hardware-backed guest launch, and selected node identity. |
| Trustee | Exact Operator/CR schema; generated resource ownership and readiness; preserved signer identity; required TLS; approved default-deny policy and target RVPS/collateral identity. |
| Security behavior | Fresh positive control, one isolated mutation, attributable denial, restoration, and a new successful control for KBS, initdata, RVPS and signed-image proofs. |
| Missing collateral | Denial without the approved endorsement material, then recovery after restoring it. Separately demonstrate the network egress constraint. |
| Resource behavior | Actual guest memory/CPU settings, cold and warm start times, and node allocatable impact. Larger memory defaults are a workaround until measured on the selected payload. |
| Cleanup | Proof resources restored/removed; secret-bearing boot endpoint unreachable; saved evidence contains no credentials; provider inventory confirms intended teardown. |

Keep `enforce_latitude_firewall=false` for this RHCOS path: it only selects an API assignment,
and the repository does not install or verify Latitude's host agent. If assessing that service
separately, inspect its effective API and host rules, including the automatic SSH rule omitted
from Terraform state. The existing egress MachineConfig filters host `OUTPUT`; host probes do
not establish pod/guest isolation. Record fresh public-connection denials attributable to the
enforcement layer and successful private-service controls; distinguish DNS/TLS/routing failures.
See [firewall and egress limits](../infra/latitude/bastion/README.md#firewall-assignment-and-network-enforcement).

Do not promote encrypted-image or GPU support based on these CPU results. Any encrypted-image experiment must separately prove key wrapping, pull/decrypt/execute, attributable denial and recovery on the actual selected guest payload. The default acceptance gate excludes it.

## Close the endpoint and tear down

The successful wrapper closes its PXE endpoint. If a run stops early, use the explicit `pxe-stop` command in [the quickstart](current-quickstart.md#prepare-install-verify) once the node no longer needs the assets, and verify the old boot URL is unreachable without copying its token into shared evidence.

Keep state until provider cleanup is verified. Destroy the node first because it depends on the bastion's VLAN. Review destroy plans before applying them; the following commands explicitly destroy the disposable rig:

```bash
TF_DATA_DIR="$COCO_STATE_DIR/terraform/node/data" terraform -chdir=infra/latitude destroy \
  -state="$COCO_STATE_DIR/terraform/node/terraform.tfstate" \
  -var-file="$COCO_NODE_TFVARS" \
  -var="bastion_state_path=$COCO_STATE_DIR/terraform/bastion/terraform.tfstate"
TF_DATA_DIR="$COCO_STATE_DIR/terraform/bastion/data" terraform -chdir=infra/latitude/bastion destroy \
  -state="$COCO_STATE_DIR/terraform/bastion/terraform.tfstate" \
  -var-file="$COCO_BASTION_TFVARS"
```

Confirm the target servers and their rig-only assignments are absent in provider inventory and billing. A failed SSH connection is not teardown evidence. Retain the sanitized run record and remove sensitive temporary artifacts according to the environment's retention policy.
