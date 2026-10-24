# outside: jterrazz infrastructure
#
# One k3s cluster: an OrbStack VM on the dev Mac. `make deploy` creates it
# (orbctl) and configures it (Ansible); `scripts/deploy.sh` is the canonical
# entry point.

.DEFAULT_GOAL := help
.PHONY: help deploy deploy-platform destroy redeploy-apps check-tools check docs harness-check lint diff smoke test test-host test-admission backup kubeconfig print-helm-unittest-version

GREEN := \033[32m
YELLOW := \033[33m
BLUE := \033[34m
NC := \033[0m

# outside: the OrbStack VM, and the node's MagicDNS name read out of the CI inventory.
VM_NAME := jterrazz-infrastructure
KUBECONFIG_FILE := kubeconfig.yaml
# invariant: THE helm-unittest version: snapshots reproduce only against the version
# that wrote them; validate.yaml reads it through `make print-helm-unittest-version`.
HELM_UNITTEST_VERSION := v1.1.2
NODE_FQDN := $(shell awk '/ansible_host:/ {print $$2; exit}' ansible/inventories/ci.yml)

# outside: how the harness reaches the cluster and the node from this Mac with no tailnet:
# OrbStack runs the VM here. `CLUSTER_KUBECTL=` falls back to $$KUBECONFIG, then
# ./kubeconfig.yaml (the order is harness/src/cluster/kubectl.ts's).
CLUSTER_KUBECTL ?= orb -m $(VM_NAME) -u root kubectl
HOST_SHELL ?= orb -m $(VM_NAME) -u root
export CLUSTER_KUBECTL HOST_SHELL

# invariant: the two vantages of the live contract (docs/guides/test.md). The Mac is the
# internet unless its Tailscale is up; VANTAGE=tailnet adds the private routes and drops
# the boundary negatives, which would then fail for the right reason.
VANTAGE ?= internet
SPECS_internet := specs/deployment/routes/public specs/deployment/certificates/public specs/deployment/boundary specs/cluster specs/routes
SPECS_tailnet := specs/deployment/routes specs/deployment/certificates specs/cluster specs/routes


deploy: ## Provision + configure the cluster (orbctl + Ansible site.yml)
	./scripts/deploy.sh

deploy-platform: ## Re-run the platform layer only (Ansible platform.yml)
	./scripts/deploy.sh --platform

destroy: ## Tear down the OrbStack VM (data on the Mac stays)
	./scripts/deploy.sh --destroy

# invariant: reads the fleet off the live Deployments; ARGS=--dry-run prints it, ARGS="--from FILE"
# replays a snapshot (the repave). Node builtins only, so it needs no install.
redeploy-apps: ## Trigger every app's CI to rebuild+redeploy (ARGS=--dry-run | --from FILE)
	node harness/src/redeploy-apps.bin.ts $(ARGS)

# invariant: the harness's own install, pinned by its lockfile; every target that runs it depends on this.
harness/node_modules/.install: harness/package-lock.json
	cd harness && npm ci
	@touch harness/node_modules/.install


# outside: the two steps `make deploy` does as a side effect; k3s writes a loopback
# server address, so the MagicDNS rewrite is what makes the file usable from the Mac.
kubeconfig: ## Regenerate ./kubeconfig.yaml from the VM (server = MagicDNS name)
	@test -n "$(NODE_FQDN)" || { echo "✗ no ansible_host in ansible/inventories/ci.yml"; exit 1; }
	@orb -m $(VM_NAME) -u root cat /etc/rancher/k3s/k3s.yaml > $(KUBECONFIG_FILE).tmp \
		|| { rm -f $(KUBECONFIG_FILE).tmp; echo "✗ could not read k3s.yaml from $(VM_NAME) (orb list?)"; exit 1; }
	@sed -E 's#https://(127\.0\.0\.1|0\.0\.0\.0):6443#https://$(NODE_FQDN):6443#' \
		$(KUBECONFIG_FILE).tmp > $(KUBECONFIG_FILE)
	@rm -f $(KUBECONFIG_FILE).tmp
	@chmod 600 $(KUBECONFIG_FILE)
	@grep -q 'server: https://$(NODE_FQDN):6443' $(KUBECONFIG_FILE) \
		|| { echo "✗ server address not rewritten: k3s wrote something other than 127.0.0.1/0.0.0.0"; exit 1; }
	@echo "✓ $(KUBECONFIG_FILE) points at https://$(NODE_FQDN):6443 (needs the tailnet)"

# outside: read-only preview against the LIVE cluster, before `make deploy-platform`;
# needs a kubeconfig. One release: `./scripts/helmfile.sh diff -l name=grafana`.
diff: ## Preview what `make deploy-platform` would change (helmfile diff, read-only)
	./scripts/helmfile.sh diff

backup: ## Encrypted snapshot of every persistent volume (ARGS=--consistent for a torn-free copy)
	@./scripts/backup.sh $(ARGS)

smoke: harness/node_modules/.install ## Probe the live platform contract from this machine (VANTAGE=tailnet on the tailnet)
	cd harness && npx vitest --run $(SPECS_$(VANTAGE))

test-host: harness/node_modules/.install ## Check the node itself: sshd, the nft guard, upgrades, k3s encryption, Pod Security
	cd harness && npx vitest --run specs/host

test: smoke test-host ## Everything this machine can prove of the live platform

# hazard: the admission specs create and delete namespaces and a PV, and impersonate app
# identities: never the live cluster. KUBECONFIG names a throwaway one (k3d), and
# CLUSTER_KUBECTL is cleared so the orb default cannot win.
test-admission: harness/node_modules/.install ## The ownership policy's cases on a throwaway cluster (KUBECONFIG=<k3d kubeconfig>)
	@test -n "$(KUBECONFIG)" || { echo "✗ KUBECONFIG must name a throwaway cluster (k3d kubeconfig get <name>)"; exit 1; }
	cd harness && CLUSTER_KUBECTL= npx vitest --run specs/admission

# invariant: the deploy tools first, then the four `make check` hard-fails on: a green
# check-tools that omits them just moves the failure to the next target.
check-tools: ## Check required tools
	@command -v ansible     >/dev/null 2>&1 && echo "✓ Ansible"      || echo "✗ Ansible"
	@command -v kubectl     >/dev/null 2>&1 && echo "✓ kubectl"      || echo "✗ kubectl"
	@command -v orbctl      >/dev/null 2>&1 && echo "✓ orbctl"       || echo "✗ orbctl"
	@command -v helm        >/dev/null 2>&1 && echo "✓ Helm"         || echo "✗ Helm"
	@command -v helmfile    >/dev/null 2>&1 && echo "✓ helmfile"     || echo "✗ helmfile"
	@command -v shellcheck  >/dev/null 2>&1 && echo "✓ shellcheck"   || echo "✗ shellcheck"
	@command -v ansible-lint >/dev/null 2>&1 && echo "✓ ansible-lint" || echo "✗ ansible-lint"
	@command -v python3     >/dev/null 2>&1 && echo "✓ python3"      || echo "✗ python3"


# invariant: a missing tool is a hard failure; the soft skips (actionlint,
# helm-unittest, npx) are the ones CI re-runs unconditionally.
check: ## Run the checks CI runs (shellcheck, ansible-lint, helm lint + unittest, actionlint, content check)
	@echo "== shellcheck scripts/ =="
	shellcheck scripts/*.sh scripts/lib/*.sh
	@echo "✓ shellcheck clean"
	@echo ""
	@echo "== ansible-lint ansible/ =="
	ansible-lint -c ansible/.ansible-lint ansible/
	@echo "✓ ansible-lint clean"
	@echo ""
	@echo "== helm lint (common, app, platform-service) =="
	@# `common` is a library chart, linted alone; its consumers need a local
	@# `helm dependency update` before helm renders them.
	helm lint kubernetes/charts/common
	@for chart in app platform-service; do \
		fixture="kubernetes/charts/$$chart/ci/test-values.yaml"; \
		if [ ! -f "$$fixture" ]; then \
			echo "✗ $$fixture missing: the fixture IS the validation contract for this chart"; \
			exit 1; \
		fi; \
		helm dependency update "kubernetes/charts/$$chart" >/dev/null || exit 1; \
		helm lint "kubernetes/charts/$$chart" -f "$$fixture" || exit 1; \
	done
	@echo "✓ helm lint clean"
	@echo ""
	@echo "== helm unittest (app, platform-service) =="
	@# These assert what the templates COMPUTED, which lint cannot see.
	@if helm plugin list 2>/dev/null | awk '{print $$1}' | grep -qx unittest; then \
		helm unittest --strict kubernetes/charts/app kubernetes/charts/platform-service || exit 1; \
	else \
		echo "⚠ helm-unittest not installed, skipped. Install with:"; \
		echo "    helm plugin install https://github.com/helm-unittest/helm-unittest --version $(HELM_UNITTEST_VERSION)"; \
		echo "    (add --verify=false on helm 4; the plugin ships no signature)"; \
	fi
	@echo ""
	@echo "== actionlint .github/workflows =="
	@if command -v actionlint >/dev/null 2>&1; then \
		actionlint && echo "✓ actionlint clean"; \
	else \
		echo "⚠ actionlint not installed (brew install actionlint), skipped"; \
	fi
	@echo ""
	@echo "== content check, harness check =="
	@if command -v npx >/dev/null 2>&1; then \
		$(MAKE) --no-print-directory docs harness-check; \
	else \
		echo "⚠ npx not installed (node), skipped"; \
	fi

# value: pinned: `@latest` would turn a green tree red the day a release adds rules.
# hazard: `--package` + the bin name, never the short form: npm infers `typescript`,
# which collides with a dependency and crashed on the runner (`edgesOut`).
docs: ## Check the repository as content (manual layout, Markdown, comments, names, secrets)
	npx --yes --package=@jterrazz/typescript@11.0.0 -- typescript check

# invariant: the harness is a TypeScript project of its own, judged by its own pinned toolchain.
harness-check: harness/node_modules/.install ## Check the harness (types, lint, format, test conventions)
	cd harness && npx typescript check

# invariant: `lint` is the name in every app repo's universal CI interface (make build /
# lint / test); `check` is what this target actually is.
lint: check


help:
	@printf "$(GREEN)jterrazz infrastructure$(NC)\n"
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z0-9_-]+:.*##/ { printf "  $(YELLOW)%-16s$(NC) %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@echo ""

print-helm-unittest-version:
	@echo $(HELM_UNITTEST_VERSION)
