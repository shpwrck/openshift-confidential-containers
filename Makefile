# Rig driver for the disposable SNO test environment.
# Customer env uses ArgoCD against the same gitops/ tree instead of `oc apply`.

OVERLAY ?= sno-workers
NODE    ?=
NS      ?= trustee-operator-system
WORKLOAD_NS ?= default
CATALOGSOURCE ?= cs-redhat-operator-index-v4-20
VCEK_BUNDLE ?= ./vcek-bundle
TEE ?= snp
OCP_VERSION ?= 4.20.18
PULL_SECRET ?= ./pull-secret.json
INITDATA ?= ./initdata-flavour-b.toml
RVPS_OUT ?= ./rvps-$(TEE).yaml
DEBUG_IMAGE ?=
REGISTRIES_CONF ?=
REGISTRY_CERTS_DIR ?=
VERITAS_OC_WRAPPER ?=
VERITAS_EXTRA_ARGS ?=
HWID ?=
HWIDS ?=
MIRROR_REGISTRY ?= mirror.rig.local:8443
MIRROR_DNS_UPSTREAM ?= 192.168.66.10
KBS_URL ?= http://kbs-service.trustee-operator-system.svc:8080
RUNG_A_IMAGE ?= registry.access.redhat.com/ubi9/ubi-minimal@sha256:4ba37413a8284073eb28f1987fdf8f7b9cc3d301807cdd79e10ab5b98bd57a63
ARTIFACT_DIR ?= ./rung-bc-artifacts
SOURCE_IMAGE ?= $(RUNG_A_IMAGE)
SOURCE_IMAGE_REF ?= docker://$(SOURCE_IMAGE)
SKOPEO_COPY_ARGS ?= --remove-signatures
RUNG_C_IMAGE ?= $(MIRROR_REGISTRY)/coco/rung-c:encrypted
RUNG_B_IMAGE ?= $(MIRROR_REGISTRY)/coco/rung-b:signed
RUNG_B_UNSIGNED_IMAGE ?= $(MIRROR_REGISTRY)/coco/rung-b-unsigned:unsigned
RUNG_C_KEY_PATH ?= /default/image-key/rung-c
RUNG_C_KEY_ID ?= kbs://$(RUNG_C_KEY_PATH)
RUNG_C_POLICY_URI ?= kbs:///default/security-policy/test
RUNG_B_POLICY_URI ?= kbs:///default/security-policy/rung-b
RUNG_C_KEY_FILE ?= $(ARTIFACT_DIR)/rung-c-image.key
COCO_KEYPROVIDER_IMAGE ?= coco-keyprovider
CONTAINER_RUNTIME ?=
CONTAINER_VOLUME_SUFFIX ?=
COSIGN_KEY ?= $(ARTIFACT_DIR)/cosign.key
COSIGN_PUB ?= $(ARTIFACT_DIR)/cosign.pub
COSIGN_SIGN_ARGS ?=
COSIGN_VERIFY_ARGS ?=
BUILD_RUNG_IMAGES_SCRIPT ?= ./scripts/build-rung-images.sh
SEED_TRUSTEE_SECRETS_SCRIPT ?= ./scripts/seed-trustee-secrets.sh
APPLY_TRUSTEE_SCRIPT ?= ./scripts/apply-trustee.sh
NEGATIVE_TEST_SCRIPT ?= ./scripts/negative-test.sh
APPLY_RUNG_A_SCRIPT ?= ./scripts/apply-rung-a.sh
APPLY_RUNG_C_SCRIPT ?= ./scripts/apply-rung-c.sh
APPLY_RUNG_B_SCRIPT ?= ./scripts/apply-rung-b.sh
RENDER_RUNG_C_MEASUREMENT_POLICY_SCRIPT ?= ./scripts/render-rung-c-measurement-policy.sh
VERIFY_RUNG_C_KEY_WRAP_SCRIPT ?= ./scripts/verify-rung-c-key-wrap.sh
VERIFY_RUNG_B_SIGNATURE_SCRIPT ?= ./scripts/verify-rung-b-signature.sh
VERIFY_RUNG_ARTIFACTS_AFTER_BUILD ?= 1
REQUIRE_RUNG_BC_IMAGES_MANIFEST ?= 1
RUNG_B_COSIGN_PUB ?= $(ARTIFACT_DIR)/cosign.pub
RUNG_B_POLICY_FILE ?=
RUNG_B_POLICY_IMAGE_PREFIX ?=
EVIDENCE_DIR ?=
DIAG_DIR ?=
RUNG_BC_IMAGES_MANIFEST ?= $(ARTIFACT_DIR)/rung-bc-images.json
REQUIRE_MIRROR_SUMMARY ?= 1
PROOF_SCOPE ?= all
EVIDENCE_PODS ?= rung-a-secret rung-c-encrypted rung-b-signed negtest-rung-a negtest-rung-c negtest-rung-b negtest-air-gap
RUNG_C_POD ?= rung-c-encrypted
RUNG_B_POD ?= rung-b-signed
NEG_RUNG_C_POD ?= negtest-rung-c
NEG_RUNG_B_POD ?= negtest-rung-b
RUNG_B_EVIDENCE_PODS ?= $(RUNG_B_POD) $(NEG_RUNG_B_POD)
RUNG_C_APP_LOG_MARKER ?= rung-c: encrypted image decrypted and running
RUNG_B_APP_LOG_MARKER ?= rung-b: signed image accepted and running
KEEP_DENIED_PODS ?= 0
TRUSTEE_LOG_TAIL ?= 1000
TRUSTEE_LOG_SINCE_TIME ?=
POD_LOG_TAIL ?= 200
CRIO_LOG_TAIL ?= 1000
CRIO_LOG_SINCE_TIME ?=
MIRROR_LOG_TAIL ?= 1000
MIRROR_LOG_SINCE_TIME ?=
MIRROR_LOG_FILES ?=
MIRROR_CONTAINER_NAMES ?=

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
# config + the OpenShift install. `make bringup-sno-airgapped` sequences both, pausing only at the SEV-SNP BIOS step.
# Requires: LATITUDESH_AUTH_TOKEN in env; RH pull-secret on the bastion (~/pull-secret.json);
# and -e overrides from terraform output (see ansible/README.md). Pass extra args via ARGS=.
# Public console publishing is default-on; opt out with -e public_console_enabled=false.
#   make bringup-sno-airgapped ARGS="--apply-tf -e vlan_vid_override=123 -e node_server_id=sv_x -e boot_artifacts_token=$(openssl rand -hex 16)"
.PHONY: bringup-sno-airgapped
bringup-sno-airgapped: ## Hands-off air-gapped SNO bring-up via Ansible (stops at the SEV-SNP BIOS step)
	cd ansible && ./up.sh $(ARGS)

