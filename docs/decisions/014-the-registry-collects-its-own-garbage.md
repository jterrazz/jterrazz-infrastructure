# ADR-014: The registry collects its own garbage, with the blob cache off

**Status:** Proposed
**Date:** 2026-09-23

Written 2026-10-24 from the comments in `kubernetes/services/registry/`
(commits 7311a2e and cefa7f2) that this record replaces.

## Context

The private registry (`registry.internal.jterrazz.com`, distribution 3.x,
filesystem storage on a hostPath PV) is the one every app deploy logs into.
Every CI push moves `:latest` to a new manifest and leaves the old one behind,
untagged but still holding its layers. A registry never deletes on its own, by
design, so a digest stays pullable for a rollback; nothing here pulls by
digest (every workload references a tag), so the history is pure weight. On
2026-09-23 it was 796 manifests for 10 tags and 14G of blobs; a one-off
collection took it to 1.0G.

Several properties of the workload constrain any answer:

- **Auth is htpasswd**, because the image offers only that or `token`, and
  `token` needs a separate JWT-issuing server for a single-user registry. One
  bcrypt-hashed account in Secret `registry-auth` (key `htpasswd`),
  bootstrapped by `roles/platform/tasks/bootstrap.yml` because a hash is never
  committed. CI pushes and every namespace's synced pull secret share it,
  which is why a rotation overlaps two accounts (`deploy` / `deploy-next`)
  instead of swapping one ([Operate](../guides/operate.md#rotating-the-registry-password)).
- **The image bakes in distribution's `config-dev.yml`**: `log.level: debug`
  (at debug, `tracing/loggerwriter.go` dumps every request's spans as JSON;
  `OTEL_TRACES_EXPORTER` does not stop it, the level is the switch), an
  in-memory blob-descriptor cache, and a debug listener on 5001 serving
  `/debug/health` and `/metrics` unauthenticated. Everything is configured by
  `REGISTRY_*` env vars; no config file is mounted. That is also what made the
  2.8 to 3.x jump safe: 3.0 moved the default config path from
  `/etc/docker/registry/config.yml` to `/etc/distribution/config.yml`, so a
  file mounted at the old path would be silently ignored. The on-disk layout
  is unchanged (`storagePathVersion` still `v2`); 3.x drops schema1, the
  oss/swift drivers, `reporting:` and TLS 1.0/1.1 minimums, none used here.
- **The Deployment is `Recreate`** (one writer on one volume), so any restart
  is a full outage of the registry every deploy depends on.

## Decision

A weekly `registry-gc` CronJob (app chart 2.13 `cronJobs`) runs
`registry garbage-collect --delete-untagged` at 03:30 UTC on Sunday, and the
running registry has its blob-descriptor cache turned off.

- **The cache is off** (`REGISTRY_STORAGE_CACHE_BLOBDESCRIPTOR` empty).
  garbage-collect never tells the cache what it swept (it runs in its own pod
  anyway). With the cache on, a push that re-uses a swept layer is told "Layer
  already exists", skips the upload, and writes a tag that cannot be pulled
  until the registry restarts. Reproduced on 2026-09-23 against
  registry:3.1.1 in a throwaway container: cache on, the re-pushed image was
  broken; cache off, it pushed and pulled. Upstream: distribution#1803, #3802,
  #4269, all open. The boot log line `unknown cache type ... caching disabled`
  is the confirmation, not a fault. Every blob lookup reads the filesystem,
  which for one user's registry costs nothing. The only other safe
  arrangement, restarting after every collection, is a weekly outage under
  `Recreate`.
- **`--delete-untagged` is safe on what buildkit pushes**: each tag points at
  an OCI index whose image and attestation manifests carry no tag of their
  own, and 3.1.x marks an index's children before it sweeps (verified with
  `--dry-run` on every live tag; 3.1.2's dry run on 2026-10-24 decided exactly
  what 3.1.1's did, line for line). An older distribution swept those children
  and broke the tag, so every `image:` bump re-runs the dry run: each index and
  both children must read `marking`, never `eligible for deletion`.
- **The race is guarded, not locked.** A collection marks then sweeps; a push
  that uploads during the mark and writes its manifest before the sweep leaves
  a tag pointing at deleted blobs. Distribution's answer is read-only mode,
  but it is a config block that cannot be toggled on a running registry, and
  the `REGISTRY_STORAGE_MAINTENANCE_READONLY_ENABLED` env var panics 3.1.1 at
  boot (`readonly config key must contain additional keys`; it took the
  registry down for about five minutes on 2026-09-23). Two restarts a week
  under `Recreate` was refused. Instead: the only pushers are app CI on merge
  (no repo builds on a schedule), so the run sits at a quiet hour and skips
  itself, exit 0, when any upload was touched in the last 30 minutes.
- **The alert is on the last success**, so a registry that skips every week
  still surfaces after eight days. The age runs from the last success or the
  CronJob's creation, whichever is later; NoData means the CronJob is gone,
  which is the same fact, so it alerts too, after `for: 1h`: with `for: 0s` a
  freshly created CronJob, which has no series until kube-state-metrics'
  next scrape, fired a NoData alert on its first evaluation (2026-09-23).

Around it, the workload is shaped by the same facts: `REGISTRY_LOG_LEVEL`
overrides the baked-in debug level (the log-volume fix); the probe hits `/`
on 5000, never `/v2/` (401 without credentials, which kubelet reads as a
failure and would CrashLoop a healthy registry) and never the debug port (a
probe belongs on the port the Service targets); the memory limit stays at
512Mi, because a tight one makes Go's GC thrash while streaming a large blob,
throughput falls to about 0.6MB/s and buildkit's ~60s upload timeout surfaces
as "blob upload invalid" rather than an OOM; it runs as root over a
root-owned blob store (`storage.owner: ""`, no chown of 10Gi on every start);
its network is `isolated`, Traefik in and DNS out; and its PV is an explicit
`manual` hostPath, since a PVC left to local-path would land under
`/var/lib/rancher/k3s/storage/`, which a repave wipes.

## Consequences

- The blob store stays near its live size (1.0G after the first run, from 14G).
- Re-enabling the blob-descriptor cache, or setting the read-only env var on
  the Deployment, breaks the registry; both are refused in the code comments.
- Every distribution bump owes a `--dry-run` before it merges.
- A rollback by old digest is no longer possible after a collection; nothing
  here uses one.
- Day-to-day commands (run it now, dry run, alert) are
  [Operate](../guides/operate.md#registry-garbage-collection).
