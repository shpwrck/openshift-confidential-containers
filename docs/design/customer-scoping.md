# Customer Scoping — questions to confirm before/early in the engagement

These are unknowns that the design deliberately works *around* (so they don't block rung-0),
but they must be confirmed with the customer to finalize the apply-to-customer step.

## Hardware
- [ ] **AMD EPYC generation** — Milan (7003) / Genoa (9004) / Turin (9005)? Changes the KDS
      product string and trips Trustee bug #591. (Mitigation: VCEK automation is gen-agnostic.)
- [ ] **BMC vendor/model** (Dell iDRAC / HPE iLO / Supermicro / Lenovo XCC)? Determines whether
      the SNP BIOS settings (`SMEE`, `SEV-SNP Support`, `SNP Memory Coverage`, `SEV-ES ASID
      limit`) are exposed in the **Redfish** BIOS attribute registry so they can be automated
      via metal3 **`HostFirmwareSettings`** (declarative, GitOps) instead of manual console.
      Risk to validate: not all AMD CBS settings are Redfish-exposed on every vendor; fallback
      = vendor tooling (Dell SCP / Supermicro SUM). The manual sequence is in
      [../notes/latitude-snp-bringup.md](../notes/latitude-snp-bringup.md).
- [ ] Socket count per node and node count → total VCEK certs to collect (one per socket).
- [ ] BIOS access to confirm: SEV-SNP Support **Enabled**, Memory Interleaving **Enabled**
      (disabled → PSP `Error: 0x3 INVALID_CONFIG`), SMEE **Enabled**.

## Firmware / lifecycle
- [ ] **Firmware/TCB patch cadence** — decides whether VCEK provisioning is a one-shot bundle
      or a recurring sync. (Mitigation: built as a re-runnable job regardless.)
- [ ] Process for staging firmware updates (ReportedTcb deferral window?).

## Network / air-gap
- [ ] Internal **mirror registry** details (host, CA, auth) for `oc-mirror` + IDMS.
- [ ] Internal **git** host for the Kustomize tree + ArgoCD.
- [ ] Proxy in play? Note: **two independent proxies** — Trustee pod (`KbsEnvVars`) and CVM
      (`aa.toml` in initdata) — neither inherits cluster proxy.

## Trustee / topology
- [ ] Confirm **separate Trustee cluster** placement and the KBS URL the workers will target.
- [ ] TLS route model: passthrough vs re-encrypt (cert pinned in initdata).

## Roadmap
- [ ] 🔴 **TDX timeline** — fully air-gapped TDX is not supported upstream yet. Confirm the
      customer understands the SNP-now / TDX-when-supported split.
- [ ] Does the customer already run **OpenShift GitOps/ArgoCD**, or is it net-new?

## Secrets the customer actually cares about
- [ ] Real credential type(s) to gate behind attestation (vs the demo `sample` secret).
- [ ] Image signing (cosign) and/or encryption requirements for rungs b/c.