.PHONY: ansible-lint
ansible-lint: ## Lint the Ansible tree (yamllint + ansible-lint + syntax-check)
	cd ansible && yamllint . && ansible-lint && ansible-playbook --syntax-check playbooks/site.yml

.PHONY: pxe-stop
pxe-stop: ## Close the boot-artifact endpoint after the node has booted (issue #33)
	cd ansible && ansible-playbook playbooks/site.yml --tags pxe-stop $(ARGS)

## --- Prereqs / tooling (Phase 0) -----------------------------------------
.PHONY: fetch-cli-tools
fetch-cli-tools: ## Fetch version-pinned oc / openshift-install / oc-mirror into ./bin (Phase 0)
	./scripts/install-tools.sh

## --- Mirror (Phase 2 — the ~1-2h bottleneck, cacheable) ------------------
.PHONY: mirror-content
mirror-content: ## oc-mirror v2 push to the bastion (needs MIRROR_REGISTRY=<host:port>)
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
.PHONY: apply-overlay
apply-overlay: ## oc apply -k the selected OVERLAY (default: sno-workers)
	oc apply -k gitops/overlays/$(OVERLAY)

.PHONY: install-coco-operators
install-coco-operators: ## Phase 4: operators (NFD->cert-manager->OSC->Trustee) + KataConfig (reboots node)
	CATALOGSOURCE="$(CATALOGSOURCE)" bash ./scripts/apply-sno.sh

