#!/bin/bash
# outside: creates the VM with orbctl when absent, then runs Ansible; the play fetches its own
# secrets with the Infisical identity exported from `.env`.
#
#   ./src/scripts/deploy.sh             # create the VM if absent + site.yml
#   ./src/scripts/deploy.sh --platform  # platform.yml only
#   ./src/scripts/deploy.sh --destroy   # delete the VM (the Mac-side data stays)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

# hazard: one string, three identities: the OrbStack machine, the inventory host and the
# Tailscale hostname the private wildcards resolve to.
VM_NAME="jterrazz-infrastructure"
VM_DATA_DIR="$HOME/.jterrazz-infrastructure/data"
INVENTORY="$PROJECT_DIR/src/ansible/inventories/laptop.yml"

if [ ! -f "$PROJECT_DIR/.env" ]; then
    error "Missing $PROJECT_DIR/.env: it must define INFISICAL_CLIENT_ID and INFISICAL_CLIENT_SECRET."
    exit 1
fi
set -a
# shellcheck disable=SC1091
source "$PROJECT_DIR/.env"
set +a

# invariant: the VM's existence is the only provisioning state (ADR-004).
vm_up() {
    # hazard: before the VM boots: roles/base links /var/lib/k8s-data here through /mnt/mac,
    # and a dangling link fails every hostPath mount.
    mkdir -p "$VM_DATA_DIR"

    if orbctl info "$VM_NAME" >/dev/null 2>&1; then
        info "OrbStack VM $VM_NAME exists, skipping create"
        return
    fi

    # hazard: `debian:trixie` spelled out (a bare `debian` is bookworm); no `-u root` (broken
    # since OrbStack 2.2.0); no `--isolated` (k3s never serves, and /mnt/mac disappears).
    info "orbctl create debian:trixie $VM_NAME"
    orbctl create -a arm64 debian:trixie "$VM_NAME"
}

run_playbook() {
    # invariant: from src/ansible, whose ansible.cfg has a relative roles_path.
    cd "$PROJECT_DIR/src/ansible"
    ansible-galaxy collection install -r requirements.yml
    ansible-playbook "playbooks/$1" -i "$INVENTORY"
}

case "${1:-}" in
    "")
        vm_up
        run_playbook site.yml
        ;;
    --platform)
        run_playbook platform.yml
        ;;
    --destroy)
        info "orbctl delete --force $VM_NAME (the Mac-side data directory stays)"
        orbctl delete --force "$VM_NAME"
        ;;
    *)
        error "Usage: $0 [--platform | --destroy]"
        exit 1
        ;;
esac
