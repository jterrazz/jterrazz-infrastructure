# OpenPanel (self-hosted product analytics)

Private dashboard on **`openpanel.internal.jterrazz.com`** (Tailscale-only) + public
event ingest on **`analytics.jterrazz.com/api/track`** (cloudflared tunnel).
Namespace **`platform-analytics`**.

**Who sends events:** the externally-hosted `jterrazz.com` site (origins
`https://jterrazz.com` and `https://www.jterrazz.com`), which POSTs directly
to the public ingest host. That is the only live sender. There is no shared
SDK: a `@jterrazz/analytics` package was planned and never built, so the site
integrates OpenPanel's browser snippet itself. Other origins listed in
`API_CORS_ORIGINS` are pre-authorised for sites that do not send yet.

## Architecture

```
 jterrazz.com (browser) ─► analytics.jterrazz.com/api/track ──► Cloudflare edge
        │                                                          │ tunnel
        ▼                                                          ▼
   op-api (/track only, public IngressRoute, stripPrefix /api) ◄─ Traefik
        │                                                          ▲
   me on tailnet ──► openpanel.internal.jterrazz.com (private IngressRoute) ┘
        │  /api/*  → op-api (dashboard tRPC + realtime /api/live/*)
        │  /*      → op-dashboard (UI)
        ▼
   op-worker (BullMQ)   Postgres   ClickHouse   Redis
```

- **op-api** owns DB migrations (`pnpm -r run migrate:deploy` on boot: Prisma
  for Postgres + code-migrations for ClickHouse), then `pnpm start`.
- **op-worker** runs the BullMQ queues/crons (event/session/profile flushers).
- **op-dashboard** is the Next.js UI, and it SSRs against its own public URL
  rather than an in-cluster one. `config.yaml` owns that rationale and the
  retirement condition; the CoreDNS special case below is one of the three
  things it rests on.
- Public host routes **only** `/api/track`; everything else (dashboard,
  `/api/export`, `/api/live`, admin) is reachable only via the tailnet.

## Deployed versions (pinned)

| Component     | Image                                          |
|---------------|------------------------------------------------|
| op-api        | `lindesvard/openpanel-api:2.2.1`                 |
| op-worker     | `lindesvard/openpanel-worker:2.2.1`              |
| op-dashboard  | `lindesvard/openpanel-dashboard:2.2.1`           |
| ClickHouse    | `clickhouse/clickhouse-server:25.10.2.65`      |
| PostgreSQL    | `postgres:14-alpine`                           |
| Redis         | `redis:7.4.9-alpine`                           |
| (init) chown  | `busybox:1.38` (digest-pinned, see manifests)  |

The namespace itself is **not** declared here — it lives with every other
platform namespace in
`kubernetes/cluster/namespaces.yaml` and is applied with the rest of that
directory.

All six workloads run with a hardened container `securityContext`
(`allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`,
`seccompProfile: RuntimeDefault`). The three datastores additionally pin a
non-root uid — ClickHouse 101, Postgres 70 (alpine variant), Redis 999 — each
paired with a root `fix-perms` initContainer that chowns the root-owned
hostPath dir, since pinning the uid bypasses the entrypoint's own chown. The
`op-*` app images do not document their user, so they are hardened without a
uid pin (see the open item in `apps.yaml`).

