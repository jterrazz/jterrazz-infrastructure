#!/bin/bash
# Shared logging helpers. Source it:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export BLUE='\033[0;34m'
export NC='\033[0m'

info() { echo -e "${BLUE}→ $1${NC}"; }
success() { echo -e "${GREEN}✓ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠ $1${NC}"; }
error() { echo -e "${RED}✗ $1${NC}" >&2; }
section() { echo -e "\n${GREEN}▶ $1${NC}"; }

# ---------------------------------------------------------------------------
# One read path to the cluster, shared by smoke.sh and trigger-app-deploys.sh.
# Both DISCOVER what they act on from live objects, so both need the same
# question answered: how does this machine reach the API server?
#
#   CLUSTER_KUBECTL   a full kubectl command to use instead. From the dev Mac
#                     when Tailscale is down:
#                       CLUSTER_KUBECTL="orb -m jterrazz-infrastructure -u root kubectl"
#   CLUSTER_SSH_KEY   path to the CI deploy key — runs kubectl on the node over
#                     SSH. What .github/workflows/smoke.yaml uses: the keypair
#                     deploy-platform.yaml already has, and no KUBECONFIG_BASE64
#                     to refresh after a repave.
#   neither           kubectl against $KUBECONFIG, else ./kubeconfig.yaml
#                     (`make kubeconfig`). Needs the tailnet.
#
# The node's MagicDNS name comes out of the CI inventory rather than being
# written down again — the same source the Makefile reads.
cluster_kubectl() {
    local repo_dir node
    repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

    if [ -n "${CLUSTER_KUBECTL:-}" ]; then
        # Deliberately unquoted: the value is a command line, not one word.
        # shellcheck disable=SC2086
        $CLUSTER_KUBECTL "$@"
    elif [ -n "${CLUSTER_SSH_KEY:-}" ]; then
        node="$(awk '/ansible_host:/ {print $2; exit}' "$repo_dir/ansible/inventories/ci.yml")"
        ssh -i "$CLUSTER_SSH_KEY" \
            -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o IdentitiesOnly=yes -o LogLevel=ERROR \
            "root@$node" "kubectl $*"
    else
        kubectl --kubeconfig "${KUBECONFIG:-$repo_dir/kubeconfig.yaml}" "$@"
    fi
}

# The advice every caller prints when the read above fails.
cluster_access_hint() {
    error "Reach the cluster one of three ways:"
    error "  CLUSTER_KUBECTL=\"orb -m jterrazz-infrastructure -u root kubectl\"  (from the Mac, no tailnet needed)"
    error "  CLUSTER_SSH_KEY=<path to the CI deploy key>                        (what CI uses)"
    error "  make kubeconfig                                                    (needs the tailnet)"
}
