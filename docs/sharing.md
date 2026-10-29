# Share this repository

Use this page to explain the repository, demo it, hand it to someone else or
move it. Everything it says is backed by the [validation results](validation.md).

## Explain it

**In one sentence:** it builds a disconnected OpenShift cluster on AMD SEV-SNP
hardware, installs confidential containers, and proves on real hardware that
Trustee only releases secrets to VMs that are running the approved software.

**What a run proves**, each with a test that must allow the right workload and
deny a tampered one:

| Control | Test |
|---|---|
| Secrets reach a workload only inside a confidential VM | `rung-kbs` |
| A VM whose configuration (initdata) changed gets nothing | `rung-initdata` |
| A VM whose launch measurement is not approved gets nothing | `rung-rvps` |
| A VM runs signed images and refuses unsigned ones | `rung-signed` |
| A VM checked against a wrong AMD chip certificate gets nothing | `air-gap` |
| Neither the node, a pod nor the VM reaches the internet, and nobody can `exec` into the VM | `isolation` |

**What it does not prove:** encrypted images, Trustee in a separate cluster,
Trustee in Restricted HTTPS mode, upgrades, Artifactory, or a fully private boot.
Do not present these as tested. The lab runs Trustee next to the workloads, which
is a test layout, not a customer one; [customer planning](customer-planning.md)
lists what a customer deployment still needs.

## Demo it

On a rig that has finished [quickstart step 7](quickstart.md#7-run-the-capability-tests),
run single tests while you talk through them. Each takes a few minutes and prints
each control as it runs:

```bash
make proof-plan                    # list the tests
make test-rung WHICH=rung-initdata # tamper with the VM's configuration: refused, then restored
make test-rung WHICH=rung-signed   # an unsigned image: refused
make test-rung WHICH=isolation     # no internet from the node, a pod or the VM; exec refused
```

Each run writes a report to `$COCO_STATE_DIR/proofs/<run>/results.json`. The
OpenShift console is at the address that [step 4](quickstart.md#4-install-openshift)
prints. The [architecture](architecture.md) diagrams explain the attestation
exchange. Delete the rig after the demo; it bills by the hour.

## Hand it to someone

Someone new needs only this repository and the accounts in the
[quickstart checklist](quickstart.md#before-you-start): a Linux controller, a
Cherry Servers account, an SSH key and a Red Hat pull secret. A full run takes
about three hours. Nothing from an earlier rig carries over: each run collects its
own certificates and reference values and produces its own evidence.

Give them, in order: the [README](../README.md), the [quickstart](quickstart.md)
and, for questions about scope, the [validation results](validation.md).

## Move or copy it

Nothing in the repository names its own GitHub location, so it works from any
clone or fork. CI ([`offline-validation.yml`](../.github/workflows/offline-validation.yml))
needs no secrets and runs on every pull request. In a new home, turn on branch
protection for `main`, secret scanning and push protection.

## Change it

See [contributing](contributing.md) for the offline checks and CI. A change that
affects what runs on the hardware is only proven by a new full run; record that
run in [validation results](validation.md) and, for a new server plan, in
[`tested-plans.json`](../infra/cherry/tested-plans.json).
