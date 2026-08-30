#!/bin/bash
# Create the cluster's VM with orbctl and configure it with Ansible.
#
# Ansible's secrets are pulled live from Infisical by
# scripts/infisical-vars.py using the universal-auth credentials in
# `.env`. Nothing sensitive lands on disk beyond the temp extra-vars file —
# 0600, deleted on exit by the trap below.
#
# Usage:
#   ./scripts/deploy.sh                 # full: create the VM if absent + site.yml
#   ./scripts/deploy.sh --ansible-only  # site.yml only, assume the VM exists
#   ./scripts/deploy.sh --platform      # platform.yml only (no host layer)
#   ./scripts/deploy.sh --destroy       # delete the VM (Mac-side data stays)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

# One string, three identities: the `orbctl list` name, the Ansible
# inventory_hostname in inventories/laptop.yml, and the Tailscale hostname the
# `*.internal` wildcard CNAME resolves to. Renaming it here alone joins the
# tailnet under a new name and breaks every private hostname.
VM_NAME="jterrazz-infrastructure"
VM_DATA_DIR="$HOME/.jterrazz-infrastructure/data"
INVENTORY="$PROJECT_DIR/ansible/inventories/laptop.yml"

if [ ! -f "$PROJECT_DIR/.env" ]; then
    error "Missing $PROJECT_DIR/.env"
    error "It must define INFISICAL_CLIENT_ID and INFISICAL_CLIENT_SECRET."
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

# The whole provisioning layer: one OrbStack VM. Idempotent by probe rather
# than by state file — `orbctl info` is the question "does this VM exist", and
# it is the only question, because OrbStack can change neither image nor
# architecture in place. To repave, `--destroy` then run this again.
vm_up() {
    # First and unconditionally: roles/base symlinks /var/lib/k8s-data at this
    # directory through OrbStack's /mnt/mac share, and if it does not exist
    # before the VM boots the symlink dangles and every hostPath mount fails at
    # the first pod schedule. Its living on the Mac is also what makes the data
    # survive `make destroy && make deploy` — the VM goes, the directory stays.
    mkdir -p "$VM_DATA_DIR"

    if orbctl info "$VM_NAME" >/dev/null 2>&1; then
        info "OrbStack VM $VM_NAME exists — skipping create"
        return
    fi

    info "orbctl create debian:trixie $VM_NAME"
    # `debian:trixie` SPELLED OUT: Debian is the one distro whose bare image
    # name resolves to the PREVIOUS stable (bookworm), and every Ansible role
    # here is Debian-13-native. Never drop the tag.
    #
    # NO `-u root`: broken since OrbStack 2.2.0, whose setup runs
    # `usermod --uid 501 root` and fails against PID 1. The VM keeps the
    # default macOS-named user; Ansible connects as `root@<vm>@orb`.
    #
    # NO `--isolated`: isolated machines run in an unprivileged user namespace
    # where the kernel refuses the `noswap` tmpfs kubelet needs for projected
    # service-account tokens, so k3s never serves — and it is also what turns
    # off the /mnt/mac auto-share the data symlink above resolves through.
    orbctl create -a arm64 debian:trixie "$VM_NAME"
}

vm_destroy() {
    info "orbctl delete --force $VM_NAME (the Mac-side data directory stays)"
    orbctl delete --force "$VM_NAME"
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
        vm_destroy
        ;;
    --ansible-only)
        run_site
        ;;
    --platform)
        run_platform
        ;;
    "")
        vm_up
        run_site
        ;;
    *)
        error "Unknown flag: $1"
        error "Usage: $0 [--ansible-only | --platform | --destroy]"
        exit 1
        ;;
esac
