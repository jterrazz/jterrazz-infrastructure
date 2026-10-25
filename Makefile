# outside: one k3s cluster on an OrbStack VM on this Mac; src/scripts/deploy.sh is the entry point.

.DEFAULT_GOAL := help
.PHONY: help deploy deploy-platform destroy redeploy-apps kubeconfig diff backup smoke test-host test test-admission check-tools check lint check-docs check-specs print-helm-unittest-version

VM_NAME := jterrazz-infrastructure
KUBECONFIG_FILE := kubeconfig.yaml
NODE_FQDN := $(shell awk '/ansible_host:/ {print $$2; exit}' src/ansible/inventories/ci.yml)
# invariant: snapshots reproduce only against the helm-unittest that wrote them; validate.yaml
# reads this pin through `make print-helm-unittest-version`.
HELM_UNITTEST_VERSION := v1.1.2

# outside: the suite reaches the cluster and the node through OrbStack, with no tailnet;
# `CLUSTER_KUBECTL=` falls back to $$KUBECONFIG, then ./kubeconfig.yaml.
CLUSTER_KUBECTL ?= orb -m $(VM_NAME) -u root kubectl
HOST_SHELL ?= orb -m $(VM_NAME) -u root
export CLUSTER_KUBECTL HOST_SHELL

# invariant: the Mac is the internet vantage unless its Tailscale is up (docs/guides/test.md).
VANTAGE ?= internet
SPECS_internet := specs/api/routes/public specs/api/certificates/public specs/api/boundary specs/cluster specs/health
SPECS_tailnet := specs/api/routes specs/api/certificates specs/cluster specs/health

deploy: ## Create the VM if absent, then configure it (Ansible site.yml)
	./src/scripts/deploy.sh

deploy-platform: ## Re-run the platform layer only (Ansible platform.yml)
	./src/scripts/deploy.sh --platform

destroy: ## Delete the VM (the data on the Mac stays)
	./src/scripts/deploy.sh --destroy

redeploy-apps: ## Trigger every app's CI to rebuild and redeploy (ARGS=--dry-run | "--from FILE")
	@./src/scripts/redeploy-apps.sh $(ARGS)

specs/node_modules/.install: specs/package-lock.json
	cd specs && npm ci
	@touch specs/node_modules/.install

# invariant: k3s writes a loopback server address; the MagicDNS rewrite makes the file usable
# from a tailnet client.
kubeconfig: ## Regenerate ./kubeconfig.yaml from the VM (server = MagicDNS name)
	@orb -m $(VM_NAME) -u root cat /etc/rancher/k3s/k3s.yaml \
		| sed -E 's#https://(127\.0\.0\.1|0\.0\.0\.0):6443#https://$(NODE_FQDN):6443#' > $(KUBECONFIG_FILE)
	@chmod 600 $(KUBECONFIG_FILE)
	@grep -q 'server: https://$(NODE_FQDN):6443' $(KUBECONFIG_FILE) \
		|| { echo "✗ server address not rewritten in $(KUBECONFIG_FILE)"; exit 1; }
	@echo "✓ $(KUBECONFIG_FILE) points at https://$(NODE_FQDN):6443 (needs the tailnet)"

diff: ## Preview what a platform deploy would change (helmfile diff, read-only)
	./src/scripts/helmfile.sh diff

backup: ## Encrypted snapshot of every persistent volume (ARGS=--consistent stops the workloads)
	@./src/scripts/backup.sh $(ARGS)

smoke: specs/node_modules/.install ## The platform contract from this Mac (VANTAGE=tailnet on the tailnet)
	cd specs && npx vitest --run $(SPECS_$(VANTAGE))

test-host: specs/node_modules/.install ## The node itself: sshd, the nft guard, upgrades, k3s
	cd specs && npx vitest --run --no-file-parallelism specs/host

test: smoke test-host ## Everything this Mac can prove of the live platform

# hazard: the admission specs create namespaces and impersonate app identities: a throwaway
# cluster only, so CLUSTER_KUBECTL is cleared and KUBECONFIG must name it.
test-admission: specs/node_modules/.install ## The admission policies' cases: app-deployer ownership, host access (KUBECONFIG=<k3d kubeconfig>)
	@test -n "$(KUBECONFIG)" || { echo "✗ KUBECONFIG must name a throwaway cluster"; exit 1; }
	cd specs && CLUSTER_KUBECTL= npx vitest --run specs/admission

check-tools: ## Check the required tools are installed
	@for tool in ansible ansible-lint kubectl orbctl helm helmfile shellcheck node; do \
		command -v $$tool >/dev/null 2>&1 && echo "✓ $$tool" || echo "✗ $$tool"; \
	done

# invariant: a missing tool fails; actionlint, helm-unittest and node are soft skips only
# because validate.yaml runs them unconditionally.
check: ## Run the checks CI runs on the tree
	shellcheck src/scripts/*.sh src/scripts/lib/*.sh
	ansible-lint -c src/ansible/.ansible-lint src/ansible/
	helm lint src/kubernetes/charts/common
	@for chart in app platform-service; do \
		helm dependency update src/kubernetes/charts/$$chart >/dev/null && \
		helm lint src/kubernetes/charts/$$chart -f src/kubernetes/charts/$$chart/ci/test-values.yaml || exit 1; \
	done
	@if helm plugin list 2>/dev/null | awk '$$1 == "unittest" { found = 1 } END { exit !found }'; then \
		helm unittest --strict src/kubernetes/charts/app src/kubernetes/charts/platform-service; \
	else \
		echo "⚠ helm-unittest skipped: helm plugin install https://github.com/helm-unittest/helm-unittest --version $(HELM_UNITTEST_VERSION) --verify=false"; \
	fi
	@if command -v actionlint >/dev/null 2>&1; then actionlint; else echo "⚠ actionlint skipped: brew install actionlint"; fi
	@if command -v npx >/dev/null 2>&1; then $(MAKE) --no-print-directory check-docs check-specs; else echo "⚠ check-docs and check-specs skipped: no node"; fi

# value: pinned, since `@latest` turns a green tree red the day a release adds rules.
# hazard: `--package` plus the bin name: npm infers `typescript` from the short form, which
# collides with a dependency (ADR-020).
check-docs: ## Check the repository as content (manual layout, Markdown, comments, names, secrets)
	npx --yes --package=@jterrazz/typescript@11.3.0 -- typescript check

check-specs: specs/node_modules/.install ## Check the specs project (types, lint, format, test conventions)
	cd specs && npx typescript check

# invariant: `lint` is the name every app repo's CI interface uses.
lint: check

help:
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z0-9_-]+:.*##/ { printf "  \033[33m%-16s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

print-helm-unittest-version:
	@echo $(HELM_UNITTEST_VERSION)