.PHONY: deploy-trustee
deploy-trustee: ## Phase 5: stand up the rig Trustee (seed VCEK OfflineStore + RVPS after)
	NS="$(NS)" VCEK_BUNDLE="$(VCEK_BUNDLE)" HWID="$(HWID)" HWIDS="$(HWIDS)" MIRROR_REGISTRY="$(MIRROR_REGISTRY)" bash ./scripts/apply-trustee.sh

.PHONY: seed-trustee-secrets
seed-trustee-secrets: ## Phase 5: create/update rig Trustee secrets from bastion-local files
	NS="$(NS)" VCEK_BUNDLE="$(VCEK_BUNDLE)" HWID="$(HWID)" HWIDS="$(HWIDS)" MIRROR_REGISTRY="$(MIRROR_REGISTRY)" bash ./scripts/seed-trustee-secrets.sh

.PHONY: build-rung-images
build-rung-images: ## Phase 6: build/push rung-c encrypted and rung-b signed images
	MIRROR_REGISTRY="$(MIRROR_REGISTRY)" SOURCE_IMAGE="$(SOURCE_IMAGE)" SOURCE_IMAGE_REF="$(SOURCE_IMAGE_REF)" SKOPEO_COPY_ARGS="$(SKOPEO_COPY_ARGS)" ARTIFACT_DIR="$(ARTIFACT_DIR)" RUNG_C_IMAGE="$(RUNG_C_IMAGE)" RUNG_B_IMAGE="$(RUNG_B_IMAGE)" RUNG_B_UNSIGNED_IMAGE="$(RUNG_B_UNSIGNED_IMAGE)" RUNG_C_KEY_PATH="$(RUNG_C_KEY_PATH)" RUNG_C_KEY_ID="$(RUNG_C_KEY_ID)" RUNG_C_KEY_FILE="$(RUNG_C_KEY_FILE)" COCO_KEYPROVIDER_IMAGE="$(COCO_KEYPROVIDER_IMAGE)" CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" CONTAINER_VOLUME_SUFFIX="$(CONTAINER_VOLUME_SUFFIX)" COSIGN_KEY="$(COSIGN_KEY)" COSIGN_PUB="$(COSIGN_PUB)" COSIGN_SIGN_ARGS="$(COSIGN_SIGN_ARGS)" COSIGN_VERIFY_ARGS="$(COSIGN_VERIFY_ARGS)" VERIFY_RUNG_ARTIFACTS_AFTER_BUILD="$(VERIFY_RUNG_ARTIFACTS_AFTER_BUILD)" VERIFY_RUNG_C_KEY_WRAP_SCRIPT="$(VERIFY_RUNG_C_KEY_WRAP_SCRIPT)" VERIFY_RUNG_B_SIGNATURE_SCRIPT="$(VERIFY_RUNG_B_SIGNATURE_SCRIPT)" bash "$(BUILD_RUNG_IMAGES_SCRIPT)"

.PHONY: verify-rung-c-key-wrap
verify-rung-c-key-wrap: ## Phase 6: verify rung-c encrypted layer KID and KEK unwrap before seeding Trustee
	MIRROR_REGISTRY="$(MIRROR_REGISTRY)" ARTIFACT_DIR="$(ARTIFACT_DIR)" RUNG_C_IMAGE="$(RUNG_C_IMAGE)" RUNG_C_KEY_ID="$(RUNG_C_KEY_ID)" RUNG_C_KEY_FILE="$(RUNG_C_KEY_FILE)" RUNG_BC_IMAGES_MANIFEST="$(RUNG_BC_IMAGES_MANIFEST)" REQUIRE_RUNG_BC_IMAGES_MANIFEST="$(REQUIRE_RUNG_BC_IMAGES_MANIFEST)" bash "$(VERIFY_RUNG_C_KEY_WRAP_SCRIPT)"

