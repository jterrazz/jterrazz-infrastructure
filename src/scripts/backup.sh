#!/bin/bash
# outside: drives the node's weekly backup (roles/backup) from the Mac: a snapshot now, or a proof
# that the newest one decrypts with the private key; why and how to restore: docs/guides/operate.md.
#
#   ./src/scripts/backup.sh            # snapshot now (stops the workloads for about a minute)
#   ./src/scripts/backup.sh --verify   # decrypt the newest snapshot and list what it holds
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

MACHINE="${ORB_MACHINE:-studio-infrastructure}"
OUT_DIR="$HOME/.studio-infrastructure/backups"

# invariant: the private key travels on stdin end to end, never in argv where `ps` reads it.
identity() {
    if [ -n "${BACKUP_AGE_IDENTITY:-}" ]; then
        printf '%s\n' "$BACKUP_AGE_IDENTITY"
        return
    fi
    # shellcheck disable=SC1091
    [ -f "$SCRIPT_DIR/../../.env" ] && { set -a; . "$SCRIPT_DIR/../../.env"; set +a; }
    local token
    token=$(jq -n --arg id "${INFISICAL_CLIENT_ID:?}" --arg secret "${INFISICAL_CLIENT_SECRET:?}" \
                '{clientId: $id, clientSecret: $secret}' \
            | curl -sf https://eu.infisical.com/api/v1/auth/universal-auth/login \
                -H 'Content-Type: application/json' -d @- | jq -r .accessToken)
    curl -sf -G https://eu.infisical.com/api/v3/secrets/raw/BACKUP_AGE_IDENTITY \
        -H @<(printf 'Authorization: Bearer %s\n' "$token") \
        --data-urlencode workspaceSlug=studio-infrastructure --data-urlencode environment=prod \
        --data-urlencode secretPath=/studio-infrastructure | jq -r .secret.secretValue
}

case "${1:-}" in
    "")
        section "Snapshot"
        orb -m "$MACHINE" -u root systemctl start studio-backup.service
        orb -m "$MACHINE" -u root journalctl -u studio-backup -n 1 -o cat
        ;;
    --verify)
        latest=$(find "$OUT_DIR" -name 'k8s-data-*.tar.gz.age' | sort | tail -1)
        [ -n "$latest" ] || { error "No snapshot in $OUT_DIR"; exit 1; }
        section "Verifying $(basename "$latest")"
        identity | orb -m "$MACHINE" -u root bash -c \
            "age -d -i <(cat) '/mnt/mac$latest' | tar -tzf - | awk -F/ 'NF>2 {print \$2}' | sort | uniq -c"
        success "The snapshot decrypts with BACKUP_AGE_IDENTITY"
        ;;
    *) echo "usage: $0 [--verify]"; exit 2 ;;
esac
