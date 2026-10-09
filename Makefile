# The release manifest is the single source for product versions.
SHELL := /bin/bash
.DEFAULT_GOAL := help
COCO_STATE_DIR ?= $(HOME)/.local/state/openshift-confidential-containers
TEE ?= snp
OCP_VERSION ?= $(shell python3 scripts/verify-release.py --get platform.version)
CATALOGSOURCE ?= $(shell python3 scripts/verify-release.py --get catalog.source)
WORKER_CONTEXT ?=
TRUSTEE_CONTEXT ?=
TRUSTEE_LAB ?= 0
TRUSTEE_PROFILE ?= Restricted
NS ?= trustee-operator-system
WORKLOAD_NS ?= coco-validation
NODE ?=
OVERLAY ?= sno-workers
WHICH ?= all
TIMEOUT ?= 180
MIRROR_REGISTRY ?= mirror.rig.local:8443
ARTIFACTORY_REGISTRY ?= $(MIRROR_REGISTRY)
override MIRROR_REGISTRY := $(ARTIFACTORY_REGISTRY)
ARTIFACT_DIR ?= $(COCO_STATE_DIR)/rung-image-artifacts
ASSETS ?= $(COCO_STATE_DIR)/cluster-assets
BIN_DIR ?= $(COCO_STATE_DIR)/bin
INSTALL ?= $(BIN_DIR)/openshift-install
PULL_SECRET ?= $(COCO_STATE_DIR)/credentials/pull-secret.json
VCEK_BUNDLE ?= $(COCO_STATE_DIR)/vcek-bundle
INITDATA ?= $(COCO_STATE_DIR)/initdata.toml
RVPS_OUT ?= $(COCO_STATE_DIR)/rvps-$(TEE).yaml
RUNG_KBS_IMAGE ?= $(shell python3 scripts/verify-release.py --get images.ubiMinimal.ref)
RUNG_SIGNED_IMAGE ?= $(MIRROR_REGISTRY)/coco/rung-b:signed
RUNG_SIGNED_UNSIGNED_IMAGE ?= $(MIRROR_REGISTRY)/coco/rung-b-unsigned:unsigned
RUNG_ENCRYPTED_IMAGE ?= $(MIRROR_REGISTRY)/coco/rung-c:encrypted
RUNG_ENCRYPTED_KEY_ID ?= kbs:///default/image-key/rung-encrypted
RUNG_ENCRYPTED_KEY_FILE ?= $(ARTIFACT_DIR)/rung-encrypted-image.key
RUNG_SIGNED_COSIGN_PUB ?= $(ARTIFACT_DIR)/cosign.pub
RUNG_SIGNED_POLICY_URI ?= kbs:///default/security-policy/rung-signed
RUNG_ENCRYPTED_POLICY_URI ?= kbs:///default/security-policy/test
RUNG_IMAGE_MANIFEST ?= $(ARTIFACT_DIR)/rung-image-manifest.json
COSIGN_KEY ?= $(ARTIFACT_DIR)/cosign.key
COSIGN_PUB ?= $(ARTIFACT_DIR)/cosign.pub
export COCO_STATE_DIR TEE OCP_VERSION CATALOGSOURCE WORKER_CONTEXT TRUSTEE_CONTEXT TRUSTEE_LAB TRUSTEE_PROFILE
export WORKLOAD_NS
export MIRROR_REGISTRY ARTIFACTORY_REGISTRY ARTIFACT_DIR BIN_DIR PULL_SECRET VCEK_BUNDLE
export RUNG_KBS_IMAGE SOURCE_IMAGE RUNG_SIGNED_IMAGE RUNG_SIGNED_UNSIGNED_IMAGE RUNG_ENCRYPTED_IMAGE
export RUNG_ENCRYPTED_KEY_ID RUNG_SIGNED_POLICY_URI RUNG_ENCRYPTED_POLICY_URI
export RUNG_IMAGE_MANIFEST COSIGN_KEY COSIGN_PUB TIMEOUT
# Command-line variables and exported environment variables pass through to scripts.
# NS is Trustee's namespace here; proof/workload recipes explicitly select WORKLOAD_NS.

