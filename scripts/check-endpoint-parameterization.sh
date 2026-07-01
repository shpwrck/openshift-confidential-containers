#!/usr/bin/env bash
# Endpoint-parameterization gate — epic #26 keystone (issue #34).
#
# Asserts the mirror/registry endpoint is reached ONLY through the ARTIFACTORY_REGISTRY seam
# (legacy alias MIRROR_REGISTRY), so a single variable switches every endpoint. No code path may
# bake the literal host such that setting the var fails to switch it. Every remaining
# `mirror.rig.local` in the code surface must be an intentional default, a comment, or a doc
# example; a stray hardcode (e.g. MIRROR_ENDPOINT="mirror.rig.local:8443" or
# image: mirror.rig.local:8443/...) fails the gate.
#
# Soundness: we MASK each intentional construct in place, then flag any host that survives — so an
# allowed construct excuses ONLY its own occurrence. (A line-oriented `grep -v` would let a same-line
# comment or a legit `:-` default whitelist an unrelated hardcode on the same physical line.)
#
# Portable on purpose (bash 3.2 / BSD userland — see epic #25): no mapfile, no `xargs -r`; sed -E,
# grep -E, and [[:space:]] are BSD-safe.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Code surface only. docs/ + *.md are prose/runbook examples; infra/ terraform exposes its own
# `registry_dns_name` variable seam (bastion bootstrap is issue #39) — both excluded on purpose.
surface="$(find scripts ansible gitops install -type f \
	\( -name '*.sh' -o -name '*.yml' -o -name '*.yaml' -o -name '*.j2' -o -name '*.tmpl' \) 2>/dev/null)"
surface="${surface} Makefile"

# Remove the INTENTIONAL constructs (each excuses only the host it directly wraps):
#   - trailing / whole-line comment        (#  ... )
#   - shell default fallback               (${VAR:-mirror.rig.local:8443})
#   - Make default assignment              (MIRROR_REGISTRY ?= mirror.rig.local:8443)
#   - ansible/jinja default() fallback     (default('mirror.rig.local:8443', true))
#   - the ansible DNS-name default         (mirror_dns_name: "mirror.rig.local")
mask_allowed() {
	sed -E \
		-e 's/#.*$//' \
		-e 's/:-mirror\.rig\.local[^"}]*//g' \
		-e 's/\?=[[:space:]]*mirror\.rig\.local[^[:space:]]*//g' \
		-e "s/default\\('mirror\\.rig\\.local[^']*'//g" \
		-e 's/mirror_dns_name:[[:space:]]*"?mirror\.rig\.local[^"]*"?//g'
}

violations=0
for f in ${surface}; do
	[ -f "${f}" ] || continue
	while IFS= read -r hit; do
		[ -n "${hit}" ] || continue
		content="${hit#*:}"
		if printf '%s' "${content}" | mask_allowed | grep -qE 'mirror\.rig\.local'; then
			printf 'STRAY ENDPOINT HARDCODE  %s:%s\n' "${f}" "${hit}" >&2
			violations=1
		fi
	done < <(grep -nE 'mirror\.rig\.local' "${f}" 2>/dev/null || true)
done

if [ "${violations}" -ne 0 ]; then
	echo "endpoint-parameterization gate FAILED (#34): route the endpoint through ARTIFACTORY_REGISTRY (legacy MIRROR_REGISTRY), not the literal host." >&2
	exit 1
fi
echo "endpoint-parameterization gate OK (#34)"
