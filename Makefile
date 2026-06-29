# Rig driver for the disposable SNO test environment.
# Customer env uses ArgoCD against the same gitops/ tree instead of `oc apply`.

OVERLAY ?= sno-workers
NODE    ?=
NS      ?= trustee-operator-system
CATALOGSOURCE ?= cs-redhat-operator-index-v4-20
VCEK_BUNDLE ?= ./vcek-bundle
HWID ?=
MIRROR_REGISTRY ?= mirror.rig.local:8443
MIRROR_DNS_UPSTREAM ?= 192.168.66.10
KBS_URL ?= http://kbs-service.trustee-operator-system.svc:8080
RUNG_A_IMAGE ?= registry.access.redhat.com/ubi9/ubi-minimal@sha256:4ba37413a8284073eb28f1987fdf8f7b9cc3d301807cdd79e10ab5b98bd57a63

# Assets dir the Agent-based installer consumes (install-config + agent-config land here).
# FILL: matches the dir used in install/README.md ("cluster-assets").
ASSETS  ?= cluster-assets
# openshift-install / oc-mirror come from scripts/install-tools.sh into ./bin; prefer them.
INSTALL ?= ./bin/openshift-install

.PHONY: help
help: ## List targets
	@grep -E '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

## --- Hands-off bring-up (Ansible automation) -----------------------------
# TF owns infra (bastion, node, VLAN, firewall, netboot OS=ipxe); Ansible owns the bastion host
# config + the OpenShift install. `make up` sequences both, pausing only at the SEV-SNP BIOS step.
# Requires: LATITUDESH_AUTH_TOKEN in env; RH pull-secret on the bastion (~/pull-secret.json);
# and -e overrides from terraform output (see ansible/README.md). Pass extra args via ARGS=.
#   make up ARGS="--apply-tf -e vlan_vid_override=123 -e node_server_id=sv_x -e boot_artifacts_token=$(openssl rand -hex 16)"
.PHONY: up
up: ## Hands-off air-gapped SNO bring-up via Ansible (stops at the SEV-SNP BIOS step)
	cd ansible && ./up.sh $(ARGS)

.PHONY: ansible-lint
ansible-lint: ## Lint the Ansible tree (yamllint + ansible-lint + syntax-check)
	cd ansible && yamllint . && ansible-lint && ansible-playbook --syntax-check playbooks/site.yml

.PHONY: pxe-stop
pxe-stop: ## Close the boot-artifact endpoint after the node has booted (issue #33)
	cd ansible && ansible-playbook playbooks/site.yml --tags pxe-stop $(ARGS)

## --- Prereqs / tooling (Phase 0) -----------------------------------------
.PHONY: tools
tools: ## Fetch version-pinned oc / openshift-install / oc-mirror into ./bin (Phase 0)
	./scripts/install-tools.sh

## --- Mirror (Phase 2 — the ~1-2h bottleneck, cacheable) ------------------
.PHONY: mirror
mirror: ## oc-mirror v2 push to the bastion (needs MIRROR_REGISTRY=<host:port>)
	@test -n "$(MIRROR_REGISTRY)" || { echo "set MIRROR_REGISTRY=<host:port>"; exit 2; }
	MIRROR_REGISTRY="$(MIRROR_REGISTRY)" ./scripts/mirror.sh mirror

## --- SNO install (Phase 3) -----------------------------------------------
.PHONY: agent-image
agent-image: ## Build the agent ISO from $(ASSETS) (fill install/agent-config first)
	# FILL: $(ASSETS)/{install-config,agent-config}.yaml from install/*.tmpl before this.
	# VERIFY: for true air-gap, $(INSTALL) should come from `oc adm release extract` on the
	#         mirrored release (install/README.md step 3), not the public binary.
	$(INSTALL) --dir $(ASSETS) agent create image

.PHONY: pxe-files
pxe-files: ## Phase 3 (iPXE): build agent PXE/iPXE boot artifacts into $(ASSETS)/boot-artifacts
	# FILL: $(ASSETS)/{install-config,agent-config}.yaml first, AND set agent-config
	#       bootArtifactsBaseURL to where serve-boot-artifacts.sh publishes (bastion pub IP:8080).
	# The node boots iPXE over its PUBLIC NIC, so the base URL must be publicly reachable.
	$(INSTALL) --dir $(ASSETS) agent create pxe-files

.PHONY: serve-boot-artifacts
serve-boot-artifacts: ## Phase 3 (iPXE): publish $(ASSETS)/boot-artifacts under the tokenized path (:8080)
	./scripts/serve-boot-artifacts.sh "$(ASSETS)/boot-artifacts"

.PHONY: stop-boot-artifacts
stop-boot-artifacts: ## Phase 3 (iPXE): close the boot-artifact endpoint once the node has booted
	./scripts/serve-boot-artifacts.sh stop

.PHONY: install-wait
install-wait: ## Wait for the Agent-based SNO install to finish (kubeconfig -> $(ASSETS)/auth)
	$(INSTALL) --dir $(ASSETS) agent wait-for install-complete