.PHONY: help check-release preflight lint test install-dev-tools fetch-cli-tools
help: ## Show current entry points
	@awk 'BEGIN{FS=":.*## "} /^[a-zA-Z0-9_-]+:.*## /{printf "  %-28s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
check-release: ## Check repository/BOM consistency without credentials or hardware
	python3 scripts/verify-release.py
preflight: ## Require all catalog/image/tool pins to be resolved before deployment
	python3 scripts/verify-release.py --require-resolved --tee "$(TEE)"
install-dev-tools: ## Install checksum-verified OPA and Kustomize in external state
	python3 scripts/install-dev-tools.py
lint: ## Strict shell, policy, manifest, and offline regression checks
	bash scripts/lint.sh
test: lint ## Alias for the complete hardware-free check suite
fetch-cli-tools: ## Fetch checksum-verified CLIs for the selected OCP version
	bash scripts/install-tools.sh

.PHONY: bringup-sno-airgapped ansible-lint pxe-stop mirror-content
bringup-sno-airgapped: ## Prepare by default; ARGS='--mode fresh-install ...' explicitly installs
	bash ansible/up.sh $(ARGS)
ansible-lint: ## Validate Ansible syntax and lint (requires development dependencies)
	cd ansible && ANSIBLE_CONFIG="$(CURDIR)/ansible/ansible.cfg" ansible-lint
	cd ansible && ANSIBLE_CONFIG="$(CURDIR)/ansible/ansible.cfg" ansible-playbook --syntax-check playbooks/site.yml
pxe-stop: ## Close the boot-artifact endpoint
	cd ansible && ANSIBLE_CONFIG="$(CURDIR)/ansible/ansible.cfg" ansible-playbook playbooks/site.yml --tags pxe-stop $(ARGS)
mirror-content: preflight ## Push selected release content with oc-mirror v2
	bash scripts/mirror.sh mirror

.PHONY: agent-image pxe-files serve-boot-artifacts stop-boot-artifacts install-wait
agent-image: preflight ## Create an ISO from externally prepared install assets
	"$(INSTALL)" --dir "$(ASSETS)" agent create image
pxe-files: preflight ## Create PXE artifacts from externally prepared install assets
	"$(INSTALL)" --dir "$(ASSETS)" agent create pxe-files
serve-boot-artifacts: ## Publish prepared boot artifacts on the bastion
	bash scripts/serve-boot-artifacts.sh "$(ASSETS)/boot-artifacts"
stop-boot-artifacts: ## Stop boot-artifact publishing
	bash scripts/serve-boot-artifacts.sh stop
install-wait: ## Wait for the selected fresh installation
	"$(INSTALL)" --dir "$(ASSETS)" agent wait-for install-complete

.PHONY: verify-snp-host validate-sno-baseline repair-sno-baseline install-coco-operators apply-overlay render-overlay diff-overlay
verify-snp-host: ## Check the selected SNP node (NODE and WORKER_CONTEXT required)
	@test -n "$(NODE)" && test -n "$(WORKER_CONTEXT)" || { echo 'Set NODE and WORKER_CONTEXT'; exit 2; }
	bash scripts/verify-snp-host.sh "$(NODE)"
validate-sno-baseline: ## Read-only node/MCP/catalog checks in WORKER_CONTEXT
	bash scripts/validate-sno-baseline.sh
repair-sno-baseline: ## Explicit repair of known MCO drift on NODE
	NODE="$(NODE)" bash scripts/repair-sno-baseline.sh
install-coco-operators: ## Apply selected worker operators in dependency order
	bash scripts/apply-sno.sh
apply-overlay: ## Route worker installs and Trustee configure through staged scripts
	@case "$(OVERLAY)" in \
	  sno-workers) INSTALL_TOPOLOGY=sno bash scripts/apply-sno.sh ;; \
	  customer-workers) INSTALL_TOPOLOGY=customer bash scripts/apply-sno.sh ;; \
	  sno-trustee|customer-trustee) NS="$(NS)" bash scripts/apply-trustee.sh configure ;; \
	  *) echo 'Unknown overlay; use render-overlay to inspect it'; exit 2 ;; esac
render-overlay: ## Render OVERLAY locally without applying it
	oc kustomize "gitops/overlays/$(OVERLAY)"
