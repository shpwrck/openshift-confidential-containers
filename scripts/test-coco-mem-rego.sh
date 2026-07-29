#!/usr/bin/env bash
# Unit tests for the CoCoContainerMemory rego — issue #70.
#
# WHY THIS EXISTS: the `coco-container-memory-floor-unlabeled` constraint has NO labelSelector, so
# its rego is evaluated against EVERY pod creation in scope. A mistake there is not a missed
# finding — it is a cluster-wide admission outage. The single most important assertion below is
# that an ORDINARY pod (no CoCo runtimeClass, no label, no default_memory annotation) yields ZERO
# violations; without the is_coco_pod gate, the fail-closed branches would reject every pod in the
# cluster for want of an annotation they have no reason to carry.
#
# Extracts the rego straight out of the ConstraintTemplate so the test can never drift from the
# manifest that is actually applied.
#
# Requires `opa` on PATH (https://openpolicyagent.org/downloads). Skips cleanly if absent, so it
# is safe to wire into lint on machines that do not have it.
#
# Gatekeeper uses Rego v0, while opa >= 1.0 defaults to v1 — hence --v0-compatible throughout.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

MANIFEST="gitops/base/gatekeeper/constraint-coco-mem.yaml"

if ! command -v opa >/dev/null 2>&1; then
	echo "coco-mem rego tests SKIPPED (#70): opa not on PATH"
	exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

python3 - "$MANIFEST" "$tmp/policy.rego" <<'PY'
import re, sys
src, dest = sys.argv[1], sys.argv[2]
s = open(src).read()
m = re.search(r'rego: \|\n(.*?)\n---', s, re.S)
if not m:
    sys.exit("could not extract the rego block from %s" % src)
lines = [l[8:] if l.startswith(' ' * 8) else l for l in m.group(1).split('\n')]
open(dest, 'w').write('\n'.join(lines) + '\n')
PY

opa check --v0-compatible "$tmp/policy.rego"

python3 - "$tmp/policy.rego" <<'PY'
import json, subprocess, sys
policy = sys.argv[1]
DM = {"io.katacontainers.config.hypervisor.default_memory": "2048"}


def pod(rc=None, labels=None, annots=None, limit=None):
    o = {"metadata": {"name": "p"}, "spec": {"containers": [{"name": "app"}]}}
    if rc:
        o["spec"]["runtimeClassName"] = rc
    if labels:
        o["metadata"]["labels"] = labels
    if annots:
        o["metadata"]["annotations"] = annots
    if limit is not None:
        o["spec"]["containers"][0]["resources"] = {"limits": {"memory": limit}}
    return {"parameters": {"overheadMi": 256}, "review": {"object": o}}


# (description, input, expect_denied)
CASES = [
    # THE outage guard: an ordinary pod must be untouched by a label-less constraint.
    ("ordinary pod: no runtimeClass, no label, no annotation", pod(limit="64Mi"), False),
    ("ordinary pod: nothing set at all", pod(), False),
    ("non-CoCo runtimeClass is ignored", pod(rc="myruntime", limit="64Mi"), False),
    # The #70 bypass this constraint exists to close.
    ("UNLABELED kata-cc, undersized limit", pod(rc="kata-cc", annots=DM, limit="512Mi"), True),
    ("UNLABELED kata-cc, correct limit", pod(rc="kata-cc", annots=DM, limit="2304Mi"), False),
    # Legacy label-only path must keep working (the Assign mutation still relies on the label).
    ("labeled pod, undersized limit", pod(labels={"coco-resource-default": "true"}, annots=DM, limit="512Mi"), True),
    # Fail-closed branches, which must apply to CoCo pods ONLY.
    ("kata-snp missing default_memory annotation", pod(rc="kata-snp", limit="4096Mi"), True),
    ("kata-cc unparseable memory unit", pod(rc="kata-cc", annots=DM, limit="2G"), True),
    ("kata-cc with no memory limit", pod(rc="kata-cc", annots=DM), True),
    ("kata-cc Gi units accepted when sufficient", pod(rc="kata-cc", annots=DM, limit="3Gi"), False),
]

failed = 0
for desc, inp, want_deny in CASES:
    p = subprocess.run(
        ["opa", "eval", "--v0-compatible", "-d", policy, "-I", "data.cococontainermemory.violation"],
        input=json.dumps(inp), capture_output=True, text=True)
    try:
        n = len(json.loads(p.stdout)["result"][0]["expressions"][0]["value"])
    except Exception:
        print("  ERROR  %s\n    %s%s" % (desc, p.stdout[:200], p.stderr[:200]))
        failed = 1
        continue
    got_deny = n > 0
    if got_deny != want_deny:
        print("  FAIL   %s (violations=%d, expected %s)" % (desc, n, "deny" if want_deny else "allow"))
        failed = 1
    else:
        print("  PASS   %s -> %s" % (desc, "deny" if got_deny else "allow"))

sys.exit(failed)
PY

echo "coco-mem rego tests OK (#70)"
