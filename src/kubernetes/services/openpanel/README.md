# OpenPanel

Self-hosted product analytics in `platform-analytics`: the dashboard is private at
`openpanel.internal.jterrazz.com`, the ingest is public at
`analytics.jterrazz.com/api/track`. Why it is six app-chart releases, and what
`API_URL_SSR` replaced, is
[ADR-010](../../../../docs/decisions/010-every-workload-renders-through-two-charts.md);
the datastore versions are
[ADR-019](../../../../docs/decisions/019-openpanel-datastores-run-supported-versions.md).

```text
browser ─► analytics.jterrazz.com/api/track ─► tunnel ─► Traefik ─► op-api (/track)
tailnet ─► openpanel.internal.jterrazz.com ──────────────► Traefik ─┬─ /api/* ─► op-api
                                                                    └─ /*     ─► op-dashboard
op-api, op-worker ─► op-postgres · op-clickhouse · op-redis
```

| Release                                    | Role                                                           |
| ------------------------------------------ | -------------------------------------------------------------- |
| `op-api`                                   | the API; runs the Prisma and ClickHouse migrations on boot     |
| `op-worker`                                | the BullMQ queues and crons                                    |
| `op-dashboard`                             | the Next.js UI, rendering server-side through op-api's Service |
| `op-postgres`, `op-clickhouse`, `op-redis` | the datastores, `isolated`: reachable from this namespace only |
| `openpanel-platform`                       | the three volumes and the two certificates (`service.yaml`)    |

The three applications load `_common.yaml` first. The public host serves
`/api/track` alone; the dashboard, `/api/export` and `/api/live` stay on the
tailnet.

## Data

| PVC                    | Size | Path under `/var/lib/k8s-data`             |
| ---------------------- | ---- | ------------------------------------------ |
| `openpanel-postgres`   | 3Gi  | `openpanel/postgres` (PGDATA in `pgdata/`) |
| `openpanel-clickhouse` | 10Gi | `openpanel/clickhouse`                     |
| `openpanel-redis`      | 1Gi  | `openpanel/redis`                          |

## Secrets and config

Infisical `/studio-infrastructure/openpanel` (env `prod`) holds
`POSTGRES_PASSWORD`, `COOKIE_SECRET`, `DATABASE_URL` and `DATABASE_URL_DIRECT`
(`postgresql://openpanel:<POSTGRES_PASSWORD>@op-postgres:5432/openpanel`). Each
release projects only the keys it names. ClickHouse and Redis hold no
credential.

A new sending site adds every origin a browser can be on (`https://x.com` and
`https://www.x.com`) to `API_CORS_ORIGINS` in `_common.yaml`; a missing one is
refused at the CORS preflight with nothing in op-api's logs.

## Operations

```bash
kubectl logs -n platform-analytics deploy/op-api --tail=50
kubectl exec -n platform-analytics deploy/op-clickhouse -- \
  clickhouse-client --query "SELECT count() FROM openpanel.events"
```

- **Upgrade OpenPanel**: bump the tag of op-api, op-worker and op-dashboard
  together and watch op-api's log for "Migrations finished". A PostgreSQL major
  is the dump and restore [below](#the-postgresql-major-migration).
- **Add a user**: set `ALLOW_REGISTRATION: "true"` in `op-api.yaml`, the only
  reader, deploy, invite, set it back. Always keep a password login: OAuth-only
  with signup disabled locks you out (upstream #363).
- **Public ingest**: op-api's `analytics.jterrazz.com/api/track` entry is
  `public: true`, so external-dns writes its record like any public route's.

## Backup and restore

```bash
# PostgreSQL
kubectl exec -n platform-analytics deploy/op-postgres -- \
  pg_dump -U openpanel -d openpanel --clean --if-exists > openpanel-pg-$(date +%F).sql
kubectl exec -i -n platform-analytics deploy/op-postgres -- \
  psql -U openpanel -d openpanel < openpanel-pg-YYYY-MM-DD.sql

# ClickHouse: lands in openpanel/clickhouse/backups/ on the Mac
kubectl exec -n platform-analytics deploy/op-clickhouse -- clickhouse-client --query \
  "BACKUP DATABASE openpanel TO File('/var/lib/clickhouse/backups/openpanel-$(date +%F).zip')"
```

Redis is a rebuildable queue: a file copy of `openpanel/redis/` is enough.

## The PostgreSQL major migration

How OpenPanel's PostgreSQL went from 14 to 17, kept for the next major: about
15 minutes of dashboard and ingest downtime at this data size. Dump with the
newer major's `pg_dumpall`. The namespace's egress baseline refuses a throwaway
`kubectl run` pod, so run the newer client as an ephemeral container inside the
PostgreSQL pod, under `--profile=baseline`: the default debug profile adds
`SYS_PTRACE`, which Pod Security refuses.

```bash
# 1. Stop the writers, not postgres; keep the deploy workflow quiet meanwhile.
kubectl scale -n platform-analytics --replicas=0 deploy/op-api deploy/op-worker deploy/op-dashboard

# 2. Dump with the newer client; check it ends in \unrestrict and holds every CREATE TABLE.
kubectl debug -q -i pod/<op-postgres-pod> -n platform-analytics --profile=baseline \
  --image=postgres:<new>-alpine --env PGPASSWORD="$POSTGRES_PASSWORD" -- \
  pg_dumpall -h 127.0.0.1 -U openpanel --quote-all-identifiers > openpanel-all-$(date +%F).sql

# 3. Stop postgres and MOVE the old data aside: it is the rollback.
kubectl scale -n platform-analytics --replicas=0 deploy/op-postgres
mv ~/.studio-infrastructure/data/openpanel/postgres/pgdata \
   ~/.studio-infrastructure/data/openpanel/postgres/pgdata-pg<old>-$(date +%F)
mkdir -p ~/.studio-infrastructure/data/openpanel/postgres/pgdata

# 4. Bump the image in src/kubernetes/services/openpanel/op-postgres.yaml and deploy it.
kubectl rollout status -n platform-analytics deploy/op-postgres --timeout=180s

# 5. Restore, then bring the writers back; op-api migrates on boot.
kubectl exec -i -n platform-analytics deploy/op-postgres -- \
  psql -X -U openpanel -d postgres < openpanel-all-YYYY-MM-DD.sql
kubectl scale -n platform-analytics --replicas=1 deploy/op-api deploy/op-worker deploy/op-dashboard
```

Verify that `\dt` lists the tables, the dashboard loads its projects and a test
event reaches ClickHouse. To roll back, scale everything to 0, move the old
directory back to `pgdata`, restore the old image and scale up.
