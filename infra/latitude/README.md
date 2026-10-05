# Latitude AMD validation node

This module provisions the disposable AMD node. Start with `air_gap=false` to check the actual hardware before building the mirror. The [bastion module](bastion/README.md) owns the mirror server, VLAN and firewall API object; provision it in the same site before enabling `air_gap=true` on the accepted node. Both servers incur charges until deleted. Use an explicit total budget and verify teardown through provider inventory.

## Select and verify the machine

Check current project access, site stock, hourly rates, SSH keys and remote firmware access before applying a plan. Select by the actual CPU, board, firmware and boot capabilities. A marketed plan name is insufficient: the October 5 run requested `m4-metal-medium`, advertised as EPYC 9124, but received EPYC 7313P / H12SSW-NTR / BIOS 2.3. Its initial SNP checks failed. [Current evidence](../../docs/validation/latitude-preflight-2026-10-05.json)

The selected OSC matrix and functional hardware checks determine eligibility; do not reject a CPU solely because another historical rig used Genoa. Complete [AMD firmware preflight](../../docs/amd-firmware-preflight.md), including UEFI, RMP reservation, firmware security fixes and successful live SNP initialization. The historical H13 recipe is not a universal BIOS configuration.

## Provision with external state

Follow [the current quickstart](../../docs/current-quickstart.md) and [Latitude validation procedure](../../docs/latitude-validation.md). Keep the provider token in the environment and tfvars/state outside this checkout and Homelab. Copy the non-secret values from `terraform.tfvars.example` into the private external input file; do not create a secret-bearing `terraform.tfvars` here.

The wrapper uses separate `$COCO_STATE_DIR/terraform/bastion` and `terraform/node` directories and passes the bastion state path to this module. Review its plan for project, site, machine, billing, VLAN/firewall assignments and SSH identity before applying. Provider 4.6.0 is locked; implicit reinstallation is disabled.

Provisioning creates the initial provider OS. OpenShift installation later uses an explicit, journaled reinstall through Ansible. Neither an apply nor a BIOS acknowledgement proves that SNP works.

Keep `enforce_latitude_firewall=false` for the maintained RHCOS path. Its legacy name selects an API assignment only; the repository does not install or verify Latitude's host agent. VLAN membership also does not prove isolation. See [firewall and egress limits](bastion/README.md#firewall-assignment-and-network-enforcement) before claiming restricted inbound access or an air gap.

## Verify and clean up

Use the provider image's documented SSH user and run `scripts/host-snp-check.sh` with sufficient privileges on the node. A failed result requires diagnosis; it does not automatically establish a provider limitation. Repeat host verification under the installed RHCOS kernel before guest attestation and workload proofs.

Destroy the node first, then the bastion, using the same external state and input files. The [teardown procedure](../../docs/latitude-validation.md#close-the-endpoint-and-tear-down) includes the required commands and verification. Powering off a server or losing SSH connectivity is not evidence that billing stopped.
