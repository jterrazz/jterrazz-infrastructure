# ADR-013: Grafana gets 768Mi, sized sidecars, and ConfigMap-only reach

**Status:** Proposed
**Date:** 2026-09-19

Written 2026-10-24 from the comments in `kubernetes/services/grafana/`
(commit d91f722 for the memory limit, a43327c for the RBAC) that this record
replaces.

## Context

Grafana kept falling into a recurring "spiral": pegged at its CPU cap,
`/api/health` answering 503, SQLite logging `context deadline exceeded`. It
was diagnosed in 2026-07 as a SQLite lock bug, which it never was. Measured
inside a spiral: 98% of `usage_usec` was system time, 549M file refaults,
12.8M `memory.max` hits, while the Go process itself used 5% of one core per
pprof. Grafana 13's unified storage holds about 320Mi of anonymous memory,
which at a 384Mi limit left the `grafana.db` and bleve-index file pages about
60Mi of the same cgroup budget; every periodic index rebuild pinned
`memory.max` and the kernel's direct reclaim burned the whole CPU quota.

Two neighbouring facts were found the same way:

- **The SQLite `wal` knob is inert on this image.** Grafana's default is
  `wal = false`, and the CGO-free modernc.org/sqlite driver ignores the
  setting anyway (grafana/grafana#127893). WAL is a property of the database
  FILE, flipped offline, which the driver then honours.
- **The chart's own ClusterRole** granted get/list/watch on ConfigMaps AND
  Secrets in every namespace, with the service-account token mounted in the
  Grafana container too: a Grafana RCE read every Secret in the cluster
  (audit 2026-10-24, `can-i list secrets -A` answered yes).

## Decision

- **Memory limit 768Mi.** Below about 512Mi the reclaim thrash returns. The
  CPU cap stays, as spin containment: a repeat degrades Grafana, not the node.
- **WAL is hygiene, applied by hand** (fewer fsyncs, readers do not block the
  writer), never the fix for the spiral. A fresh `grafana.db` (a repave)
  starts in rollback mode and needs the pragma again:

  ```bash
  kubectl scale deploy grafana -n platform-telemetry --replicas=0
  sqlite3 /var/lib/grafana-node-local/grafana.db "PRAGMA journal_mode=WAL;"
  kubectl scale deploy grafana -n platform-telemetry --replicas=1
  ```

- **One sized `resources` block for every sidecar.** All five sidecar
  containers interpolate `.Values.sidecar.resources`, with no per-sidecar
  override. They are sized rather than BestEffort because an evicted sidecar
  is not a visible outage: dashboards and alert rules silently stop updating
  while Grafana stays green.
- **The sidecars read ConfigMaps only**, bound to a narrower ClusterRole of
  this repo's; the chart renders none. A sidecar left on the default `both`
  lists Secrets cluster-wide and gets a 403 on every loop. Alert delivery,
  the one Secret Grafana needs (`grafana-alerting`, the Slack contact point),
  is mounted by the kubelet instead, so Grafana holds no Secret RBAC at all; a
  subPath mount does not follow updates, so a new `SLACK_WEBHOOK_URL` lands at
  the next pod restart.
- **revisionHistoryLimit 3**, not the chart's 10: ten ReplicaSets per
  Deployment is ten objects in a SQLite-backed apiserver for a rollback nobody
  performs. The collector carries the same value for the same reason.

## Consequences

- Grafana costs twice the memory it did; shrinking it is re-opening the
  spiral, not a right-sizing.
- A binding's `roleRef` is immutable: renaming the ClusterRole means deleting
  `grafana-clusterrolebinding` first, or the upgrade fails, as it did on
  2026-10-24. The upgrade test now catches that class before the real cluster.
- Grafana installs the VictoriaLogs plugin at every pod start, so it keeps
  egress to grafana.com.
