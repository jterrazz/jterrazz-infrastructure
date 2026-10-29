#!/bin/bash
# outside: dispatches every app repository's Deploy workflow (deploy.yaml), so a rebuilt cluster
# gets its apps back. The fleet is discovered: each Deployment in a namespace an app owns (label
# studio.jterrazz.com/repository) names its repository in the annotation of the same key.
#
#   ./src/scripts/redeploy-apps.sh               # discover, then dispatch
#   ./src/scripts/redeploy-apps.sh --dry-run     # print one repository per line, dispatch nothing
#   ./src/scripts/redeploy-apps.sh --from FILE   # dispatch what FILE lists (a repave's snapshot)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

WORKFLOW="deploy.yaml"
# value: builds land on one memory-bound node; without a gap they all start at once.
STAGGER_SECONDS=20
read -r -a KUBECTL <<< "${CLUSTER_KUBECTL:-kubectl}"

discover() {
    local namespaces lines
    namespaces=$("${KUBECTL[@]}" get namespaces -l studio.jterrazz.com/repository -o jsonpath='{.items[*].metadata.name}')
    lines=$(for namespace in $namespaces; do
        "${KUBECTL[@]}" get deployments -n "$namespace" \
            -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} {.metadata.annotations.studio\.jterrazz\.com/repository}{"\n"}{end}'
    done)
    if awk 'NF == 1 { print "  - " $1; missing = 1 } END { exit !missing }' <<< "$lines" >&2; then
        error "These app Deployments name no repository: redeploy each once from its own CI."
        exit 1
    fi
    awk 'NF == 2 { print $2 }' <<< "$lines" | sort -u
}

case "${1:-}" in
    "" | --dry-run) repositories=$(discover) ;;
    --from) repositories=$(sed -e 's/#.*//' -e 's/[[:space:]]//g' "${2:?--from needs a file}" | grep -v '^$' || true) ;;
    *) error "Usage: $0 [--dry-run | --from FILE]"; exit 1 ;;
esac

if [ -z "$repositories" ]; then
    error "No repositories found: a broken query or an empty file, never 'no apps'."
    exit 1
fi

if [ "${1:-}" = "--dry-run" ]; then
    echo "$repositories"
    exit 0
fi

first=1
for repository in $repositories; do
    [ "$first" = 1 ] || sleep "$STAGGER_SECONDS"
    first=0
    if gh workflow run "$WORKFLOW" --repo "$repository"; then
        success "dispatched $repository: https://github.com/$repository/actions"
    else
        warn "could not dispatch $repository (no \"$WORKFLOW\" workflow?)"
    fi
done
