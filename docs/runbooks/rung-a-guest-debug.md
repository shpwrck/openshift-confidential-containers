# Runbook — interactive in-guest debug of the rung-a air-gap pull

Goal: from an **interactive terminal** (you, a human — `kata-runtime exec` needs a real TTY, which
non-interactive automation can't provide), catch the confidential VM during a rung-a attempt and
read what image-rs/CDH/attestation is actually doing. Background + recipe:
[airgap-coco-guest-pull.md](../notes/airgap-coco-guest-pull.md).

## Already in place (verify, don't redo)
- Bastion `rocky@<BASTION_PUBLIC_IP>`; cluster reached from there:
  `KUBECONFIG=/opt/install/cluster-assets/auth/kubeconfig` (alias `oc='sudo env KUBECONFIG=$KUBECONFIG /usr/local/bin/oc'`).
- Initdata (full mirror remap incl. pause image) at `~/initdata-rig.b64` on the bastion.
- KBS serves `credential` + `security-policy`; OfflineStore VCEK mounted; CoreDNS forwards `rig.local`
  → bastion dnsmasq; node `create_container_timeout=600`, kubelet `runtimeRequestTimeout=20m`,
  kata `debug_console_enabled=true`. Air gap enforced (node egress to quay/KDS blocked).

## 1. Deploy rung-a (terminal A, on the bastion)
```bash
INITDATA=$(cat ~/initdata-rig.b64)
UBI=registry.access.redhat.com/ubi9/ubi-minimal@sha256:4ba37413a8284073eb28f1987fdf8f7b9cc3d301807cdd79e10ab5b98bd57a63
oc delete pod rung-a -n default --force --grace-period=0 2>/dev/null
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: rung-a
  namespace: default
  annotations:
    io.katacontainers.config.hypervisor.default_memory: "2048"
    io.katacontainers.config.hypervisor.cc_init_data: "$INITDATA"
spec:
  runtimeClassName: kata-cc
  restartPolicy: Never
  containers: [{name: app, image: $UBI, command: ["/bin/sh","-c","echo UP; sleep 600"]}]
EOF
```

## 2. Catch the CVM and exec into the guest (terminal B → interactive node shell)
```bash
oc debug node/sno-coco-node        # gives an interactive TTY
chroot /host
# wait for the sandbox, then exec the moment it appears:
while :; do SB=$(ps -ef | grep -oE 'sandbox-[a-f0-9]{64}' | sed 's/sandbox-//' | head -1); [ -n "$SB" ] && break; sleep 1; done; echo "SB=$SB"
kata-runtime exec "$SB"            # drops you into a bash shell INSIDE the confidential VM
```
If `kata-runtime exec` says "no such sandbox", the CVM was torn down — re-run the `while` loop; it
will catch the next attempt (one fires roughly every minute).

## 3. Inside the guest (note: minimal rootfs — bash builtins work; `ip`/`getent`/`timeout` may not)
```bash
# (a) Was initdata delivered? (should show cdh.toml with the registry remap)
cat /run/confidential-containers/initdata/cdh.toml | grep -iE 'registry|mirror|kbs|credential'
# (b) Can the guest reach KBS and the mirror? (bash /dev/tcp; Ctrl-C if it hangs >5s)
(exec 3<>/dev/tcp/kbs-service.trustee-operator-system.svc/8080) && echo KBS_OK || echo KBS_FAIL
(exec 3<>/dev/tcp/mirror.rig.local/8443) && echo MIRROR_OK || echo MIRROR_FAIL
# (c) Is image-rs pulling? (data should be accumulating if the pull started)
ls -laR /run/image-rs /run/kata-containers/image 2>/dev/null
# (d) Did attestation/credential fetch happen? (creds land here after a successful attestation)
ls -laR /run/confidential-containers/cdh/ 2>/dev/null
# (e) The actual error — the guest runs systemd, so the agent/CDH/AA logs are in the journal:
journalctl -b --no-pager | grep -iE 'image-rs|confidential-data-hub|attestation|kbs|pull|registry|mirror|error|denied|x509|connect' | tail -40
#   (if journalctl is absent, try:  dmesg | tail -50  )
```

## What each result means
- **(a) empty / missing** → initdata still not delivered (re-check the annotation key).
- **(b) MIRROR_FAIL or KBS_FAIL** → guest networking/DNS (shouldn't happen — a normal pod gets HTTP 200 to both).
- **(d) empty + journal shows an attestation error** → the OfflineStore/SNP attestation is failing
  (look for the verifier error; the air-gap VCEK negative-test path). This would be the headline finding.
- **(c) growing but (e) shows a 401/auth error** → the mirror credential isn't being applied to the
  guest pull (auth-key vs mirror-location mismatch).
- **journal shows image-rs blocked on a registry/timeout** → the registry_config form (inline vs
  `registry_configuration_uri = kbs:///default/registry-configuration/test`) isn't honored by this
  CDH version → that's the OSC 1.12 gap to file.

## Fallback — get a STABLE CVM to debug calmly
If the sandbox dies too fast to exec, briefly lift egress so the pause image pulls from quay.io and
the sandbox stays up (you lose the air-gap purity but get a stable CVM; the **app** pull still tests
the mirror+attestation path):
```bash
oc delete -k <repo>/gitops/base/airgap-egress     # or on the node: nft delete table inet airgap
# redeploy rung-a, catch + exec as above, watch the APP container pull from the mirror.
# Re-apply airgap-egress afterwards.
```

## When you find the cause
The two likely outcomes — (i) attestation/OfflineStore failure, or (ii) CDH ignores the
initdata registry config — are both worth filing with the OSC/CoCo team (docs/defects #16). If it's
just an auth-key mismatch, register the credential under the mirror-location key the journal shows
image-rs requesting and redeploy.
