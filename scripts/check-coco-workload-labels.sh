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
# EVALUATED PER YAML DOCUMENT, not per file. A file-wide count would let one correctly labeled
# pod (or an unrelated resource that merely mentions the same key) vouch for a second, unlabeled
# CoCo pod in the same file — the gate would pass while a pod still bypassed both protections.
# Each `---` document is judged on its own, so a label can never be borrowed across documents.
# One document is one resource, so at most one pod spec is in scope at a time.
#
# For a controller (Deployment/StatefulSet/DaemonSet/Job/CronJob/ReplicaSet), the label must sit
# in the POD TEMPLATE — a label on the controller's own metadata is not inherited by the pods it
# creates, so it must appear after the `template:` key to count.
#
# Soundness: comments are MASKED before matching, so prose like `# runtimeClassName: kata-cc`
# (which appears in several explanatory headers) never trips the gate.
#
# Portable on purpose (bash 3.2 / BSD userland — see epic #25): POSIX awk only, no gawk
# extensions (no gensub/asort), no mapfile, no `xargs -r`.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Shipped manifest surface: the gitops tree plus docs/templates (the customer bundle ships real
# pod manifests the customer copies verbatim, so the contract has to hold there too).
surface="$(find gitops docs/templates -type f \
	\( -name '*.yaml' -o -name '*.yml' \) 2>/dev/null || true)"

[ -n "${surface}" ] || { echo "coco workload-label gate OK (#68) — no manifests found"; exit 0; }

# shellcheck disable=SC2086 # word-splitting the newline-separated file list is intended
if awk '
function is_controller(k) {
	return (k == "Deployment" || k == "StatefulSet" || k == "DaemonSet" ||
	        k == "Job" || k == "CronJob" || k == "ReplicaSet" || k == "ReplicationController")
}
function flush(   ok) {
	if (has_rt) {
		# Controllers must carry the label in the pod template; bare pods anywhere in the doc.
		ok = is_controller(kind) ? label_in_template : label_any
		if (!ok) {
			printf "UNLABELED CoCo WORKLOAD  %s:%d (kind=%s)%s\n", \
				curfile, rt_line, (kind == "" ? "?" : kind), \
				(is_controller(kind) && label_any ? " — label is on the controller, not the pod template" : "") \
				> "/dev/stderr"
			bad = 1
		}
	}
	has_rt = 0; label_any = 0; label_in_template = 0; seen_template = 0; kind = ""; rt_line = 0
}
FNR == 1 { if (NR > 1) flush(); curfile = FILENAME }
/^---[ \t]*$/ { flush(); next }
{
	line = $0
	sub(/#.*/, "", line)                       # mask comments: prose must not trip or excuse the gate
	if (line ~ /^kind:[ \t]*/) { kind = line; sub(/^kind:[ \t]*/, "", kind); gsub(/[ \t\r]/, "", kind) }
	if (line ~ /^[ \t]+template:[ \t]*$/) seen_template = 1
	if (line ~ /runtimeClassName:[ \t]*"?kata/) { has_rt = 1; if (!rt_line) rt_line = FNR }
	if (line ~ /coco-resource-default:[ \t]*"?true"?/) {
		label_any = 1
		if (seen_template) label_in_template = 1
	}
}
END { flush(); exit bad }
' ${surface}; then
	echo "coco workload-label gate OK (#68)"
else
	echo "coco workload-label gate FAILED (#68): add 'coco-resource-default: \"true\"' to that pod's metadata.labels (pod template, for a controller), or the Gatekeeper memory floor silently does not apply to it." >&2
	exit 1
fi
