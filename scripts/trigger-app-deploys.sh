#!/bin/bash
# Trigger every app's CI to redeploy — run after a fresh cluster rebuild, when
# the registry is empty and no app workload exists yet.
#
# Usage:
#   ./scripts/trigger-app-deploys.sh     # needs an authenticated `gh`

set -euo pipefail

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

# <owner/repo>|<public hostnames scripts/smoke.sh probes for it>
#
# The hostname column is what makes this list checkable rather than a thing
# somebody remembers to update: scripts/assert-sync.py fails when a surface in
# smoke.sh's PUBLIC_CHECKS names no repo here (jterrazz-web went missing that
# way), and when a hostname here is probed by nothing. Only the repo column is
# used at runtime; a repo with no public surface carries an empty list.
REPOS=(
    "jterrazz/signews-api|signews.jterrazz.com signews-next.jterrazz.com signews-staging.jterrazz.com"
    "jterrazz/signews-web|sig.news"
    "jterrazz/jterrazz-web|www.jterrazz.com jterrazz.com blog.jterrazz.com"
    "jterrazz/gateway-intelligence|"
    "jterrazz/clawssify-web|clawssify.com"
    "jterrazz/spwn-web|spwn.sh"
    "clawrr/web-landing|clawrr.com"
)

# Public surfaces this repo deploys itself (ansible/roles/platform), so there
# is no app CI to trigger. Listed only so the check above covers the whole
# smoke table instead of a convenient subset of it.
# shellcheck disable=SC2034  # read by scripts/assert-sync.py, not by this script
PLATFORM_PUBLIC_HOSTS=(
    "analytics.jterrazz.com"
)

section "Triggering App Deployments"

for i in "${!REPOS[@]}"; do
    repo="${REPOS[$i]%%|*}"
    info "Triggering deploy for $repo..."
    if gh workflow run "Build and Deploy" --repo "$repo"; then
        success "Triggered $repo"
    else
        warn "Failed to trigger $repo (workflow may not exist yet)"
    fi

    # Stagger: these are rolling deploys against ONE memory-constrained node,
    # and without a gap every CI run lands at once and competes for RAM.
    if [ "$i" -lt $((${#REPOS[@]} - 1)) ]; then
        sleep 20
    fi
done

success "All app deployments triggered!"
echo
echo "Monitor progress at:"
for entry in "${REPOS[@]}"; do
    echo "  https://github.com/${entry%%|*}/actions"
done
