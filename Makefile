# jterrazz infrastructure
#
# One k3s cluster: an OrbStack VM on the dev Mac. `make deploy` provisions it
# (Pulumi) and configures it (Ansible); `scripts/deploy.sh` is the canonical
# entry point.

.DEFAULT_GOAL := help
.PHONY: help deploy deploy-platform destroy redeploy-apps check-tools check lint diff smoke backup kubeconfig

GREEN := \033[32m
YELLOW := \033[33m
BLUE := \033[34m
NC := \033[0m

# The OrbStack VM, and the node's MagicDNS name read out of the CI inventory
# rather than written down a third time (roles/k3s/tasks/kubeconfig.yml and
# inventories/ci.yml are the other two places it appears).
VM_NAME := jterrazz-infrastructure
KUBECONFIG_FILE := kubeconfig.yaml
NODE_FQDN := $(shell awk '/ansible_host:/ {print $$2; exit}' ansible/inventories/ci.yml)

##@ Deploy

deploy: ## Provision + configure the cluster (Pulumi + Ansible site.yml)
	./scripts/deploy.sh

deploy-platform: ## Re-run the platform layer only (Ansible platform.yml)
	./scripts/deploy.sh --platform

destroy: ## Tear down the OrbStack VM (data on the Mac stays)
	./scripts/deploy.sh --destroy

redeploy-apps: ## Trigger every app's CI to rebuild+redeploy (bootstrap after cluster rebuild)
	./scripts/trigger-app-deploys.sh

##@ Utilities

# `make deploy` writes kubeconfig.yaml as a side effect (roles/k3s/tasks/
# kubeconfig.yml); this is the same two steps on their own, for the far more
# common case of "the file is stale/gone and I only want to look at the
# cluster". k3s writes a loopback server address, which is useless from the
# Mac — the rewrite to the MagicDNS name is what makes the fetched file usable.
kubeconfig: ## Regenerate ./kubeconfig.yaml from the VM (server = MagicDNS name)
	@test -n "$(NODE_FQDN)" || { echo "✗ no ansible_host in ansible/inventories/ci.yml"; exit 1; }
	@orb -m $(VM_NAME) -u root cat /etc/rancher/k3s/k3s.yaml > $(KUBECONFIG_FILE).tmp \
		|| { rm -f $(KUBECONFIG_FILE).tmp; echo "✗ could not read k3s.yaml from $(VM_NAME) (orb list?)"; exit 1; }
	@sed -E 's#https://(127\.0\.0\.1|0\.0\.0\.0):6443#https://$(NODE_FQDN):6443#' \
		$(KUBECONFIG_FILE).tmp > $(KUBECONFIG_FILE)
	@rm -f $(KUBECONFIG_FILE).tmp
	@chmod 600 $(KUBECONFIG_FILE)
	@grep -q 'server: https://$(NODE_FQDN):6443' $(KUBECONFIG_FILE) \
		|| { echo "✗ server address not rewritten — k3s wrote something other than 127.0.0.1/0.0.0.0"; exit 1; }
	@echo "✓ $(KUBECONFIG_FILE) → https://$(NODE_FQDN):6443 (needs the tailnet)"

# Read-only preview against the LIVE cluster, meant to be run BEFORE
# `make deploy-platform`: that play runs `helmfile apply` over
# kubernetes/helmfile.yaml.gotmpl, so a bumped chart version or an edited
# helm.yaml lands the moment it runs. This shows what would change first.
# Installs the helm-diff plugin on first use; needs a working kubeconfig
# (./kubeconfig.yaml by default, override with KUBECONFIG=...). Narrow it to
# one release: `./scripts/helmfile.sh diff -l name=grafana`.
diff: ## Preview what `make deploy-platform` would change (helmfile diff, read-only)
	./scripts/helmfile.sh diff

backup: ## Encrypted snapshot of every persistent volume (ARGS=--consistent for a torn-free copy)
	@./scripts/backup.sh $(ARGS)

# Black-box probe of the deployed surfaces. `--public` needs nothing;
# `--private` and the private half of `--certs` need this machine to be on the
# tailnet, so they are left out of the default target here — CI
# (.github/workflows/smoke.yaml) runs the full set from a runner that joins it.
smoke: ## Probe the public surfaces + their TLS expiry (ARGS=--private on the tailnet)
	./scripts/smoke.sh --public --certs $(ARGS)

# The deploy tools first, then the four `make check` hard-fails on — a green
# check-tools that omits them just moves the failure to the next target.
check-tools: ## Check required tools
	@command -v ansible     >/dev/null 2>&1 && echo "✓ Ansible"      || echo "✗ Ansible"
	@command -v pulumi      >/dev/null 2>&1 && echo "✓ Pulumi"       || echo "✗ Pulumi"
	@command -v node        >/dev/null 2>&1 && echo "✓ Node.js"      || echo "✗ Node.js"
	@command -v kubectl     >/dev/null 2>&1 && echo "✓ kubectl"      || echo "✗ kubectl"
	@command -v orbctl      >/dev/null 2>&1 && echo "✓ orbctl"       || echo "✗ orbctl"
	@command -v helm        >/dev/null 2>&1 && echo "✓ Helm"         || echo "✗ Helm"
	@command -v helmfile    >/dev/null 2>&1 && echo "✓ helmfile"     || echo "✗ helmfile"
	@command -v shellcheck  >/dev/null 2>&1 && echo "✓ shellcheck"   || echo "✗ shellcheck"
	@command -v ansible-lint >/dev/null 2>&1 && echo "✓ ansible-lint" || echo "✗ ansible-lint"
	@command -v python3     >/dev/null 2>&1 && echo "✓ python3"      || echo "✗ python3"

##@ Check

# Deliberately strict: a missing tool is a hard failure, so this can never
# print all green on a machine where it checked nothing. Install them with:
#   brew install shellcheck helm actionlint
#   pip install ansible-core ansible-lint
# actionlint and helm-unittest are the two soft skips — CI re-runs both
# unconditionally, so a laptop without them is not a gap in the gate.
check: ## Run the checks CI runs (shellcheck, python, sync assertions, tsc, ansible-lint, helm lint + unittest, actionlint)
	@echo "== shellcheck scripts/ =="
	shellcheck scripts/*.sh scripts/lib/*.sh
	@echo "✓ shellcheck clean"
	@echo ""
	@echo "== python syntax scripts/ =="
	@# ast.parse rather than py_compile: same syntax check, no __pycache__/ left
	@# behind in the working tree.
	@for f in scripts/infisical-vars.py scripts/assert-sync.py; do \
		python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read(), sys.argv[1])" "$$f" || exit 1; \
	done
	@echo "✓ python clean"
	@echo ""
	@echo "== cross-file sync assertions =="
	@# Facts this repo has to write down twice (the Infisical var map vs the
	@# Ansible preflight assert, Traefik's trustedIPs vs the rate-limit
	@# excludedIPs, the four Helm/helmfile/ansible-core/helm-unittest version
	@# pins, the busybox digest, the smoke table vs both the private hostnames
	@# and the app repo list, the two app-chart publish guards). Each pair
	@# carries a "keep in sync" comment; this is what actually checks them.
	python3 scripts/assert-sync.py
	@echo ""
	@echo "== pulumi typecheck =="
	@# The `pulumi` job in validate.yaml runs exactly this after `npm ci`.
	@test -d pulumi/node_modules || { echo "✗ pulumi/node_modules missing — run: npm ci --prefix pulumi"; exit 1; }
	cd pulumi && npx tsc --noEmit
	@echo "✓ tsc clean"
	@echo ""
	@echo "== ansible-lint ansible/ =="
	ansible-lint -c ansible/.ansible-lint ansible/
	@echo "✓ ansible-lint clean"
	@echo ""
	@echo "== helm lint (app, service) =="
	@for chart in app service; do \
		fixture="kubernetes/charts/$$chart/ci/test-values.yaml"; \
		if [ ! -f "$$fixture" ]; then \
			echo "✗ $$fixture missing — the fixture IS the validation contract for this chart"; \
			exit 1; \
		fi; \
		helm lint "kubernetes/charts/$$chart" -f "$$fixture" || exit 1; \
	done
	@echo "✓ helm lint clean"
	@echo ""
	@echo "== helm unittest (app, service) =="
	@# helm lint + kubeconform only prove the rendered YAML is well-formed and
	@# schema-valid. These assert what the templates COMPUTED: the NODE_OPTIONS
	@# floor, the Mi/Gi parser, the dockerconfigjson escaping, which ipAllowList
	@# an `access:` value selects. The plugin is a soft skip (like actionlint)
	@# because CI installs and runs it unconditionally.
	@if helm plugin list 2>/dev/null | awk '{print $$1}' | grep -qx unittest; then \
		helm unittest --strict kubernetes/charts/app kubernetes/charts/service || exit 1; \
	else \
		echo "⚠ helm-unittest not installed — skipped. Install with:"; \
		echo "    helm plugin install https://github.com/helm-unittest/helm-unittest --version v1.1.2"; \
		echo "    (add --verify=false on helm 4; the plugin ships no signature)"; \
	fi
	@echo ""
	@echo "== actionlint .github/workflows =="
	@if command -v actionlint >/dev/null 2>&1; then \
		actionlint && echo "✓ actionlint clean"; \
	else \
		echo "⚠ actionlint not installed (brew install actionlint) — skipped"; \
	fi

# `lint` is the name in every app repo's universal CI interface (make build /
# lint / test); `check` is what this target actually is.
lint: check

##@ Help

help:
	@printf "$(GREEN)jterrazz infrastructure$(NC)\n"
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z0-9_-]+:.*##/ { printf "  $(YELLOW)%-16s$(NC) %s\n", $$1, $$2 } /^##@/ { printf "\n$(BLUE)%s$(NC)\n", substr($$0, 5) }' $(MAKEFILE_LIST)
	@echo ""
