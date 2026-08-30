#!/bin/bash
# Trigger every app's CI to redeploy — run after a fresh cluster rebuild, when
# the registry is empty and no app workload exists yet.
#
# THE FLEET IS DISCOVERED, NOT LISTED. Every app Deployment carries
# `app.jterrazz.com/repository`, stamped by the app chart from the
# `--set meta.repository=${{ github.repository }}` that
# jterrazz-actions/actions/docker-deploy passes. This script reads that
# annotation off the live cluster.
#
# The list it replaced went stale exactly the way a list does: jterrazz-web was
# missing from it while smoke.sh probed three of its hostnames, so a repave
# would silently never have brought it back. A Deployment that carries the app
# chart's labels but NO repository annotation is reported and makes this script
# exit non-zero — an app that has not redeployed since the annotation landed is
# a gap, not an absence.
#
# THE REPAVE IS THE ONE CASE DISCOVERY CANNOT SERVE: a rebuilt cluster has no
# app Deployments to read, which is exactly when this script is needed most. So
# the fleet is written down BEFORE the cluster is destroyed and replayed after:
#
#   ./scripts/trigger-app-deploys.sh --dry-run > /tmp/fleet.txt   # before destroy
#   ./scripts/trigger-app-deploys.sh --from /tmp/fleet.txt        # after deploy
#
# That file is a snapshot of a live cluster, not a list somebody maintains — it
# cannot be stale, because it is written minutes before it is used. The repave
# procedure in docs/RUNBOOK.md has both steps in order.
#
# Usage:
#   ./scripts/trigger-app-deploys.sh              # needs an authenticated `gh`
#   ./scripts/trigger-app-deploys.sh --dry-run    # one repo per line on stdout, dispatch nothing
#   ./scripts/trigger-app-deploys.sh --from FILE  # dispatch that list instead of discovering
#
# Cluster access is `cluster_kubectl` in scripts/lib/common.sh, shared with
# scripts/smoke.sh: CLUSTER_KUBECTL, CLUSTER_SSH_KEY, or a kubeconfig.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

# The workflow name every app repo exposes. It is the one string this script
# still has to know, because a workflow_dispatch is addressed by name.
WORKFLOW="Build and Deploy"

# Stagger: these are rolling deploys against ONE memory-constrained node, and
# without a gap every CI run lands at once and competes for RAM.
STAGGER_SECONDS=20

dry_run=false
from_file=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) dry_run=true ;;
        --from)
            shift
            from_file="${1:-}"
            [ -n "$from_file" ] || {
                error "--from needs a file"
                exit 2
            }
            ;;
        -h | --help)
            sed -n '2,36p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            error "Unknown flag: $1"
            exit 2
            ;;
    esac
    shift
done

# Every app-chart Deployment in the cluster. `managed-by=Helm` plus the
# existence of an `environment` label is what distinguishes them from the
# upstream charts' workloads (grafana, cert-manager, librechat...), which carry
# no environment.
app_deployments_json() {
    cluster_kubectl get deployment --all-namespaces \
        -l "app.kubernetes.io/managed-by=Helm,environment" -o json
}

# One repo per line, deduplicated (an app with prod/next/staging is three
# Deployments and one repo). `!<ns>/<name>` for a Deployment with no annotation.
# shellcheck disable=SC2016  # this is a Python program, not a shell string
DISCOVER_PY='
import json, sys

doc = json.load(sys.stdin)
if not doc.get("items"):
    sys.exit("no app-chart Deployments in the cluster — is this the right cluster?")

repos, missing = {}, []
for item in doc["items"]:
    meta = item["metadata"]
    where = "%s/%s" % (meta.get("namespace", "?"), meta.get("name", "?"))
    repo = (meta.get("annotations") or {}).get("app.jterrazz.com/repository", "").strip()
    if not repo:
        missing.append(where)
    else:
        repos.setdefault(repo, []).append(where)

for repo in sorted(repos):
    print(repo)
for where in sorted(missing):
    print("!" + where)
'

declare -a repos=() unannotated=()

# Everything diagnostic goes to stderr, so `--dry-run > fleet.txt` is a clean
# list of repos and nothing else.
if [ -n "$from_file" ]; then
    section "Replaying $from_file" >&2
    while IFS= read -r line; do
        line="${line%%#*}"
        line="$(printf '%s' "$line" | tr -d '[:space:]')"
        [ -n "$line" ] || continue
        repos+=("$line")
    done <"$from_file"
else
    section "Discovering the fleet" >&2

    deployments=""
    if ! deployments="$(app_deployments_json 2>&1)"; then
        error "could not read Deployments from the cluster:"
        printf '%s\n' "$deployments" >&2
        cluster_access_hint
        error "On a freshly repaved cluster there are no app Deployments at all — replay the pre-repave snapshot with --from instead."
        exit 1
    fi

    discovered=""
    if ! discovered="$(printf '%s' "$deployments" | python3 -c "$DISCOVER_PY")"; then
        error "could not parse the Deployment list"
        exit 1
    fi

    while IFS= read -r line; do
        [ -n "$line" ] || continue
        case "$line" in
            '!'*) unannotated+=("${line#!}") ;;
            *) repos+=("$line") ;;
        esac
    done <<<"$discovered"
fi

if [ ${#unannotated[@]} -gt 0 ]; then
    error "${#unannotated[@]} app Deployment(s) carry no app.jterrazz.com/repository annotation:"
    for where in "${unannotated[@]}"; do
        error "  - $where"
    done
    error "Their repos cannot be discovered, so this run would leave them behind."
    error "FIX: redeploy each once from its own CI (its next push, or \`gh workflow run '$WORKFLOW' --repo <owner>/<repo>\`)."
    error "The annotation comes from jterrazz-actions/actions/docker-deploy passing --set meta.repository."
    exit 1
fi

if [ ${#repos[@]} -eq 0 ]; then
    error "found no repos. That is a broken query or an empty file, never 'no apps'."
    exit 1
fi

if $dry_run; then
    printf '%s\n' "${repos[@]}"
    success "${#repos[@]} repo(s) would be dispatched (--dry-run: nothing sent)." >&2
    exit 0
fi

for repo in "${repos[@]}"; do
    info "$repo"
done

section "Triggering App Deployments"

for i in "${!repos[@]}"; do
    repo="${repos[$i]}"
    info "Triggering deploy for $repo..."
    if gh workflow run "$WORKFLOW" --repo "$repo"; then
        success "Triggered $repo"
    else
        warn "Failed to trigger $repo (workflow may not exist yet)"
    fi

    if [ "$i" -lt $((${#repos[@]} - 1)) ]; then
        sleep "$STAGGER_SECONDS"
    fi
done

success "All app deployments triggered!"
echo
echo "Monitor progress at:"
for repo in "${repos[@]}"; do
    echo "  https://github.com/${repo}/actions"
done
