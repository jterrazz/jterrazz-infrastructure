#!/bin/bash
# Installing a Helm plugin at a pinned version, across Helm majors. Source it:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/helm-plugin.sh"
#   helm_plugin_install https://github.com/databus23/helm-diff v3.15.10
#
# Sourced by scripts/platform-diff.sh and by the `kubernetes` job of
# .github/workflows/validate.yaml — the two places that install a plugin.

# Helm 4 verifies plugin signatures by default and neither plugin this repo
# uses publishes one; Helm 3 has no --verify flag at all. Pass it only where it
# exists, so this survives the next helm bump in either direction.
helm_plugin_install() {
    local url="$1" version="$2"
    if helm plugin install --help 2>&1 | grep -q -- '--verify'; then
        helm plugin install "$url" --version "$version" --verify=false
    else
        helm plugin install "$url" --version "$version"
    fi
}