ClickHouse config (`clickhouse.yaml` ConfigMap) is upstream's self-hosting
config = the **issue #324 mitigation**: logger→console, all heavy system log
tables removed, plus a per-query `max_memory_usage` 1 GiB cap (issue #382). No
ClickHouse/Redis password (upstream design); the datastores are firewalled to
the namespace by `kubernetes/cluster/network-policies/platform-analytics.yaml`.

## Where the data lives

All three datastores use manual **hostPath PVs (`Retain`)** under
`/var/lib/k8s-data` → on OrbStack that's a symlink to
`/mnt/mac/Users/jterrazz.agent/.jterrazz-infrastructure/data` (the Mac), so data
survives pod restarts, `kubectl delete`, helm/redeploys and `pulumi destroy`.

| PVC / PV               | Size  | Path (`/var/lib/k8s-data/...`) |
|------------------------|-------|--------------------------------|
| `openpanel-postgres`   | 3Gi   | `openpanel/postgres/pgdata`    |
| `openpanel-clickhouse` | 10Gi  | `openpanel/clickhouse`         |
| `openpanel-redis`      | 1Gi   | `openpanel/redis`              |

One directory per app (repo convention): the three datastores nest under
`openpanel/` even though each has its own PV/PVC.

All three PV/PVC pairs come from the **platform-service chart**, declared as the
`storage` map in `service.yaml`. They used to be hand-written blocks at the
top of `postgres.yaml` / `redis.yaml` / `clickhouse.yaml`; names, sizes and
hostPaths are unchanged by the move. `service.yaml` sets no `host` — OpenPanel
is the one service whose ingress the chart cannot express (two hostnames,
different exposure, path routing), so `ingress.yaml` stays hand-written.

## Secrets & config

- **Secrets** — Infisical `/jterrazz-infrastructure/openpanel` (prod) → synced to Secret
  `openpanel-secrets` by the Infisical operator (read-only CI identity). Keys:
  `POSTGRES_PASSWORD`, `COOKIE_SECRET`, `DATABASE_URL`, `DATABASE_URL_DIRECT`.
  The project **clientId/clientSecret** (from the OpenPanel UI) should also be
  stored here once created.
- **Non-secret config** — ConfigMap `openpanel-config` (URLs, CORS origins,
  `SELF_HOSTED=true`, Postgres user/db). Add a new sending site's origin to
  `API_CORS_ORIGINS` — the ingest is a **browser** POST, so an origin missing
  from that list is rejected at the CORS preflight and the events are simply
  never delivered, with nothing in op-api's logs to say so. List every variant
  a browser can actually be on — `jterrazz.com` **and** `www.jterrazz.com` are
  both present for that reason.

## Common operations

```bash
export KUBECONFIG=./kubeconfig.yaml
kubectl get pods -n platform-analytics
kubectl get certificate -n platform-analytics
kubectl logs -n platform-analytics deploy/op-api --tail=50
# ClickHouse shell
kubectl exec -n platform-analytics deploy/op-clickhouse -- clickhouse-client --query "SELECT count() FROM openpanel.events"
```

### Upgrade OpenPanel

Bump the `2.2.1` tags for `op-api`/`op-worker`/`op-dashboard` in `apps.yaml`
(keep the three in lockstep), then redeploy (`kubectl apply -f apps.yaml` or
re-run the playbook). op-api runs any new migrations on boot — watch its logs
for "Migrations finished" before trusting the new version. Bump ClickHouse /
Postgres / Redis only deliberately (Postgres major bumps need a dump/restore,
not an in-place image swap). Check the OpenPanel self-hosting changelog for the
matching ClickHouse version.

### Registration

`ALLOW_REGISTRATION` is `"false"` in `apps.yaml` — the admin account exists and
public signup is closed. To add a user later, flip both occurrences (op-api +
op-dashboard) to `"true"`, redeploy, invite/sign up, then flip back. Keep a
password login (OAuth-only + signup-disabled can lock you out — issue #363).

## Backup & restore

Data is `Retain` hostPath on the Mac; the simplest durable backup is a
file-level snapshot of the three dirs, but for consistency use the DB-native
tools below.

### PostgreSQL

```bash
# Backup
kubectl exec -n platform-analytics deploy/op-postgres -- \
  pg_dump -U openpanel -d openpanel --clean --if-exists > openpanel-pg-$(date +%F).sql
# Restore (into a running, empty op-postgres)
kubectl exec -i -n platform-analytics deploy/op-postgres -- \
  psql -U openpanel -d openpanel < openpanel-pg-YYYY-MM-DD.sql
```

### ClickHouse

Native BACKUP to a file inside the data volume, then copy it off the Mac:

```bash
kubectl exec -n platform-analytics deploy/op-clickhouse -- \
  clickhouse-client --query "BACKUP DATABASE openpanel TO File('/var/lib/clickhouse/backups/openpanel-$(date +%F).zip')"
# The file lands at /var/lib/k8s-data/openpanel/clickhouse/backups/ on the Mac.
# Restore: RESTORE DATABASE openpanel FROM File('...').
```

For a cold copy instead: scale `op-clickhouse` to 0, `tar` the
`openpanel/clickhouse/` dir on the Mac, scale back to 1.

### Redis

It's a durable BullMQ queue (AOF on), not a source of truth — losing it drops
only in-flight jobs. `appendonly.aof`/`dump.rdb` live in `openpanel/redis/` on
the Mac; a file snapshot is sufficient. No scheduled backup needed.

## Gotchas seen during deploy

- **cert-manager webhook** was down at first apply (`no endpoints available`) —
  the documented post-k3s-churn issue. Fix: `kubectl rollout restart -n
  platform-networking deploy/cert-manager deploy/cert-manager-webhook
  deploy/cert-manager-cainjector`, then re-apply `ingress.yaml`.
- **Public ingest — CNAME and tunnel route are managed separately.** The
  cloudflared tunnel routes per-hostname (not a wildcard):
  - CNAME `analytics` → the tunnel is created by the Cloudflare Zero Trust
    UI when the Public Hostname is added; nothing for it lands in this repo.
  - The per-hostname **routing rule** must be added in the Zero Trust
    dashboard (Service: HTTPS → `traefik.kube-system.svc.cluster.local:443`,
    No TLS Verify ON) — it needs Tunnel:Edit, which the DNS token lacks.
  A CNAME with no matching route returns a 404 from cloudflared; a route with
  no CNAME never resolves. Both are required.
- **ClickHouse hostPath perms**: the pod runs as uid 101; an init container
  chowns `/var/lib/clickhouse` because hostPath dirs are created root-owned.
- **Dashboard SSR resolves `openpanel.internal.jterrazz.com` to Traefik's
  ClusterIP, in-cluster.** The `coredns-custom` block maps that host to
  Traefik's ClusterIP (a separate hosts line from the other private hosts,
  which use the node tailnet IP); resolving it to the node tailnet IP instead
  hairpins through the ServiceLB and times out. Because those SSR calls then
  arrive at Traefik from a **pod IP**, the private IngressRoute uses
  `cluster-internal-access` rather than `private-access`.
  `kubernetes/services/openpanel/config.yaml` owns this rationale in full,
  including what has to happen before any of it can be removed.
