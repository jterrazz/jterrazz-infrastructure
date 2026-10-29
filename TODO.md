# TODO

Work deliberately left for later. Each line says what unblocks it.

- **Backups stop the whole cluster.** The weekly snapshot (ADR-024, Sunday
  03:30 UTC) runs `k3s-killall` so nothing writes during the tar: every app
  and public site is down for 2 to 4 minutes (74 s of k3s down on
  2026-10-25, then the pods' restart). The snapshot is crash-consistent, not a
  clean shutdown, and a week of data is the most a loss costs.
  - Candidate fix, open to other ideas: dump the databases hot, nightly,
    without stopping anything: `pg_dump` in op-postgres, SQLite's `.backup`
    in signews-api and studio-console, each through `kubectl exec`, then
    age-encrypted like today. About 700 MB of data, a few hundred MB
    compressed. A loss then costs a day, and a `pg_dump` restores into a
    newer PostgreSQL major, which a file copy does not. The cold full copy
    stays for the telemetry stores (VictoriaMetrics is 1.7 GB of the ~2.9 GB)
    and drops to monthly.
  - Ruled out for now: an APFS snapshot of the Mac's disk (zero downtime, but
    it runs on the Mac under launchd and sudo, outside the VM and Ansible).
- **Offsite backup.** The snapshots sit on the Mac, beside the data: a lost
  disk loses both. Backblaze B2 is the pick (10 GB free, then $6/TB/month,
  restores free up to 3x the stored volume; a provider other than Cloudflare,
  so losing that account loses no backup); R2 is the simpler fallback (10 GB
  free, same account as DNS and the tunnel). Needs the account and a
  bucket-scoped key in Infisical; the archives are already age-encrypted.
  Ships the nightly dumps above, not the telemetry.
