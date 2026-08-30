#!/bin/bash
# Run helmfile against kubernetes/helmfile.yaml.gotmpl from THIS machine,
# rather than from the node the way roles/platform does.
#
# Usage:
#   make diff                                  # everything, read-only
#   ./scripts/helmfile.sh diff -l name=grafana # one release
#   ./scripts/helmfile.sh list
#   KUBECONFIG=/path/to/kc ./scripts/helmfile.sh diff
#
# `make deploy-platform` is what APPLIES; this is the pre-flight for it. That
# play runs `helmfile apply`, so a bumped chart version or an edited values.yaml
# lands the moment it runs — this shows what would change first. Nothing here
# writes to the cluster unless you pass a subcommand that does.
#
# Needs the tailnet: kubeconfig.yaml points at the node's MagicDNS name.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/helm-plugin.sh"

GROUP_VARS="$PROJECT_DIR/ansible/inventories/group_vars/all.yml"
HELMFILE="$PROJECT_DIR/kubernetes/helmfile.yaml.gotmpl"

# Both versions come from group_vars, which is where the node's install reads
# them too — one pin, two machines.
group_var() {
    awk -v key="$1:" '$1 == key { gsub(/"/, "", $2); print $2; exit }' "$GROUP_VARS"
}

: "${KUBECONFIG:=$PROJECT_DIR/kubeconfig.yaml}"
export KUBECONFIG

# The hostPath PV's nodeAffinity target — the one value the helmfile takes from
# its caller rather than a values file. Ansible passes inventory_hostname.
export NODE_NAME="${NODE_NAME:-jterrazz-infrastructure}"

# Only ever read by the `grafana` release, and only at apply time. A preview
# from a laptop has no business fetching the real one: helm-diff redacts Secret
# contents by default, so the placeholder changes nothing you can see.
export GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-preview-placeholder}"

require_kubeconfig() {
    if [ ! -f "$KUBECONFIG" ]; then
        error "No kubeconfig at $KUBECONFIG"
        error "This talks to the LIVE cluster, so it needs one."
        error "Generate it with:  make kubeconfig"
        error "(or point KUBECONFIG at an existing one)."
        exit 1
    fi
    if ! kubectl version -o yaml >/dev/null 2>&1; then
        error "Cannot reach the cluster with KUBECONFIG=$KUBECONFIG"
        error "The VM may be down (orb list), this Mac may be off the tailnet,"
        error "or the kubeconfig may predate the last repave."
        exit 1
    fi
}

require_helmfile() {
    if command -v helmfile >/dev/null 2>&1; then
        return
    fi
    error "helmfile is not installed (brew install helmfile)."
    error "The node's copy is pinned to $(group_var helmfile_version) by roles/platform."
    exit 1
}

# helmfile apply/diff IS helm-diff — without the plugin there is no preview and
# no deploy.
require_helm_diff() {
    local want
    want="$(group_var helm_diff_version)"
    if helm plugin list 2>/dev/null | awk '{print $1}' | grep -qx diff; then
        return
    fi
    info "helm-diff plugin missing — installing $want"
    helm_plugin_install https://github.com/databus23/helm-diff "$want"
}

require_kubeconfig
require_helmfile
require_helm_diff

exec helmfile --file "$HELMFILE" "$@"
