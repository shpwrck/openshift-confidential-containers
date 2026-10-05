#!/usr/bin/env bash
# Required hardware-free checks. Missing prerequisites or failed checks are errors.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
for tool in python3 shellcheck opa kustomize ansible-playbook ansible-lint; do
  command -v "$tool" >/dev/null || { echo "ERROR: missing $tool; see docs/current-quickstart.md" >&2; exit 2; }
done
while IFS= read -r file; do bash -n "$file"; done < <(find scripts -type f -name '*.sh')
shellcheck --severity=warning -x scripts/*.sh scripts/lib/*.sh ansible/up.sh
bash scripts/check-endpoint-parameterization.sh
bash scripts/check-coco-workload-labels.sh
bash scripts/test-coco-mem-rego.sh
python3 scripts/verify-release.py
python3 scripts/test-release-manifest.py
python3 scripts/test-mirror-resources.py
python3 scripts/test-worker-install.py
python3 scripts/test-worker-safety.py
python3 scripts/test-vcek-bundle.py
python3 -m unittest discover -s tests -v
while IFS= read -r overlay; do
  echo "Rendering $overlay"
  kustomize build "$overlay" >/dev/null
done < <(find gitops/overlays -mindepth 1 -maxdepth 1 -type d | sort)
export ANSIBLE_CONFIG="$PWD/ansible/ansible.cfg"
(cd ansible && ansible-playbook --syntax-check playbooks/site.yml && ansible-lint)
python3 scripts/check-doc-links.py
printf 'All required offline checks passed. Hardware validation remains separate.\n'
