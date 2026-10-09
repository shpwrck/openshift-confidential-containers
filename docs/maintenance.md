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
Use [Trustee setup](trustee-current.md), preserve CPU/hardware checks, and run the
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

This removes CoCo Operators and operands on an existing co-located lab, retaining
OpenShift, the mirror and provider allocations. It may reboot the node. Back up
Trustee configuration, Secrets, collateral, signing identities and proof evidence first.

Confirm identical `WORKER_CONTEXT`/`TRUSTEE_CONTEXT`. Every existing target namespace
must already carry `coco.openshift.io/disposable=true`: the workload namespace,
`trustee-operator-system`, `openshift-sandboxed-containers-operator`, `openshift-nfd`,
`cert-manager-operator`, `cert-manager`, and `openshift-gatekeeper-system`.
Mark only namespaces deliberately owned by the disposable test.

```bash
TRUSTEE_LAB=1 ALLOW_DISPOSABLE_UNINSTALL=1 make uninstall-coco
make validate-coco-uninstalled
make validate-sno-baseline
```

The reset retains controllers until their operands finish deletion. If it stops,
inspect finalizers and reconciliation before retrying; do not clear them blindly.
Reinstall through [the quickstart](current-quickstart.md#install-coco-and-trustee),
recollect current collateral, reconfigure Trustee and rerun all proofs/isolation.
`make test-rung WHICH=all` runs fresh proofs; reset/reinstallation is separate.

## Retire the infrastructure

Close boot publication once no accepted install needs it. Back up keys, registry
configuration, installer assets, Trustee state and evidence outside Git. Verify
archive hashes and recovery limits before deleting resources.

Delete only the intended provider objects and confirm absence through fresh inventory
reads. Power-off or failed SSH is not proof of deletion. Keep the provider ownership and retirement records.
The [Cherry leave-behind](runbooks/cherry-qualification/README.md) records the completed
trial's retirement and protected backups; it is not a credential set for a new rig.
