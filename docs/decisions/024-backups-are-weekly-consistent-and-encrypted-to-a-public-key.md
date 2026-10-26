# ADR-024: Backups are weekly, consistent, and encrypted to a public key

**Status:** Accepted
**Date:** 2026-10-25

## Context

The one backup was a manual `make backup` run 36 days earlier: 14.7 GB of
AES-256-CBC with no MAC, keyed by a passphrase the script fetched by putting
the Infisical client secret on curl's command line. Nothing scheduled it, and
most of its bytes were the registry, which git can rebuild.

## Decision

- **The node takes the snapshot**, `roles/backup`: a systemd timer every Sunday
  at 03:30 (`Persistent=true`, so a run the Mac slept through happens on wake)
  stops the workloads with `k3s-killall.sh`, tars `/var/lib/k8s-data`, starts k3s
  again, and keeps the four newest. Consistent beats live: a minute of
  downtime a week against databases captured mid-write.
- **Encrypted with age to a public key** committed in
  `group_vars/all/backup.yml`; the private half is `BACKUP_AGE_IDENTITY` in
  Infisical `/studio-infrastructure`, and nothing on the node or in the
  deploy needs it. age authenticates what it decrypts, which CBC did not.
- **The registry is left out**: `make redeploy-apps` rebuilds every image from
  its repository, and it was 4.2 of the 7.2 GB. The first snapshot was 1.9 GB.
- **`make backup`** runs a snapshot now; `make backup ARGS=--verify` decrypts the
  newest and lists what it holds, the key carried on stdin end to end.

## Consequences

- A month of history sits on the Mac's disk, beside the data: a lost disk
  loses both. An offsite copy is the open half of this record.
- Restoring needs the private key, so losing `BACKUP_AGE_IDENTITY` loses every
  snapshot; it is a key to keep, not to rotate.
- The last archive the openssl script made was deleted on 2026-10-25, so
  `BACKUP_ENCRYPTION_KEY` decrypts nothing any more.
