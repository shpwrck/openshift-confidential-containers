#!/usr/bin/env bash
# CoCo workload-label gate — issue #68.
#
# Asserts every CoCo pod manifest in the shipped surface carries the
# `coco-resource-default: "true"` label. That label is the SELECTOR both halves of the
# Gatekeeper memory guard (gitops/base/gatekeeper/) match on — the Assign mutation that fills a
# missing memory default, and the CoCoContainerMemory deny-constraint that rejects an undersized
# limit. Gatekeeper `match` cannot key on spec.runtimeClassName, so the label is the only handle.
#
# Why this is a GATE and not a convention: an unlabeled kata-cc pod does not fail loudly — it
# bypasses mutation AND validation and admits cleanly, then SNP pins the whole CVM at launch and
# the host OOM-kills qemu-kvm seconds later (observed on the rig 2026-07-22: CONSTRAINT_MEMCG /
# task=qemu-kvm, while pod events still showed only Scheduled). The guard was inert from the day
# it was written because nothing ever set the label. This gate is what keeps it wired.
#
# Invariant (per file): count(CoCo runtimeClassName) <= count(coco-resource-default: "true").
# File-scoped rather than per-document so it stays sound for multi-doc manifests without needing
# a YAML parser on the CI box.
#
# Soundness: comments are MASKED before matching, so prose like `# runtimeClassName: kata-cc`
# (which appears in several explanatory headers) never trips the gate.
#
# Portable on purpose (bash 3.2 / BSD userland — see epic #25): no mapfile, no `xargs -r`; sed -E,
# grep -E, and [[:space:]] are BSD-safe.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Shipped manifest surface: the gitops tree plus docs/templates (the customer bundle ships real
# pod manifests the customer copies verbatim, so the contract has to hold there too).
surface="$(find gitops docs/templates -type f \
	\( -name '*.yaml' -o -name '*.yml' \) 2>/dev/null || true)"

# Strip whole-line and trailing comments so documentation prose cannot trip (or excuse) the gate.
mask_comments() {
	sed -E 's/#.*$//'
}

# A CoCo workload is a pod whose runtimeClassName is a Kata/CoCo class (kata-cc, kata-snp, kata-*).
coco_runtime_re='runtimeClassName:[[:space:]]*"?kata'
label_re='coco-resource-default:[[:space:]]*"?true"?'

violations=0
for f in ${surface}; do
	[ -f "${f}" ] || continue
	masked="$(mask_comments < "${f}")"

	runtimes="$(printf '%s\n' "${masked}" | grep -cE "${coco_runtime_re}" || true)"
	[ "${runtimes}" -gt 0 ] || continue

	labels="$(printf '%s\n' "${masked}" | grep -cE "${label_re}" || true)"
	if [ "${labels}" -lt "${runtimes}" ]; then
		printf 'UNLABELED CoCo WORKLOAD  %s (%s CoCo runtimeClassName, %s coco-resource-default label)\n' \
			"${f}" "${runtimes}" "${labels}" >&2
		violations=1
	fi
done

if [ "${violations}" -ne 0 ]; then
	echo "coco workload-label gate FAILED (#68): add 'coco-resource-default: \"true\"' to the pod's metadata.labels, or the Gatekeeper memory floor silently does not apply to it." >&2
	exit 1
fi
echo "coco workload-label gate OK (#68)"