.PHONY: verify-rung-b-signature
verify-rung-b-signature: ## Phase 6: verify rung-b signed image and unsigned negative-control signature state
	MIRROR_REGISTRY="$(MIRROR_REGISTRY)" ARTIFACT_DIR="$(ARTIFACT_DIR)" RUNG_B_IMAGE="$(RUNG_B_IMAGE)" RUNG_B_UNSIGNED_IMAGE="$(RUNG_B_UNSIGNED_IMAGE)" RUNG_B_COSIGN_PUB="$(RUNG_B_COSIGN_PUB)" RUNG_BC_IMAGES_MANIFEST="$(RUNG_BC_IMAGES_MANIFEST)" REQUIRE_RUNG_BC_IMAGES_MANIFEST="$(REQUIRE_RUNG_BC_IMAGES_MANIFEST)" COSIGN_VERIFY_ARGS="$(COSIGN_VERIFY_ARGS)" bash "$(VERIFY_RUNG_B_SIGNATURE_SCRIPT)"

.PHONY: verify-rung-bc-artifacts
verify-rung-bc-artifacts: verify-rung-c-key-wrap verify-rung-b-signature ## Phase 6: verify rung-b/c image artifact manifest, key unwrap, and signature state

.PHONY: seed-rung-bc-secrets
seed-rung-bc-secrets: verify-rung-c-key-wrap verify-rung-b-signature ## Phase 6: seed rung-b/c key, public key, and signed-image policy resources
	NS="$(NS)" VCEK_BUNDLE="$(VCEK_BUNDLE)" HWID="$(HWID)" HWIDS="$(HWIDS)" MIRROR_REGISTRY="$(MIRROR_REGISTRY)" RUNG_C_KEY_ID="$(RUNG_C_KEY_ID)" RUNG_C_KEY_FILE="$(RUNG_C_KEY_FILE)" RUNG_B_IMAGE="$(RUNG_B_IMAGE)" RUNG_B_COSIGN_PUB="$(RUNG_B_COSIGN_PUB)" RUNG_B_POLICY_FILE="$(RUNG_B_POLICY_FILE)" RUNG_B_POLICY_IMAGE_PREFIX="$(RUNG_B_POLICY_IMAGE_PREFIX)" bash "$(SEED_TRUSTEE_SECRETS_SCRIPT)"

.PHONY: deploy-trustee-rung-bc
deploy-trustee-rung-bc: verify-rung-c-key-wrap verify-rung-b-signature ## Phase 6: apply Trustee with rung-b/c KBS resources enabled
	NS="$(NS)" VCEK_BUNDLE="$(VCEK_BUNDLE)" HWID="$(HWID)" HWIDS="$(HWIDS)" MIRROR_REGISTRY="$(MIRROR_REGISTRY)" RUNG_C_KEY_ID="$(RUNG_C_KEY_ID)" RUNG_C_KEY_FILE="$(RUNG_C_KEY_FILE)" RUNG_B_IMAGE="$(RUNG_B_IMAGE)" RUNG_B_COSIGN_PUB="$(RUNG_B_COSIGN_PUB)" RUNG_B_POLICY_FILE="$(RUNG_B_POLICY_FILE)" RUNG_B_POLICY_IMAGE_PREFIX="$(RUNG_B_POLICY_IMAGE_PREFIX)" bash "$(APPLY_TRUSTEE_SCRIPT)"

