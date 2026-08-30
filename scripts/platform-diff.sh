#!/bin/bash
# Pre-flight for `make deploy-platform`: what WOULD the next platform deploy
# change on the live cluster?
#
# `ansible-playbook platform.yml` runs `helm upgrade --install` for every
# release below. That is idempotent in the "same inputs, same output" sense,
# but it is not a no-op preview: a bumped chart version in group_vars, an
# edited helm.yaml, or upstream defaults that moved between two chart versions
# all land the moment the play runs. This prints the diff first.
#
# Read-only. It never installs, upgrades or deletes anything.
#
# Usage:
#   make diff                      # uses ./kubeconfig.yaml
#   KUBECONFIG=/path/to/kc make diff
#   ./scripts/platform-diff.sh grafana victoria-logs   # only these releases
#
# Secrets are suppressed in the output (--suppress-secrets): the Grafana admin
# password and the registry credentials would otherwise be printed in full.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/helm-plugin.sh"

GROUP_VARS="$PROJECT_DIR/ansible/inventories/group_vars/all.yml"
SERVICE_CHART="$PROJECT_DIR/kubernetes/charts/service"

# Pinned. The plugin renders the chart and talks to the cluster, so an
# uncontrolled version is an uncontrolled preview.
HELM_DIFF_VERSION="v3.15.10"

# hostPath PV nodeAffinity, the one value Ansible injects that isn't in a
# values file (roles/platform/tasks/service-charts.yml passes
# --set infrastructure.nodeName={{ inventory_hostname }}). Without it every
# service-chart PV would diff as "nodeAffinity removed".
NODE_NAME="${NODE_NAME:-jterrazz-infrastructure}"

: "${KUBECONFIG:=$PROJECT_DIR/kubeconfig.yaml}"
export KUBECONFIG

# =============================================================================
# The release table — mirrors the `helm upgrade --install` invocations in
# ansible/roles/platform/tasks/*.yml. Ansible is the deployer; this is a
# read-only preview of the same set, so the two must describe the same
# releases. Adding a platform service means adding a line here.
#
# This table IS checked: scripts/assert-sync.py parses both arrays below and
# the Ansible tasks, and fails if a release, chart ref, namespace, version key
# or values path differs. A stale preview is worse than no preview — it diffs a
# chart the deploy will not use, and says "no changes" about the one it will.
#
# UPSTREAM_RELEASES: <release>|<namespace>|<chart ref>|<version key in
#                    group_vars platform_chart_versions>|<values file>
# =============================================================================
UPSTREAM_RELEASES=(
    "cert-manager|platform-networking|jetstack/cert-manager|cert_manager|kubernetes/services/cert-manager/helm.yaml"
    "infisical|platform-secrets|infisical/secrets-operator|infisical|kubernetes/services/infisical/helm.yaml"
    "victoria-metrics|platform-telemetry|vm/victoria-metrics-single|victoria_metrics|kubernetes/services/victoria-metrics/helm.yaml"
    "victoria-logs|platform-telemetry|vm/victoria-logs-single|victoria_logs|kubernetes/services/victoria-logs/helm.yaml"
    "victoria-traces|platform-telemetry|vm/victoria-traces-single|victoria_traces|kubernetes/services/victoria-traces/helm.yaml"
    "kube-state-metrics|platform-telemetry|prometheus-community/kube-state-metrics|kube_state_metrics|kubernetes/services/kube-state-metrics/helm.yaml"
    "node-exporter|platform-telemetry|prometheus-community/prometheus-node-exporter|node_exporter|kubernetes/services/node-exporter/helm.yaml"
    "otel-collector|platform-telemetry|open-telemetry/opentelemetry-collector|otel_collector|kubernetes/services/otel-collector/helm.yaml"
    "grafana|platform-telemetry|grafana-community/grafana|grafana|kubernetes/services/grafana/helm.yaml"
    # OCI, so no `helm repo add` is needed for this one.
    "librechat|platform-ai|oci://ghcr.io/danny-avila/librechat-chart/librechat|librechat|kubernetes/services/librechat/helm.yaml"
)

# SERVICE_RELEASES: <service name>|<namespace>
# All installed as `<name>-platform` from kubernetes/charts/service with
# kubernetes/services/<name>/platform.yaml, exactly as service-charts.yml does.
SERVICE_RELEASES=(
    "grafana|platform-telemetry"
    "victoria-metrics|platform-telemetry"
    "victoria-logs|platform-telemetry"
    "victoria-traces|platform-telemetry"
    "librechat|platform-ai"
    "openpanel|platform-analytics"
    "registry|platform-registry"
)

# =============================================================================

