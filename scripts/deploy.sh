#!/bin/bash
# Provision the cluster via Pulumi and configure it with Ansible.
#
# Ansible's secrets are pulled live from Infisical by
# scripts/infisical-vars.py using the universal-auth credentials in
# `.env`. Nothing sensitive lands on disk beyond the temp extra-vars file —
# 0600, deleted on exit by the trap below.
#
# Usage:
#   ./scripts/deploy.sh                 # full: pulumi up + site.yml
#   ./scripts/deploy.sh --ansible-only  # site.yml only, assume the VM exists
#   ./scripts/deploy.sh --platform      # platform.yml only (no host layer)
#   ./scripts/deploy.sh --destroy       # tear down the stack

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

STACK="jterrazz/local"
INVENTORY="$PROJECT_DIR/ansible/inventories/laptop.yml"

if [ ! -f "$PROJECT_DIR/.env" ]; then
    error "Missing $PROJECT_DIR/.env"
    error "It must define PULUMI_ACCESS_TOKEN, INFISICAL_CLIENT_ID and INFISICAL_CLIENT_SECRET."
    error "See 'Local .env' in docs/RUNBOOK.md; the file is gitignored on purpose."
    exit 1
fi
set -a
# shellcheck disable=SC1091
source "$PROJECT_DIR/.env"
set +a

# Script-scope and declared BEFORE the trap so cleanup sees it however the
# script exits, including a failure partway through the fetch. `${var:-}` keeps
# `rm -f` from tripping `set -u` if the path was never populated.
secrets_file=""
trap 'rm -f "${secrets_file:-}"' EXIT

pulumi_up() {
    cd "$PROJECT_DIR/pulumi"
    info "pulumi up --stack $STACK"
    pulumi stack select "$STACK"
    pulumi up --yes --refresh
}

pulumi_destroy() {
    cd "$PROJECT_DIR/pulumi"
    info "pulumi destroy --stack $STACK"
    pulumi stack select "$STACK"
    pulumi destroy --yes --refresh
}

# Sets the script-scope $secrets_file instead of echoing the path: command
# substitution would run this in a SUBSHELL, so the assignment made right after
# `mktemp` would never reach the parent and the EXIT trap would leak the
# tempfile whenever the fetch failed partway.
fetch_secrets_file() {
    local scope="$1"
    secrets_file=$(mktemp -t jterrazz-infrastructure-vars-XXXXXX.yml)
    "$SCRIPT_DIR/infisical-vars.py" "$scope" "$secrets_file"
}

# Without this a fresh machine silently uses whatever collections the local
# ansible install happens to bundle, which may not satisfy requirements.yml.
# Idempotent — ansible-galaxy skips collections already at the pinned version.
install_collections() {
    info "Installing Ansible collections (requirements.yml)"
    ansible-galaxy collection install -r "$PROJECT_DIR/ansible/requirements.yml"
}

run_site() {
    fetch_secrets_file site
    # ansible.cfg has a relative roles_path, so this must run from ansible/.
    cd "$PROJECT_DIR/ansible"
    install_collections
    info "ansible-playbook site.yml"
    ansible-playbook playbooks/site.yml -i "$INVENTORY" -e "@$secrets_file"
}

run_platform() {
    fetch_secrets_file platform
    cd "$PROJECT_DIR/ansible"
    install_collections
    info "ansible-playbook platform.yml"
    ansible-playbook playbooks/platform.yml -i "$INVENTORY" -e "@$secrets_file"
}

case "${1:-}" in
    --destroy)
        pulumi_destroy
        ;;
    --ansible-only)
        run_site
        ;;
    --platform)
        run_platform
        ;;
    "")
        pulumi_up
        run_site
        ;;
    *)
        error "Unknown flag: $1"
        error "Usage: $0 [--ansible-only | --platform | --destroy]"
        exit 1
        ;;
esac