## --- rung-b only (signed image, no rung-c / no coco-keyprovider) ----------
# rung-b (signed image) is independent of rung-c (encrypted image). These targets prove rung-b
# WITHOUT the rung-c encryption path, so they need neither coco-keyprovider (often unavailable in
# an air gap) nor the rung-c artifacts. They deliberately omit all RUNG_C_* env so the trustee
# scripts stay rung-b-only (rung-c is gated on a non-empty RUNG_C_KEY_FILE).
.PHONY: build-rung-b
build-rung-b: ## Phase 6 (rung-b only): build/push + cosign-sign the signed image (no rung-c, no keyprovider)
	# SOURCE_IMAGE is deliberately NOT forwarded here: the Makefile default ($(RUNG_A_IMAGE)) is a
	# public registry.access.redhat.com ref, which would break the first `skopeo copy` on a
	# mirror-only bastion. Omitting it lets build-rung-images.sh use its MIRROR_REGISTRY-derived
	# default; override with `make build-rung-b SOURCE_IMAGE=<ref>` if you really need a custom source.
	MIRROR_REGISTRY="$(MIRROR_REGISTRY)" SKOPEO_COPY_ARGS="$(SKOPEO_COPY_ARGS)" ARTIFACT_DIR="$(ARTIFACT_DIR)" RUNG_B_IMAGE="$(RUNG_B_IMAGE)" RUNG_B_UNSIGNED_IMAGE="$(RUNG_B_UNSIGNED_IMAGE)" COSIGN_KEY="$(COSIGN_KEY)" COSIGN_PUB="$(COSIGN_PUB)" COSIGN_SIGN_ARGS="$(COSIGN_SIGN_ARGS)" COSIGN_VERIFY_ARGS="$(COSIGN_VERIFY_ARGS)" bash "$(BUILD_RUNG_IMAGES_SCRIPT)" sign-rung-b-only

.PHONY: seed-rung-b-secrets
seed-rung-b-secrets: ## Phase 6 (rung-b only): seed rung-b cosign pub + signed-image policy (no rung-c)
	NS="$(NS)" VCEK_BUNDLE="$(VCEK_BUNDLE)" HWID="$(HWID)" HWIDS="$(HWIDS)" MIRROR_REGISTRY="$(MIRROR_REGISTRY)" RUNG_C_KEY_ID= RUNG_C_KEY_FILE= RUNG_B_IMAGE="$(RUNG_B_IMAGE)" RUNG_B_COSIGN_PUB="$(RUNG_B_COSIGN_PUB)" RUNG_B_POLICY_FILE="$(RUNG_B_POLICY_FILE)" RUNG_B_POLICY_IMAGE_PREFIX="$(RUNG_B_POLICY_IMAGE_PREFIX)" bash "$(SEED_TRUSTEE_SECRETS_SCRIPT)"

.PHONY: deploy-trustee-rung-b
deploy-trustee-rung-b: ## Phase 6 (rung-b only): apply Trustee with rung-b KBS resources (no rung-c, no keyprovider)
	NS="$(NS)" VCEK_BUNDLE="$(VCEK_BUNDLE)" HWID="$(HWID)" HWIDS="$(HWIDS)" MIRROR_REGISTRY="$(MIRROR_REGISTRY)" RUNG_C_KEY_ID= RUNG_C_KEY_FILE= RUNG_B_IMAGE="$(RUNG_B_IMAGE)" RUNG_B_COSIGN_PUB="$(RUNG_B_COSIGN_PUB)" RUNG_B_POLICY_FILE="$(RUNG_B_POLICY_FILE)" RUNG_B_POLICY_IMAGE_PREFIX="$(RUNG_B_POLICY_IMAGE_PREFIX)" bash "$(APPLY_TRUSTEE_SCRIPT)"

.PHONY: run-rung-a-secret
run-rung-a-secret: ## Phase 6: render initdata, launch rung-a, and wait for the CoCo pod to run
	NS="$(WORKLOAD_NS)" TRUSTEE_NS="$(NS)" MIRROR_REGISTRY="$(MIRROR_REGISTRY)" MIRROR_DNS_UPSTREAM="$(MIRROR_DNS_UPSTREAM)" KBS_URL="$(KBS_URL)" RUNG_A_IMAGE="$(RUNG_A_IMAGE)" bash "$(APPLY_RUNG_A_SCRIPT)"