# Reads one key out of the flat `platform_chart_versions:` block. Deliberately
# not a YAML parser: the block is a flat map and anything else in it should be
# a loud failure here rather than a wrong --version on a live diff.
chart_version() {
    local key="$1" value
    value="$(awk -v key="$key" '
        /^platform_chart_versions:/ { in_block = 1; next }
        in_block && /^[^[:space:]]/ { in_block = 0 }
        in_block && $1 == key ":" { print $2 }
    ' "$GROUP_VARS" | tr -d '"' | head -1)"
    printf '%s' "$value"
}

require_kubeconfig() {
    if [ ! -f "$KUBECONFIG" ]; then
        error "No kubeconfig at $KUBECONFIG"
        error "This tool diffs against the LIVE cluster, so it needs one."
        error "Generate it with:  make kubeconfig"
        error "(or point KUBECONFIG at an existing one)."
        exit 1
    fi
    if ! kubectl version -o yaml >/dev/null 2>&1; then
        error "Cannot reach the cluster with KUBECONFIG=$KUBECONFIG"
        error "The VM may be down (orb list), or the kubeconfig may predate the last repave."
        exit 1
    fi
}

require_helm_diff() {
    if helm plugin list 2>/dev/null | awk '{print $1}' | grep -qx diff; then
        return
    fi
    info "helm-diff plugin missing — installing $HELM_DIFF_VERSION"
    helm_plugin_install https://github.com/databus23/helm-diff "$HELM_DIFF_VERSION"
}

# `<repo>/<chart>` needs `helm repo add <repo>`; an OCI ref or a local path
# does not. The repo URLs live in ansible/roles/platform/tasks/helm-cli.yml and
# are deliberately NOT copied here — one more copy is one more thing to drift.
repo_available() {
    local chart="$1" repo
    case "$chart" in
        oci://* | /* | ./*) return 0 ;;
    esac
    repo="${chart%%/*}"
    helm repo list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$repo"
}

wanted=("$@")
selected() {
    [ ${#wanted[@]} -eq 0 ] && return 0
    local name
    for name in "${wanted[@]}"; do
        [ "$name" = "$1" ] && return 0
    done
    return 1
}

require_kubeconfig
require_helm_diff

skipped=0
diffed=0
failed=0

# A release whose diff errored is REPORTED and the loop moves on, rather than
# swallowed with `|| true`. A pre-flight tool that hides a failure behind an
# empty diff says "nothing would change" about a release it never managed to
# render — which is the exact failure mode this script exists to prevent. The
# run still covers every other release; the non-zero exit at the end is what
# makes the gap impossible to miss.
diff_release() {
    local label="$1"
    shift
    if helm diff upgrade "$@"; then
        diffed=$((diffed + 1))
        return
    fi
    error "$label: helm diff FAILED (output above) — this preview does NOT cover it."
    failed=$((failed + 1))
}

section "Upstream charts"
for entry in "${UPSTREAM_RELEASES[@]}"; do
    IFS='|' read -r release namespace chart version_key values <<<"$entry"
    selected "$release" || continue

    version="$(chart_version "$version_key")"
    if [ -z "$version" ]; then
        error "$release: no '$version_key' under platform_chart_versions in $GROUP_VARS"
        skipped=$((skipped + 1))
        continue
    fi
    if ! repo_available "$chart"; then
        warn "$release: helm repo '${chart%%/*}' is not configured locally — skipping."
        warn "  Add the repositories listed in ansible/roles/platform/tasks/helm-cli.yml, then re-run."
        skipped=$((skipped + 1))
        continue
    fi

    info "$release ($chart $version) in $namespace"
    diff_release "$release" "$release" "$chart" \
        --namespace "$namespace" \
        --version "$version" \
        --values "$PROJECT_DIR/$values" \
        --suppress-secrets \
        --allow-unreleased
done

section "Service chart (ingress + certificate + storage)"
for entry in "${SERVICE_RELEASES[@]}"; do
    IFS='|' read -r name namespace <<<"$entry"
    selected "$name" || continue

    info "$name-platform in $namespace"
    diff_release "$name-platform" "$name-platform" "$SERVICE_CHART" \
        --namespace "$namespace" \
        --values "$PROJECT_DIR/kubernetes/services/$name/platform.yaml" \
        --set "infrastructure.nodeName=$NODE_NAME" \
        --suppress-secrets \
        --allow-unreleased
done

section "Summary"
echo "  releases diffed:  $diffed"
echo "  releases skipped: $skipped"
echo "  releases failed:  $failed"
echo ""
echo "  Empty output above a release means it is already in the desired state."
echo "  Apply with: make deploy-platform"

if [ "$failed" -gt 0 ]; then
    echo ""
    error "$failed release(s) could not be diffed — the preview above is INCOMPLETE."
    error "Fix those before running: make deploy-platform"
    exit 1
fi
