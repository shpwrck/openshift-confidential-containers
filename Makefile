# Rig driver for the disposable SNO test environment.
# Customer env uses ArgoCD against the same gitops/ tree instead of `oc apply`.

OVERLAY ?= sno-workers
NODE    ?=
NS      ?= trustee-operator-system

.PHONY: help
help: ## List targets
	@grep -E '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

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
negative-test: ## Run the per-rung denial proofs (see docs/design/engagement-design.md §5)
	@echo "TODO: implement rung a/b/c + air-gap negative tests"; exit 1
