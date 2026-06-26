# Rig driver for the disposable SNO test environment.
# Customer env uses ArgoCD against the same gitops/ tree instead of `oc apply`.

OVERLAY ?= sno-workers
NODE    ?=
NS      ?= trustee-operator-system

# Assets dir the Agent-based installer consumes (install-config + agent-config land here).
# FILL: matches the dir used in install/README.md ("cluster-assets").
ASSETS  ?= cluster-assets
# openshift-install / oc-mirror come from scripts/install-tools.sh into ./bin; prefer them.
INSTALL ?= ./bin/openshift-install
MIRROR_REGISTRY ?=

.PHONY: help
help: ## List targets
	@grep -E '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

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

.PHONY: install-wait
install-wait: ## Wait for the Agent-based SNO install to finish (kubeconfig -> $(ASSETS)/auth)
	$(INSTALL) --dir $(ASSETS) agent wait-for install-complete

## --- Gates ---------------------------------------------------------------
.PHONY: verify-snp-host
verify-snp-host: ## Rung-0 gate: prove SEV-SNP HOST is live on NODE (run before any GitOps)
	@test -n "$(NODE)" || { echo "set NODE=<node-name>"; exit 2; }
	./scripts/verify-snp-host.sh "$(NODE)"

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
	oc apply -k gitops/overlays/sno-workers

.PHONY: apply-trustee
apply-trustee: ## Phase 5: stand up the rig Trustee (seed VCEK OfflineStore + RVPS after)
	oc apply -k gitops/overlays/sno-trustee

.PHONY: diff
diff: ## Server-side diff of the selected OVERLAY
	oc diff -k gitops/overlays/$(OVERLAY) || true

## --- Air-gap data pipelines ----------------------------------------------
.PHONY: collect-vcek
collect-vcek: ## Collect per-socket VCEK certs into the OfflineStore secret (gen-agnostic)
	@test -n "$(NODE)" || { echo "set NODE=<node-name>"; exit 2; }
	./scripts/collect-vcek.sh "$(NODE)" "$(NS)"

.PHONY: gen-rvps
gen-rvps: ## Generate RVPS reference values with Veritas (run on target hardware)
	./scripts/gen-rvps-veritas.sh

## --- Validation (negative tests) -----------------------------------------
.PHONY: negative-test
negative-test: ## Run the per-rung denial proofs (WHICH=all|rung-a|rung-b|rung-c|air-gap)
	./scripts/negative-test.sh $(WHICH)
