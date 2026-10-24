# ADR-019: OpenPanel's datastores run supported versions above upstream's pins

**Status:** Proposed
**Date:** 2026-10-24

Written 2026-10-24 from the comments in `kubernetes/services/openpanel/`
(commit 9f49d38 for ClickHouse; the PostgreSQL move of 2026-09-19) that this
record replaces.

## Context

OpenPanel's self-hosting compose pins its datastores and documents no other
version: `postgres:14-alpine`, `redis:7.2.5-alpine`, and ClickHouse
26.1.3.52 at the 2.3.0 images. Those pins age: 14 reaches EOL on 2026-11-12;
ClickHouse 26.1 is not an LTS, left support in 2026-05 and carries
CVE-2026-51992 (SQL injection via `CREATE DICTIONARY`, fixed after 26.3.9.8).
Running upstream's exact pins means running unsupported software; running the
newest release means trusting compatibility nobody states.

## Decision

Each store runs the newest line that a support statement or a test on the
live data covers, and no further.

- **ClickHouse: the 26.3 LTS line, never past 26.4.** 26.5 flips
  `date_time_input_format` to `best_effort`, which changes event-ingest
  parsing, and 26.7 rejects the AggregatingMergeTree shape OpenPanel's
  materialized views use. Moved on 2026-10-24 after booting 26.3.60.2 on a
  copy of the live data directory: all 29 tables and 6 materialized views
  loaded, row counts matched, no server error. Patch bumps within 26.3 are
  free; a minor bump re-runs that test. `clickhouse-26.1-2026-10-24` beside
  the live directory is the rollback.
- **PostgreSQL: `17-alpine`.** The only statement reaching above 14 is
  Prisma 6's supported-databases list (9.6 to 18), the ORM rather than the
  application. Moved from 14 on 2026-09-19 by dump and restore
  ([Operate](../guides/operate.md#the-postgresql-major-migration-14-to-17-was-run-this-way-on-2026-09-19));
  `pgdata-pg14-2026-09-19` is the rollback. Not 18: its image moved the
  default data layout; 17 is supported until 2029. The tag floats to the
  latest 17 patch.
- **Redis: latest 7.x, not 8.** Neither OpenPanel nor BullMQ publishes a
  statement supporting Redis 8, which would be two uncited assumptions under
  the job queue. 7.4 is a minor inside the line upstream pins, verified to
  start under this uid (999:1000) and these args. Its RDB/AOF are unreadable
  by 7.2, so it is forward-only, acceptable for a rebuildable queue.

The rest of the stores' shape comes with the same upstream parity: ClickHouse
runs upstream's self-hosting config verbatim (console logging and no heavy
system log tables, which is also the fix for upstream issue #324, ClickHouse
pegged at ~140% CPU once logrotate broke its file handle) and its default
no-auth user; Redis and ClickHouse hold no credential. Each store is
reachable only from its namespace and dials nothing but DNS: its `network:`
block is the only thing in front of an unauthenticated database.

## Consequences

- Every store is inside its upstream support window, at the cost of running
  versions OpenPanel itself never tested; the boot test on live data and the
  kept rollback directory are what stand in for that.
- A ClickHouse minor bump, or any move past 26.4, needs a fresh test on a copy
  of the data, and is a decision rather than a Renovate merge.
- The table of held pins lives in
  [Operate](../guides/operate.md#version-decisions).