diff-overlay: ## Server diff; report real errors (a difference is exit 1)
	@test -n "$(WORKER_CONTEXT)" || { echo 'Set WORKER_CONTEXT'; exit 2; }
	@oc --context="$(WORKER_CONTEXT)" diff -k "gitops/overlays/$(OVERLAY)"; rc=$$?; test $$rc -le 1

.PHONY: bootstrap-trustee deploy-trustee seed-trustee-secrets collect-vcek seed-vcek gen-rvps render-measurement-policy
bootstrap-trustee: ## Create Restricted TrusteeConfig, wait for migration, install collateral
	NS="$(NS)" bash scripts/apply-trustee.sh bootstrap
deploy-trustee: ## Configure approved resource policy/RVPS and explicitly named resources
	NS="$(NS)" bash scripts/apply-trustee.sh configure
seed-trustee-secrets: ## Seed synthetic resources on an explicitly selected disposable lab
	NS="$(NS)" bash scripts/seed-trustee-secrets.sh
collect-vcek: ## Collect the selected worker VCEK into external state (NODE required)
	@test -n "$(NODE)" || { echo 'Set NODE'; exit 2; }
	bash scripts/collect-vcek.sh "$(NODE)"
seed-vcek: ## Publish a validated VCEK bundle to the explicit Trustee context
	NS="$(NS)" bash scripts/collect-vcek.sh --seed
gen-rvps: ## Run target-hardware Veritas; convert and validate Trustee 1.2 references
	INITDATA="$(INITDATA)" OUT="$(RVPS_OUT)" NODE="$(NODE)" bash scripts/gen-rvps-veritas.sh
render-measurement-policy: ## Add initdata binding to BASE_CPU_POLICY_FILE without dropping CPU checks
	NS="$(NS)" bash scripts/render-measurement-policy.sh "$(INITDATA)"

.PHONY: build-rung-signed build-rung-images verify-rung-signed-signature verify-rung-encrypted-key-wrap
build-rung-signed: ## Build signed and unsigned controls independently of encrypted-image tooling
	bash scripts/build-rung-images.sh sign-rung-signed-only
build-rung-images: ## Build both signed and experimental encrypted image artifacts
	RUNG_ENCRYPTED_KEY_FILE="$(RUNG_ENCRYPTED_KEY_FILE)" bash scripts/build-rung-images.sh
verify-rung-signed-signature: ## Check published image signatures before guest testing
	bash scripts/verify-rung-signed-signature.sh
verify-rung-encrypted-key-wrap: ## Check encrypted layers and key wrapping before guest testing
	RUNG_ENCRYPTED_KEY_FILE="$(RUNG_ENCRYPTED_KEY_FILE)" bash scripts/verify-rung-encrypted-key-wrap.sh

.PHONY: run-rung-kbs run-rung-signed run-rung-encrypted test-rung proof-plan
run-rung-kbs: ## Render or create a secret-release workload (RENDER_ONLY=1 supported)
	NS="$(WORKLOAD_NS)" TRUSTEE_NS="$(NS)" bash scripts/apply-rung-kbs.sh
run-rung-signed: ## Render or create a signed workload (immutable image required)
	NS="$(WORKLOAD_NS)" TRUSTEE_NS="$(NS)" bash scripts/apply-rung-signed.sh
run-rung-encrypted: ## Experimental encrypted workload (explicit opt-in required for apply)
	NS="$(WORKLOAD_NS)" TRUSTEE_NS="$(NS)" bash scripts/apply-rung-encrypted.sh
proof-plan: ## List proof cases without cluster access
	python3 scripts/run-proofs.py --list
test-rung: ## Fresh allow/deny/restore/recovery proof; WHICH=all or a named case
	NS="$(WORKLOAD_NS)" TRUSTEE_NS="$(NS)" python3 scripts/run-proofs.py "$(WHICH)"

.PHONY: uninstall-coco validate-coco-uninstalled
uninstall-coco: ## Remove the explicitly selected disposable rig stack
	bash scripts/uninstall-coco.sh
validate-coco-uninstalled: ## Read-only uninstall check
	bash scripts/uninstall-coco.sh validate