.PHONY: run-rung-c-encrypted
run-rung-c-encrypted: ## Phase 6: render initdata, launch rung-c, and wait for the encrypted-image pod
	NS="$(WORKLOAD_NS)" TRUSTEE_NS="$(NS)" MIRROR_REGISTRY="$(MIRROR_REGISTRY)" MIRROR_DNS_UPSTREAM="$(MIRROR_DNS_UPSTREAM)" KBS_URL="$(KBS_URL)" RUNG_C_KEY_ID="$(RUNG_C_KEY_ID)" IMAGE_SECURITY_POLICY_URI="$(RUNG_C_POLICY_URI)" RUNG_C_IMAGE="$(RUNG_C_IMAGE)" bash "$(APPLY_RUNG_C_SCRIPT)"

.PHONY: run-rung-b-signed
run-rung-b-signed: ## Phase 6: render initdata, launch rung-b, and wait for the signed-image pod
	NS="$(WORKLOAD_NS)" TRUSTEE_NS="$(NS)" MIRROR_REGISTRY="$(MIRROR_REGISTRY)" MIRROR_DNS_UPSTREAM="$(MIRROR_DNS_UPSTREAM)" KBS_URL="$(KBS_URL)" IMAGE_SECURITY_POLICY_URI="$(RUNG_B_POLICY_URI)" RUNG_B_IMAGE="$(RUNG_B_IMAGE)" bash "$(APPLY_RUNG_B_SCRIPT)"

.PHONY: uninstall-coco
uninstall-coco: ## Remove the CoCo stack in reverse order (Trustee->Kata/Gatekeeper/NFD->OLM)
	bash ./scripts/uninstall-coco.sh

.PHONY: validate-coco-uninstalled
validate-coco-uninstalled: ## Verify CoCo operators/operands are absent and the SNO node is Ready
	bash ./scripts/uninstall-coco.sh validate

.PHONY: diff-overlay
diff-overlay: ## Server-side diff of the selected OVERLAY
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
	TEE="$(TEE)" OCP_VERSION="$(OCP_VERSION)" PULL_SECRET="$(PULL_SECRET)" INITDATA="$(INITDATA)" OUT="$(RVPS_OUT)" NODE="$(NODE)" DEBUG_IMAGE="$(DEBUG_IMAGE)" REGISTRIES_CONF="$(REGISTRIES_CONF)" REGISTRY_CERTS_DIR="$(REGISTRY_CERTS_DIR)" VERITAS_OC_WRAPPER="$(VERITAS_OC_WRAPPER)" VERITAS_EXTRA_ARGS="$(VERITAS_EXTRA_ARGS)" ./scripts/gen-rvps-veritas.sh

.PHONY: render-rung-c-measurement-policy
render-rung-c-measurement-policy: ## Render restrictive rung-c HOST_DATA and image-key policies (set INITDATA)
	NS="$(NS)" RUNG_C_KEY_ID="$(RUNG_C_KEY_ID)" bash "$(RENDER_RUNG_C_MEASUREMENT_POLICY_SCRIPT)" "$(INITDATA)"

## --- Validation (negative tests) -----------------------------------------
.PHONY: negative-test
negative-test: ## Run the per-rung denial proofs (WHICH=all|rung-a|rung-c|rung-b|air-gap)
	NS="$(WORKLOAD_NS)" TRUSTEE_NS="$(NS)" MIRROR_REGISTRY="$(MIRROR_REGISTRY)" MIRROR_DNS_UPSTREAM="$(MIRROR_DNS_UPSTREAM)" KBS_URL="$(KBS_URL)" RUNG_C_POLICY_URI="$(RUNG_C_POLICY_URI)" RUNG_B_POLICY_URI="$(RUNG_B_POLICY_URI)" RUNG_C_IMAGE="$(RUNG_C_IMAGE)" RUNG_B_UNSIGNED_IMAGE="$(RUNG_B_UNSIGNED_IMAGE)" TIMEOUT="$(TIMEOUT)" KEEP_DENIED_PODS="$(KEEP_DENIED_PODS)" bash "$(NEGATIVE_TEST_SCRIPT)" $(WHICH)
