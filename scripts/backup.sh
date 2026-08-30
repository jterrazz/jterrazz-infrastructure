#!/bin/bash
# Encrypted snapshot of every persistent volume, restorable on any future
# machine with nothing but the passphrase.
#
# WHY ENCRYPTED AT ALL: the volumes live on the Mac at
# ~/.jterrazz-infrastructure/data, world-readable, and a `chmod 750` on that
# tree is NOT the fix — the pods write as uids 70/101/472/999/1000 through
# virtiofs and lose traversal the moment "other" is dropped. Encryption moves
# the control to where copies of this data actually travel: Time Machine, an
# external disk, another machine.
#
# THE PASSPHRASE IS PERMANENT. Rotating it does not re-encrypt old archives, it
# only orphans them. It lives in Infisical as BACKUP_ENCRYPTION_KEY under
# /jterrazz-infrastructure; losing it loses every archive it ever made, and
# there is no recovery path by design.
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
# 600k iterations: openssl's own default is 10k, which is a decade out of date
# for a key this long-lived.
ITER=600000
# Where the passphrase lives. Same folder as the rest of this repo's secrets.
KEY_PATH=/jterrazz-infrastructure

usage() { echo "usage: $0 [--consistent] [--verify-only <archive>]"; exit 2; }

require_key() {
    if [ -z "${BACKUP_ENCRYPTION_KEY:-}" ]; then
        # Same source of truth as every other credential here.
        if [ -f "$SCRIPT_DIR/../.env" ]; then
            set -a
            # shellcheck disable=SC1091
            . "$SCRIPT_DIR/../.env"
            set +a
        fi
    fi
    # Still nothing: pull it from Infisical directly. Deliberately NOT routed
    # through infisical-vars.py — that writes the deploy extra-vars file onto
    # the node, and this key has no business there.
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

# Decrypt and list. An archive nobody has ever opened is a guess, not a backup,
# so this runs on every snapshot and not only on demand.
verify() {
    local archive="$1"
    info "Verifying $archive"
    local count
    # `if ! count=$(...)`, not a bare assignment: under `set -e` a failed
    # decrypt aborts the script outright and the branches below never run, so
    # the one failure this function exists to report is the one it misses.
    if ! count=$(openssl enc -d -aes-256-cbc -pbkdf2 -iter "$ITER" \
                     -pass env:BACKUP_ENCRYPTION_KEY -in "$archive" \
                 | tar -tzf - | wc -l | tr -d ' '); then
        error "Archive did not decrypt — wrong BACKUP_ENCRYPTION_KEY or corrupt file"
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
        # `systemctl stop k3s` does NOT stop the containers — they keep writing
        # through the whole tar and the databases land torn. killall is the
        # only thing that actually stops them.
        section "Stopping workloads"
        orb -m "$MACHINE" -u root /usr/local/bin/k3s-killall.sh >/dev/null 2>&1 || true
        success "Workloads stopped"
    else
        warn "Live snapshot: databases may be captured mid-write."
        warn "Use --consistent for a restorable copy of Postgres/Mongo/ClickHouse."
    fi

    section "Archiving $DATA_DIR"
    # --exclude .DS_Store: Finder writes it into every directory it displays and
    # tar aborts on the permission error mid-archive.
    tar -czf - --exclude '.DS_Store' -C "$(dirname "$DATA_DIR")" "$(basename "$DATA_DIR")" \
        | openssl enc -aes-256-cbc -pbkdf2 -iter "$ITER" \
              -pass env:BACKUP_ENCRYPTION_KEY -out "$archive"
    chmod 600 "$archive"
    success "Wrote $archive ($(du -h "$archive" | cut -f1))"

    verify "$archive"

    if [ "$consistent" -eq 1 ]; then
        section "Restarting the cluster"
        orb -m "$MACHINE" -u root systemctl start k3s
        success "k3s restarted — cert-manager may need the restart from docs/RUNBOOK.md"
    fi

    section "Restore"
    cat <<EOF
  openssl enc -d -aes-256-cbc -pbkdf2 -iter $ITER \\
      -pass env:BACKUP_ENCRYPTION_KEY -in <archive> | tar -xzf - -C <target>

  The passphrase is the only thing needed — on this Mac or any future one.
EOF
}

main "$@"
