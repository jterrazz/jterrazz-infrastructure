#!/bin/bash
# outside: helmfile against the live cluster from this Mac, the preview before a platform
# deploy; it writes nothing unless the subcommand does. Needs a kubeconfig (`make kubeconfig`).
#
#   make diff                                   # every release, read-only
#   ./src/scripts/helmfile.sh diff -l name=grafana  # one release

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

: "${KUBECONFIG:=$PROJECT_DIR/kubeconfig.yaml}"
export KUBECONFIG
export NODE_NAME="${NODE_NAME:-jterrazz-infrastructure}"
# invariant: helm-diff redacts Secrets, so a preview needs no real password.
export GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-preview-placeholder}"

if ! kubectl version >/dev/null 2>&1; then
    error "Cannot reach the cluster with KUBECONFIG=$KUBECONFIG: is the VM up (orb list), this Mac on the tailnet, and the file current (make kubeconfig)?"
    exit 1
fi
command -v helmfile >/dev/null 2>&1 || { error "helmfile is not installed (brew install helmfile)"; exit 1; }

if ! helm plugin list 2>/dev/null | awk '$1 == "diff" { found = 1 } END { exit !found }'; then
    version=$(awk '$1 == "helm_diff_version:" { gsub(/"/, "", $2); print $2 }' "$PROJECT_DIR/src/ansible/inventories/group_vars/all/versions.yml")
    info "Installing helm-diff $version"
    helm plugin install https://github.com/databus23/helm-diff --version "$version" --verify=false
fi

exec helmfile --file "$PROJECT_DIR/src/kubernetes/helmfile.yaml.gotmpl" "$@"
