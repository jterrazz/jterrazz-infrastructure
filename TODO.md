# TODO

Work deliberately left for later. Each line says what unblocks it.

- **Offsite backup.** The weekly snapshots (ADR-024) sit on the Mac, beside
  the data: a lost disk loses both. Needs a destination (R2, B2 or an external
  disk); the archives are already age-encrypted, so any dumb store will do.
- **Renovate never ran.** The app is said to be installed, yet no repository
  has a PR or a dependency dashboard (checked 2026-10-25, six repositories).
  Check the activation on the Mend side; `renovate.json` validates.
