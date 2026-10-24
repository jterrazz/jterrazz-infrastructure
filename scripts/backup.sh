#!/bin/bash
# outside: an encrypted snapshot of every persistent volume, restorable anywhere with the
# passphrase alone; why encrypted, and why the passphrase is permanent: docs/guides/operate.md.
#
#   ./scripts/backup.sh                 # snapshot, workloads left running
#   ./scripts/backup.sh --consistent    # stop workloads first (real downtime)
#   ./scripts/backup.sh --verify-only <file>
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

MACHINE="${ORB_MACHINE:-jterrazz-infrastructure}"
DATA_DIR="${BACKUP_DATA_DIR:-$HOME/.jterrazz-infrastructure/data}"
OUT_DIR="${BACKUP_OUT_DIR:-$HOME/.jterrazz-infrastructure/backups}"
# value: 600k PBKDF2 iterations, not openssl's 10k default, for a key this long-lived.
ITER=600000
KEY_PATH=/jterrazz-infrastructure

usage() { echo "usage: $0 [--consistent] [--verify-only <archive>]"; exit 2; }

require_key() {
    if [ -z "${BACKUP_ENCRYPTION_KEY:-}" ]; then
        if [ -f "$SCRIPT_DIR/../.env" ]; then
            set -a
            # shellcheck disable=SC1091
            . "$SCRIPT_DIR/../.env"
            set +a
        fi
    fi
    # invariant: fetched here, never through the deploy's infisical_secrets.
    if [ -z "${BACKUP_ENCRYPTION_KEY:-}" ] && [ -n "${INFISICAL_CLIENT_ID:-}" ] \
        && [ -n "${INFISICAL_CLIENT_SECRET:-}" ]; then
        info "Fetching BACKUP_ENCRYPTION_KEY from Infisical"
        local token
        token=$(curl -s -X POST https://eu.infisical.com/api/v1/auth/universal-auth/login \
                    -H 'Content-Type: application/json' \
                    -d "{\"clientId\":\"$INFISICAL_CLIENT_ID\",\"clientSecret\":\"$INFISICAL_CLIENT_SECRET\"}" \
                | python3 -c 'import sys,json; print(json.load(sys.stdin).get("accessToken",""))')
        if [ -n "$token" ]; then
            BACKUP_ENCRYPTION_KEY=$(curl -s -G "https://eu.infisical.com/api/v3/secrets/raw" \
                    -H "Authorization: Bearer $token" \
                    --data-urlencode "workspaceSlug=jterrazz" \
                    --data-urlencode "environment=prod" \
                    --data-urlencode "secretPath=$KEY_PATH" \
                | python3 -c 'import sys,json; s=json.load(sys.stdin).get("secrets") or []; print(next((x["secretValue"] for x in s if x["secretKey"]=="BACKUP_ENCRYPTION_KEY"), ""))')
            export BACKUP_ENCRYPTION_KEY
        fi
    fi

    if [ -z "${BACKUP_ENCRYPTION_KEY:-}" ]; then
        error "BACKUP_ENCRYPTION_KEY is not set."
        error "It lives in Infisical at $KEY_PATH (env prod). Export it, or put"
        error "INFISICAL_CLIENT_ID / INFISICAL_CLIENT_SECRET in .env and re-run."
        exit 1
    fi
}

# invariant: every snapshot is decrypted back: an archive nobody opened is a guess.
verify() {
    local archive="$1"
    info "Verifying $archive"
    local count
    # hazard: `if !`, not a bare assignment, which `set -e` would abort before reporting.
    if ! count=$(openssl enc -d -aes-256-cbc -pbkdf2 -iter "$ITER" \
                     -pass env:BACKUP_ENCRYPTION_KEY -in "$archive" \
                 | tar -tzf - | wc -l | tr -d ' '); then
        error "Archive did not decrypt: wrong BACKUP_ENCRYPTION_KEY or corrupt file"
        return 1
    fi
    if [ "$count" -lt 1 ]; then
        error "Archive decrypted to an empty listing."
        return 1
    fi
    success "Archive decrypts and holds $count entries"
}

main() {
    local consistent=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --consistent) consistent=1; shift ;;
            --verify-only) require_key; verify "${2:?archive path required}"; exit $? ;;
            -h|--help) usage ;;
            *) usage ;;
        esac
    done

    require_key
    [ -d "$DATA_DIR" ] || { error "No data directory at $DATA_DIR"; exit 1; }
    mkdir -p "$OUT_DIR"

    local stamp archive
    stamp=$(date +%Y%m%d-%H%M%S)
    archive="$OUT_DIR/k8s-data-$stamp.tar.gz.enc"

    if [ "$consistent" -eq 1 ]; then
        # hazard: `systemctl stop k3s` leaves the containers writing; only killall stops them.
        section "Stopping workloads"
        orb -m "$MACHINE" -u root /usr/local/bin/k3s-killall.sh >/dev/null 2>&1 || true
        success "Workloads stopped"
    else
        warn "Live snapshot: databases may be captured mid-write."
        warn "Use --consistent for a restorable copy of the databases."
    fi

    section "Archiving $DATA_DIR"
    # hazard: Finder's .DS_Store files abort tar on a permission error.
    tar -czf - --exclude '.DS_Store' -C "$(dirname "$DATA_DIR")" "$(basename "$DATA_DIR")" \
        | openssl enc -aes-256-cbc -pbkdf2 -iter "$ITER" \
              -pass env:BACKUP_ENCRYPTION_KEY -out "$archive"
    chmod 600 "$archive"
    success "Wrote $archive ($(du -h "$archive" | cut -f1))"

    verify "$archive"

    if [ "$consistent" -eq 1 ]; then
        section "Restarting the cluster"
        orb -m "$MACHINE" -u root systemctl start k3s
        success "k3s restarted; cert-manager may need the restart from docs/guides/operate.md"
    fi

    section "Restore"
    cat <<EOF
  openssl enc -d -aes-256-cbc -pbkdf2 -iter $ITER \\
      -pass env:BACKUP_ENCRYPTION_KEY -in <archive> | tar -xzf - -C <target>

  The passphrase is the only thing needed, on this Mac or any future one.
EOF
}

main "$@"