## --- Gates ---------------------------------------------------------------
.PHONY: verify-snp-host
verify-snp-host: ## Rung-0 gate: prove SEV-SNP HOST is live on NODE (run before any GitOps)
	@test -n "$(NODE)" || { echo "set NODE=<node-name>"; exit 2; }
	./scripts/verify-snp-host.sh "$(NODE)"

.PHONY: validate-sno-baseline
validate-sno-baseline: ## Read-only gate: node Ready, MCP stable, mirrored CatalogSource READY
	CATALOGSOURCE="$(CATALOGSOURCE)" bash ./scripts/validate-sno-baseline.sh

.PHONY: repair-sno-baseline
repair-sno-baseline: ## Repair known MCO kubelet.conf drift, then wait for the SNO baseline gate
	NODE="$(NODE)" CATALOGSOURCE="$(CATALOGSOURCE)" bash ./scripts/repair-sno-baseline.sh

## --- Lint / CI (no hardware) ---------------------------------------------
.PHONY: lint
lint: ## kustomize build + kubeconform + conftest over all overlays
	./scripts/lint.sh

## --- Apply (rig) ---------------------------------------------------------
.PHONY: apply
apply: ## oc apply -k the selected OVERLAY (default: sno-workers)
	oc apply -k gitops/overlays/$(OVERLAY)

.PHONY: apply-sno
apply-sno: ## Phase 4: operators (NFD->cert-manager->OSC->Trustee) + KataConfig (reboots node)
	CATALOGSOURCE="$(CATALOGSOURCE)" bash ./scripts/apply-sno.sh

.PHONY: apply-trustee
apply-trustee: ## Phase 5: stand up the rig Trustee (seed VCEK OfflineStore + RVPS after)
	NS="$(NS)" VCEK_BUNDLE="$(VCEK_BUNDLE)" HWID="$(HWID)" MIRROR_REGISTRY="$(MIRROR_REGISTRY)" bash ./scripts/apply-trustee.sh

.PHONY: seed-trustee-secrets
seed-trustee-secrets: ## Phase 5: create/update rig Trustee secrets from bastion-local files
	NS="$(NS)" VCEK_BUNDLE="$(VCEK_BUNDLE)" HWID="$(HWID)" MIRROR_REGISTRY="$(MIRROR_REGISTRY)" bash ./scripts/seed-trustee-secrets.sh

.PHONY: apply-rung-a
apply-rung-a: ## Phase 6: render initdata, launch rung-a, and wait for the CoCo pod to run
	NS=default TRUSTEE_NS="$(NS)" MIRROR_REGISTRY="$(MIRROR_REGISTRY)" MIRROR_DNS_UPSTREAM="$(MIRROR_DNS_UPSTREAM)" KBS_URL="$(KBS_URL)" RUNG_A_IMAGE="$(RUNG_A_IMAGE)" bash ./scripts/apply-rung-a.sh

.PHONY: uninstall-coco
uninstall-coco: ## Remove the CoCo stack in reverse order (Trustee->Kata/Gatekeeper/NFD->OLM)
	bash ./scripts/uninstall-coco.sh

.PHONY: validate-coco-uninstalled
validate-coco-uninstalled: ## Verify CoCo operators/operands are absent and the SNO node is Ready
	bash ./scripts/uninstall-coco.sh validate

.PHONY: diff
diff: ## Server-side diff of the selected OVERLAY
	oc diff -k gitops/overlays/$(OVERLAY) || true

## --- Air-gap data pipelines ----------------------------------------------
.PHONY: collect-vcek
collect-vcek: ## Collect per-socket VCEK certs into the OfflineStore secret (auto-detects single-node clusters)
	@node="$(NODE)"; \
	if [ -z "$$node" ]; then \
		nodes="$$(oc get nodes --request-timeout=10s -o name 2>/dev/null | sed 's#^node/##')"; \
		count="$$(printf '%s\n' "$$nodes" | sed '/^$$/d' | wc -l | tr -d ' ')"; \
		if [ "$$count" = "1" ]; then \
			node="$$nodes"; \
			echo "Auto-detected NODE=$$node"; \
		elif [ "$$count" = "0" ]; then \
			echo "set NODE=<node-name> (could not auto-detect from oc get nodes)"; \
			exit 2; \
		else \
			echo "set NODE=<node-name> (multiple nodes found: $$(printf '%s' "$$nodes" | tr '\n' ' '))"; \
			exit 2; \
		fi; \
	fi; \
	./scripts/collect-vcek.sh "$$node" "$(NS)"

.PHONY: gen-rvps
gen-rvps: ## Generate RVPS reference values with Veritas (run on target hardware)
	./scripts/gen-rvps-veritas.sh

## --- Validation (negative tests) -----------------------------------------
.PHONY: negative-test
negative-test: ## Run the per-rung denial proofs (WHICH=all|rung-a|rung-b|rung-c|air-gap)
	./scripts/negative-test.sh $(WHICH)
