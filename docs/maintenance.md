# Maintenance

Operate only the selected environment, with explicit cluster contexts and
protected external state. These helpers are not a production backup or upgrade service.

## Collateral and references

Recollect VCEK material after firmware/TCB changes or allocation changes. An unchanged
HWID alone does not establish that an older certificate matches the current TCB.
The collector records source identity, certificate validity and hashes.

```bash
make collect-vcek NODE='<actual-worker>'
```

If the worker is disconnected, transfer the collected URL bundle to a connected
controller and run `scripts/collect-vcek.sh --download`. For a raw SNP report, use
`--from-report <report-file>`. Carry the reviewed bundle back through the approved
transfer process. Publish separately with an explicit Trustee context:

```bash
make seed-vcek
```

Use `VCEK_BUNDLE` for the protected bundle path. Bootstrap/configure Trustee after
publication so the correct worker cache entries are mounted. Check expiry and the
current host/TCB before reuse; collection does not renew collateral automatically.

Recalculate launch references after guest/release/runtime command-line changes.
Rebind initdata after any byte change, including policy or certificate changes.
Use [Trustee setup](trustee.md), preserve CPU/hardware checks, and run the
relevant positive/negative/recovery proofs. Reference expiry is deliberate;
extending it requires renewed review, not a documentation date change.

## Configuration refresh

Use `scripts/apply-trustee.sh configure` for approved policy/reference/resource changes.
It waits for actual serving configuration. After a separately applied CPU ConfigMap,
refresh with the actual names:

```bash
python3 scripts/refresh-trustee.py --context "$TRUSTEE_CONTEXT" \
  --namespace trustee-operator-system --trustee-name trustee-config
```

The refresh verifies ownership, replacement pod UIDs and current mounts. Changing
a ConfigMap or running `oc rollout restart` alone does not prove that Trustee serves it.
TLS/signer rotation and pruning resource references require their own reviewed
procedure; configure does not perform those operations.

## Reset a disposable CoCo lab

This puts the test rig back to plain OpenShift: it removes the CoCo Operators,
Trustee, the test workloads and the Kata runtime, and keeps OpenShift, the mirror,
the servers and `$COCO_STATE_DIR`. Back up any Trustee configuration, Secrets and
proof evidence you want to keep first. In a terminal where you ran
`source scripts/env.sh` after [`make connect`](quickstart.md#5-install-the-coco-operators):

```bash
make reset-lab
```

It shows the context, the API address, the node and every namespace it deletes,
and asks you to type `reset`; without a terminal, approve ahead with
`ALLOW_DISPOSABLE_UNINSTALL=1 make reset-lab`. Then it marks those namespaces with
`coco.openshift.io/disposable=true`, removes the stack, waits until everything is
gone and checks the cluster again, in about 10 minutes. Removing the Kata runtime
reboots the node, so a watch error or two while the API is down is expected. The
removal check prints `Waiting:` for what is left meanwhile; `FAIL:` only appears
if it times out.

`make reset-lab` refuses to run without the lab settings from `lab.env`
(`TRUSTEE_LAB=1` and the same context for workloads and Trustee). On any other
cluster, use `make uninstall-coco` directly: it removes only namespaces that
already carry the disposable label, so label only namespaces the test owns.

The reset keeps each controller until its operands finish deletion. If it stops,
inspect finalizers and reconciliation before retrying; do not clear them blindly.
Reinstall with `make install-coco-operators`, then run `make trustee-lab`,
`source scripts/env.sh` and `make test-rung WHICH=all` again
([Trustee setup](trustee.md#disposable-lab), [capability tests](capability-status.md)).
The signing key pair in `$COCO_STATE_DIR` from the first build is used again.
`make test-rung WHICH=all` runs fresh proofs; it does not reset anything.

## Retire the infrastructure

Close boot publication once no accepted install needs it. Back up keys, registry
configuration, installer assets, Trustee state and evidence outside Git. Verify
archive hashes and recovery limits before deleting resources.

Delete only the intended provider objects and confirm absence through fresh inventory
reads. Power-off or failed SSH is not proof of deletion. Keep the provider ownership and retirement records.

If you ordered with `make order-rig`, Terraform deletes exactly the servers it
created, and the SSH key if it added one; a key your account already had stays.
Run this in a terminal where you ran `source scripts/env.sh`. The plan lists the
two servers; type `yes` to delete them, then confirm in the Cherry portal or API
that both servers are gone:

```bash
terraform -chdir=infra/cherry destroy -var-file="$COCO_STATE_DIR/cherry.tfvars"
```

A script that cannot type `yes` adds `-auto-approve` instead. Then stop the
`make connect` tunnel to the deleted helper: `pgrep -af '^ssh .*-L 127.0.0.1:6443'`
shows its process ID, and `kill <ID>` stops it.
