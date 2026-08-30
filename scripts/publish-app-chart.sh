#!/bin/bash
# Package kubernetes/charts/app and push it to the OCI registry, unless that
# version is already published.
#
# The chart is pulled UNVERSIONED by every app's deploy (`oci://…/charts/app`,
# no version pin — see CLAUDE.md), so overwriting a published version would
# mean two different template sets answering to one tag depending on when an
# app last pulled. The guard below therefore refuses to overwrite — and SKIPS
# rather than fails, because roles/platform/tasks/publish-app-chart.yml
# publishes the same chart during a full deploy and a push landing just after
# `make deploy` would otherwise go red on an already-current registry. The
# consequence is that forgetting to bump `version:` in Chart.yaml publishes
# nothing, silently.
#
# KEEP IN SYNC with ansible/roles/platform/tasks/publish-app-chart.yml, which
# is the same guard for the fresh-cluster case (the node has no checkout of
# this repo, so it cannot call this script). scripts/assert-sync.py checks that
# the two agree on the registry refs and that the workflow calls this script.
#
# Usage:
#   REGISTRY_USERNAME=… REGISTRY_PASSWORD=… ./scripts/publish-app-chart.sh
#
# Needs the tailnet (the registry is private) and a Helm at the pinned
# `helm_version` from ansible/inventories/group_vars/all.yml.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

REGISTRY=registry.internal.jterrazz.com
CHART_DIR="$PROJECT_DIR/kubernetes/charts/app"
STAGING_DIR="${TMPDIR:-/tmp}/app-chart-publish"

: "${REGISTRY_USERNAME:?REGISTRY_USERNAME is required}"
: "${REGISTRY_PASSWORD:?REGISTRY_PASSWORD is required}"

# --password-stdin, and the value only ever in the environment: a password on a
# command line is visible in `ps` and in the CI log of the expanded command.
printf '%s' "$REGISTRY_PASSWORD" \
    | helm registry login "$REGISTRY" --username "$REGISTRY_USERNAME" --password-stdin

version="$(awk -F': *' '/^version:/ {print $2; exit}' "$CHART_DIR/Chart.yaml")"
if [ -z "$version" ]; then
    error "Could not read version: from kubernetes/charts/app/Chart.yaml"
    exit 1
fi
info "Chart.yaml version: $version"

rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR/check"

if helm pull "oci://$REGISTRY/charts/app" --version "$version" \
        --destination "$STAGING_DIR/check" >/dev/null 2>&1; then
    success "app chart $version is already published — nothing to do."
    warn "If you CHANGED templates, bump version: in kubernetes/charts/app/Chart.yaml,"
    warn "or this run publishes nothing."
    rm -rf "$STAGING_DIR"
    exit 0
fi

# The .tgz filename is not knowable here (helm derives it from Chart.yaml) and
# parsing it out of `helm package` stdout breaks on any warning line. An empty
# directory means the one file in it IS the chart.
mkdir -p "$STAGING_DIR/pkg"
helm package "$CHART_DIR" --destination "$STAGING_DIR/pkg"

# A glob, not `mapfile`: this has to run on the Mac's bash 3.2 as well as on
# a runner.
shopt -s nullglob
packages=("$STAGING_DIR"/pkg/*.tgz)
shopt -u nullglob
if [ "${#packages[@]}" -ne 1 ]; then
    error "Expected exactly one .tgz after \`helm package\`, found ${#packages[@]}."
    error "Refusing to guess which one to push."
    rm -rf "$STAGING_DIR"
    exit 1
fi

helm push "${packages[0]}" "oci://$REGISTRY/charts"
success "Published $(basename "${packages[0]}")"
rm -rf "$STAGING_DIR"
