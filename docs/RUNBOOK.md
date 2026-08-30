# Runbook

The 2am document: where the secrets are, what to run when something is down,
and how to rebuild from nothing. Design lives in [../README.md](../README.md).

## Reaching the cluster

```bash
orb -m jterrazz-infrastructure -u root kubectl get pod -A   # most reliable
ssh root@jterrazz-infrastructure@orb                        # OrbStack SSH proxy
export KUBECONFIG=./kubeconfig.yaml                         # make kubeconfig
```

`kubeconfig.yaml` is fetched by the k3s role at the end of every `make deploy`
and rewritten to the node's MagicDNS name — it only works from a tailnet
client. `make kubeconfig` regenerates it (fetch + rewrite) without a deploy,
which is what `make diff` tells you to run when the file is missing or stale. The `orb` SSH alias resolves only with `~/.orbstack/ssh/config` in play
(which is why `inventories/laptop.yml` passes it explicitly); `orb -m …` needs
nothing but OrbStack.

## Secrets inventory

### Infisical — project `jterrazz`, environment `prod`

Fetched at deploy time by `scripts/infisical-vars.py` — the single
implementation, shared by `scripts/deploy.sh` and
`.github/workflows/deploy-platform.yaml`. Each path is fetched **explicitly**,
never recursively, so short key names can repeat across folders. A missing key
aborts the run; `roles/platform/tasks/preflight.yml` asserts the same set again
on the host.

| Path                               | Key                             | Ansible var                     | Scope         |
| ---------------------------------- | ------------------------------- | ------------------------------- | ------------- |
| `/jterrazz-infrastructure`         | `CLOUDFLARE_API_TOKEN`          | `cloudflare_api_token`          | site+platform |
|                                    | `CLOUDFLARE_TUNNEL_TOKEN`       | `cloudflare_tunnel_token`       | site+platform |
|                                    | `DOCKER_REGISTRY_PASSWORD`      | `registry_password`             | site+platform |
|                                    | `TAILSCALE_OAUTH_CLIENT_ID`     | `tailscale_oauth_client_id`     | site only     |
|                                    | `TAILSCALE_OAUTH_CLIENT_SECRET` | `tailscale_oauth_client_secret` | site only     |
| `/jterrazz-infrastructure/grafana` | `ADMIN_PASSWORD`                | `grafana_admin_password`        | site+platform |

`BACKUP_ENCRYPTION_KEY` also lives at `/jterrazz-infrastructure` but is **not**
in the table above: no deploy reads it, only `make backup` does, and it is
fetched directly rather than through the extra-vars file. See
[Backups](#backups).

The `platform` scope drops the Tailscale OAuth pair — `platform.yml` only reads
Tailscale *facts* off an already-joined node. `infisical_client_id` /
`infisical_client_secret` are the one exception to all of this: they come from
`.env` (or the GitHub secrets in CI) and are written into the extra-vars file,
because the in-cluster operator needs them and they cannot come from Infisical
itself.

Synced **into the cluster** by the operator from `InfisicalSecret` CRs — the
deploy script never sees these:

| Path                                       | Becomes Secret                | Keys                                                            |
| ------------------------------------------ | ----------------------------- | --------------------------------------------------------------- |
| `/jterrazz-infrastructure`                 | `cloudflared-secrets`         | `CLOUDFLARE_TUNNEL_TOKEN`                                        |
| `/jterrazz-infrastructure/librechat`       | `librechat-credentials-env`   | `CREDS_KEY`, `CREDS_IV`, `JWT_SECRET`, `JWT_REFRESH_SECRET`      |
| `/jterrazz-infrastructure/openpanel`       | `openpanel-secrets`           | `POSTGRES_PASSWORD`, `COOKIE_SECRET`, `DATABASE_URL`, `DATABASE_URL_DIRECT` |
| `/jterrazz-infrastructure/otel-collector`  | `otel-collector-secrets`      | `LANGFUSE_BASIC_AUTH`                                            |
| `/<app>/…`                                 | `<app>-secrets`               | whatever the app's `spec.secrets.env` lists                      |

There is no `/jterrazz-infrastructure/registry` folder: the registry's password
is `DOCKER_REGISTRY_PASSWORD` at the root path, bcrypt-hashed into the
`registry-auth` Secret by `roles/platform/tasks/bootstrap.yml`.

### `/jterrazz-actions` — app CI

The default `infisical-secret-path` of `jterrazz-actions/actions/infra-connect`,
consumed by every app repo's pipeline: `DOCKER_REGISTRY_USERNAME`,
`DOCKER_REGISTRY_PASSWORD`, `TAILSCALE_OAUTH_CLIENT_ID`,
`TAILSCALE_OAUTH_CLIENT_SECRET`, `KUBECONFIG_BASE64`.

**`KUBECONFIG_BASE64` must be refreshed after every repave.** k3s regenerates
its CA on a fresh install, so the old client certificate stops authenticating
and every app deploy fails at `helm upgrade`. After `make deploy`:

```bash
base64 -i kubeconfig.yaml | pbcopy
```

then paste it into the Infisical UI at `/jterrazz-actions` (env `prod`). The
`.env` machine identity is **read-only** on that path — this step cannot be
scripted with the credentials this repo holds.

### GitHub secrets (repo `jterrazz/jterrazz-infrastructure`)

| Secret                    | Used by                                        |
| ------------------------- | ---------------------------------------------- |
| `INFISICAL_CLIENT_ID`     | `deploy-platform.yaml`, `publish-chart.yaml`   |
| `INFISICAL_CLIENT_SECRET` | same                                           |
| `CI_DEPLOY_SSH_PRIVATE`   | `deploy-platform.yaml` — SSH into the VM       |

The public half of that keypair is committed as `security_ci_deploy_pubkey` in
`ansible/roles/security/defaults/main.yml`; the `security` role installs it in
root's `authorized_keys`.

### GitHub secrets (every app repo)

`INFISICAL_CLIENT_ID` / `INFISICAL_CLIENT_SECRET` — the same machine identity as
above, which `infra-connect` exchanges for `/jterrazz-actions`. One identity is
shared by CI, the cluster's Infisical operator and the local `.env`; rotating it
means updating every deploying repo. A repo that lacks them fails the *Release*
job at `Missing universal auth credentials` — after a green validate, so a first
deploy looks like it almost worked.

```bash
set -a; . ./.env; set +a
gh secret set INFISICAL_CLIENT_ID     -R jterrazz/<repo> --body "$INFISICAL_CLIENT_ID"
gh secret set INFISICAL_CLIENT_SECRET -R jterrazz/<repo> --body "$INFISICAL_CLIENT_SECRET"
```

### Local `.env` (gitignored, repo root)

```
PULUMI_ACCESS_TOKEN
INFISICAL_CLIENT_ID
INFISICAL_CLIENT_SECRET
```

## Security controls

Five things enforce the boundary. Each is here because a probe found a real
hole, and each names the check that proves it still holds.

| Control | Where | Verify |
| ------- | ----- | ------ |
| Peer-isolation firewall | `roles/security` -> `nft-guard.conf.j2`, unit `nft-guard.service` | from a second machine: `orb create debian:trixie t && orb -m t -u root bash -c 'echo > /dev/tcp/<node-ip>/6443'` must fail |
| Secrets encrypted at rest | `secrets-encryption: true` in the k3s config | `k3s secrets-encrypt status` -> Enabled; then grep a real Secret value in `state.db` and find nothing |
| API audit log | `audit-policy.yaml.j2`, Metadata level | `wc -l <data-dir>/server/logs/audit.log` grows |
| Pod Security Admission | `cluster/namespaces.yaml` | `kubectl get ns -L pod-security.kubernetes.io/enforce` |
| kube-system NetworkPolicy | `cluster/network-policies/kube-system.yaml` | DNS from a fresh pod, `kubectl top nodes`, and a tailnet curl (see below) |

### The two things that will bite

**OrbStack machines are not isolated from each other by default.** Every one
mounts every other's rootfs at `/mnt/machines/<name>/` and reads it **as
root** — so file permissions are irrelevant there, `0600` included. A plain
`orb create` machine can read this cluster's data directory and its
kubeconfig. Create dev machines with `--isolated` (no `/mnt/machines` at all)
and add `--isolate-network` for the host. Note that `--isolate-network` does
NOT block peer machines despite the docs, which is why the nftables guard
exists. `--isolated` is impossible for a k3s node: the unprivileged userns
refuses kubelet's `noswap` tmpfs and k3s restart-loops without ever serving.

**Test the tailnet path, not just the public one.** cloudflared dials
Traefik's ClusterIP directly, so a kube-system policy can break every tailnet
client while smoke stays 11/11 and the cluster looks green. CI is a tailnet
client — it pulls from the registry — so this surfaces as a failed deploy:

```bash
curl -sk -H "Host: registry.internal.jterrazz.com" https://<tailnet-ip>/v2/   # 401
curl -sk -H "Host: grafana.internal.jterrazz.com" https://<tailnet-ip>/api/health  # 200
```

## Troubleshooting

```bash
kubectl get pod -A | grep -v Running ; helm list -A ; kubectl get certificate -A

# What would the next platform deploy change? (read-only, needs the tailnet)
make diff
./scripts/helmfile.sh diff -l name=grafana     # one release

# cert-manager after any k3s churn (webhook + cainjector lose the API)
kubectl rollout restart -n platform-networking \
  deploy/cert-manager deploy/cert-manager-webhook deploy/cert-manager-cainjector

# Cloudflare tunnel: connected? serving?
kubectl logs -n platform-networking deploy/cloudflared --tail=30 | grep -E 'Registered|edge'
POD_IP=$(kubectl get pod -n platform-networking -l app.kubernetes.io/name=cloudflared \
  -o jsonpath='{.items[0].status.podIP}')
curl -s "http://$POD_IP:2000/metrics" | grep '^cloudflared_tunnel_total_requests '

# Every pod's stdout is in VictoriaLogs, shipped by the otel-collector's
# filelog receiver (it tails /var/log/pods off a hostPath; there is no separate
# log agent any more). Query in Grafana's "VictoriaLogs" datasource — the
# language is LogsQL, NOT LogQL:
#   {k8s.namespace.name="platform-analytics"}
#   {app="op-api"} error
#   {app="op-api"} | stats by (k8s.container.name) count()
# The four stream fields are k8s.namespace.name / k8s.pod.name /
# k8s.container.name / app — pinned by the VL-Stream-Fields header on the
# collector's exporter. Everything else (node, deployment, pod uid, file path)
# is a regular field: filter on it, just do not expect it to narrow the scan.
#
# LogQL -> LogsQL, the three that bite: `|=` "x" is just a bare word or
# "quoted phrase"; `| json` is unnecessary (JSON bodies are parsed on ingest);
# `| line_format` / `sum by (...) (rate(...))` become the `format` and `stats`
# pipes. Full mapping:
#   https://docs.victoriametrics.com/victorialogs/logsql/
#
# No logs arriving? Check the collector, not a DaemonSet:
kubectl logs -n platform-telemetry deploy/otel-collector | grep -iE 'permission denied|filelog|k8sattributes'
kubectl get clusterrole otel-collector -o yaml   # pods+namespaces+replicasets read

# Registry DNS is the usual suspect for a fleet-wide ImagePullBackOff.
# On the node: must resolve to a 100.x tailnet IP.
getent hosts registry.internal.jterrazz.com ; tailscale status
```

**Tailscale identity collision.** If a VM with the same hostname was destroyed
without `tailscale logout`, the new one joins as `jterrazz-infrastructure-2`,
MagicDNS stops resolving the canonical name, and every private hostname breaks.
Delete the stale device in the Tailscale admin console, or rename via the API:

```bash
curl -H "Authorization: Bearer $TS_API_KEY" -X POST \
  "https://api.tailscale.com/api/v2/device/<id>/name" \
  -d '{"name":"jterrazz-infrastructure"}'
```

A node that comes back **logged out** after a reboot self-heals through
`tailscale-autoauth.service` (installed by the `tailscale` role). If it did
not, check that unit's journal first — the failure chain is registry NXDOMAIN
→ ImagePullBackOff on every app pod → Cloudflare 503 on every public hostname.

## Repaving the cluster

The sequence as executed on 2026-07-25 (Debian 13 migration):

```bash
# 1. Stop the workloads. `systemctl stop k3s` does NOT stop running
#    containers — they keep writing to /var/lib/k8s-data mid-backup.
orb -m jterrazz-infrastructure -u root /usr/local/bin/k3s-killall.sh

# 2. Back up the data directory (it lives on the Mac, so tar it there).
tar -czf ~/k8s-data-$(date +%F).tar.gz -C ~/.jterrazz-infrastructure data

# 3. Repave. `make destroy` deletes the VM only; the Mac-side data dir stays.
make destroy
make deploy

# 4. Refresh KUBECONFIG_BASE64 in Infisical /jterrazz-actions (see above) —
#    nothing else will deploy until this is done.

# 5. Rebuild + redeploy every app onto the new (empty) registry.
make redeploy-apps
```

Step 5 is required, not optional: registry blobs are hostPath and do survive,
but no app's Helm release does — the cluster is new. The script staggers the
six dispatches by 20s so six simultaneous Docker builds don't compete for RAM
on one node. Post-repave verification items (uid pins, remaining egress narrowing)
live in the pinned GitHub issue. Every namespace in
`kubernetes/cluster/namespaces.yaml` has a NetworkPolicy file. The OpenPanel
`API_URL_SSR` rationale lives in `kubernetes/services/openpanel/config.yaml` —
do not retell it here.

## Backups

`make backup` writes an AES-256 archive of `~/.jterrazz-infrastructure/data` to
`~/.jterrazz-infrastructure/backups/` and verifies it by decrypting it back —
an archive nobody has opened is a guess, not a backup.

`make backup ARGS=--consistent` runs `k3s-killall.sh` first. Without it the
databases are captured mid-write: `systemctl stop k3s` does NOT stop the
containers, which is how two earlier backups came out torn.

The passphrase is `BACKUP_ENCRYPTION_KEY` in Infisical at
`/jterrazz-infrastructure` (env `prod`). Nothing local is needed: with
`INFISICAL_CLIENT_ID` / `INFISICAL_CLIENT_SECRET` in `.env`, `make backup`
fetches it itself. It is deliberately NOT routed through
`scripts/infisical-vars.py`, which writes the deploy extra-vars onto the node —
this key has no business there.
It is **permanent**: rotating it does not re-encrypt existing archives, it
orphans them, and losing it loses every archive it ever produced. That is the
whole point — a copy on Time Machine, an external disk or a future machine is
useless without it, and fully restorable with it.

Why encryption and not `chmod`: the data tree has to stay traversable by
"other". The pods write through virtiofs as uids 70, 101, 472, 999 and 1000,
so dropping world-execute on the directory breaks Postgres, ClickHouse,
Grafana, Mongo and signews-api at once. Permissions cannot protect this tree;
encrypting what leaves it can.

## Restoring from backup

All persistent state is one directory: `/var/lib/k8s-data` on the node, which
is a symlink to `~/.jterrazz-infrastructure/data` on the Mac. Restore = stop
the consumer, replace the directory, start it again.

```
data/
├── grafana/                    grafana.db — users, API keys, alert state
├── victoria-metrics/           metrics (30d)
├── victoria-logs/              logs (90d)
├── victoria-traces/            traces (720h)
├── registry/                   Docker registry blobs
├── librechat/                  mongo/ + uploads/
├── openpanel/                  postgres/ + clickhouse/ + redis/
├── signews-api-{prod,next,staging}/, gateway-intelligence-prod/
│                               per-app volumes from the app chart
├── prometheus/  loki/  tempo/  ORPHANED — replaced by the three above
├── n8n/                        ORPHANED — n8n was removed
└── portainer/                  ORPHANED — Portainer was removed
```

The orphans have no workload and no PV any more: the services were deleted
(namespaces, CNAMEs and manifests are gone), but the PVs were `Retain`, so any
of them can be resurrected from git history plus that directory. The
prometheus/loki/tempo trio is the ONLY copy of pre-migration metrics and logs —
nothing reads it, and no Victoria component can. Keep it until the new stores
have accumulated a window worth trusting, then delete it by hand.

For consistent database dumps rather than a file copy, see the backup sections
of [openpanel](../kubernetes/services/openpanel/README.md#backup--restore) and
[librechat](../kubernetes/services/librechat/README.md).

## Rotating credentials

| What                              | How                                                                                                   |
| --------------------------------- | ------------------------------------------------------------------------------------------------------ |
| Any Infisical-held secret         | Change it in the Infisical UI, then `make deploy-platform`. No `InfisicalSecret` in this repo sets `spec.syncConfig`, so every one resyncs on the **operator's own default interval**; `kubectl delete pod -n platform-secrets -l control-plane=controller-manager` forces it now. Note the resync only updates the **Secret** — a consumer that reads it as `env` still needs a rollout restart. |
| `CLOUDFLARE_TUNNEL_TOKEN`         | New connector token in Zero Trust → store at `/jterrazz-infrastructure` → wait for the resync (or force it as above), then `kubectl rollout restart deploy/cloudflared -n platform-networking` (it reads `TUNNEL_TOKEN` once, at startup). |
| `DOCKER_REGISTRY_PASSWORD`        | Rotate in Infisical **and** at `/jterrazz-actions`, then `make deploy-platform` to regenerate `registry-auth`. |
| CI deploy SSH key                 | `ssh-keygen -t ed25519`, paste the pubkey into `security_ci_deploy_pubkey`, `gh secret set CI_DEPLOY_SSH_PRIVATE -R jterrazz/jterrazz-infrastructure`, then `make deploy` to roll it onto the VM. |
| `KUBECONFIG_BASE64`               | Regenerated by every repave — see the procedure above.                                                  |
| `cloudflare:apiToken` (Pulumi)    | `cd pulumi && pulumi config set --secret cloudflare:apiToken <new>`.                                     |

## Add a new platform service

1. Namespace: add it to `kubernetes/cluster/namespaces.yaml` if it doesn't
   already have one — never `kubectl create ns`. Give it a NetworkPolicy file
   under `kubernetes/cluster/network-policies/`.
2. Values: add `kubernetes/services/<svc>/{helm.yaml,platform.yaml}` (upstream
   chart values + service-chart values), following an existing service as a
   template.
3. Release: add ONE block to `kubernetes/helmfile.yaml.gotmpl` — name,
   namespace, chart, pinned `version:` and `values:`. Its `<svc>-platform`
   sibling is `inherit: [{template: service}]` and needs no version. That block
   is the whole declaration: Ansible applies it, `make diff` previews it and
   Renovate bumps it, with nothing to keep in sync. If the chart comes from a
   repository not already listed at the top of the file, add that too.
4. Ingress: set `access: private` (default) or `access: cluster-internal` in
   `platform.yaml`; add a private hostname to `private_hostnames` in
   group_vars **and** `PRIVATE_CHECKS` in `scripts/smoke.sh`. A public service
   needs a new zone — see "New public zone" in `CLAUDE.md`.
5. `make check` locally, then a PR — `deploy-platform.yaml` deploys on merge.

## Add a new app

Apps live in their own repo and deploy themselves; this repo only owns the
chart they render through. Full schema and merge semantics:
[kubernetes/charts/app/README.md](../kubernetes/charts/app/README.md).

1. Add `.infrastructure/application.yaml` to the app repo, with `tag:` set on
   every environment — omitting it silently deploys "staging" instead.
2. Set `INFISICAL_CLIENT_ID` / `INFISICAL_CLIENT_SECRET` as GitHub secrets on
   the app repo — see [GitHub secrets (every app repo)](#github-secrets-every-app-repo)
   above.
3. Expose `make build`, `make lint`, `make test` and call the shared workflow
   in `jterrazz/jterrazz-actions`.
4. First deploy creates the namespace and Certificate; this repo needs no
   changes.

## Version decisions

Pins held below the current upstream release — do not re-open without new
evidence.

| Component  | Held at        | Why                                                                                                                                                                                              |
| ---------- | -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| MongoDB    | `7.0`          | LibreChat does support 8 (`mongo:8.0.20` in its compose at the v0.8.7 tag) but **8.0 will not boot on this host**: SERVER-121912 blocks MongoDB on Linux kernel ≥ 6.19 and this node runs OrbStack's 7.0.11 kernel. Measured: `mongo:8.0` exits 1, `mongo:7.0` and `mongo:8.2` start. 8.2 is outside the line LibreChat cites, and the FCV bump is irreversible. Retest when an 8.0.x carries the fix. |
| PostgreSQL | `14-alpine`    | OpenPanel pins `postgres:14-alpine` in both compose files and documents no other version. Only Prisma (the ORM, not the app) reaches higher. **EOL 2026-11-12 — schedule this separately.**          |
| ClickHouse | `25.10.2.65`   | Already exactly what OpenPanel's self-hosting compose pins. Newer is uncited and 26.5/26.7 change event-ingest datetime parsing and reject the AggregatingMergeTree schema shape OpenPanel uses.     |
| Redis 8.x  | staying on 7.x | Neither OpenPanel nor BullMQ publishes a Redis 8 support statement.                                                                                                                                |

#### If the PostgreSQL 14 → 17 migration is later approved

Not scheduled — recorded here so it is not re-derived under time pressure. DB is
~26 MB. **Dump with the *newer* server's `pg_dumpall`**, which is what the
PostgreSQL docs require across majors.

```bash
# 1. Stop the writers (NOT postgres itself — it must serve the dump).
kubectl scale -n platform-analytics --replicas=0 deploy/op-api deploy/op-worker deploy/op-dashboard

# 2. Dump using a throwaway PG 17 client against the live PG 14 service.
kubectl run pgdump-17 -n platform-analytics --rm -i --restart=Never \
  --image=postgres:17-alpine --env PGPASSWORD="$POSTGRES_PASSWORD" -- \
  pg_dumpall -h op-postgres -U openpanel --quote-all-identifiers > openpanel-all-$(date +%F).sql
test -s openpanel-all-*.sql && grep -c "CREATE DATABASE" openpanel-all-*.sql   # sanity

# 3. Stop postgres and MOVE the old data dir aside — never delete it; it is the
#    rollback. A PG 17 server cannot read a PG 14 cluster directory.
kubectl scale -n platform-analytics --replicas=0 deploy/op-postgres
#    On the Mac (/var/lib/k8s-data is a symlink to ~/.jterrazz-infrastructure/data):
mv ~/.jterrazz-infrastructure/data/openpanel/postgres/pgdata \
   ~/.jterrazz-infrastructure/data/openpanel/postgres/pgdata-pg14-$(date +%F)
mkdir -p ~/.jterrazz-infrastructure/data/openpanel/postgres/pgdata

# 4. Swap the image to postgres:17-alpine in kubernetes/services/openpanel/postgres.yaml.
#    uid/gid 70:70 is correct for the alpine variant on 17 as well; the
#    fix-perms initContainer chowns the new empty dir. PGDATA stays
#    /var/lib/postgresql/data/pgdata so initdb never sees lost+found.
kubectl apply -f kubernetes/services/openpanel/postgres.yaml
kubectl scale -n platform-analytics --replicas=1 deploy/op-postgres
kubectl rollout status -n platform-analytics deploy/op-postgres --timeout=180s

# 5. Restore, then bring the app back. op-api runs Prisma migrations on boot.
kubectl exec -i -n platform-analytics deploy/op-postgres -- \
  psql -X -U openpanel -d postgres < openpanel-all-YYYY-MM-DD.sql
kubectl scale -n platform-analytics --replicas=1 deploy/op-api deploy/op-worker deploy/op-dashboard
kubectl rollout status -n platform-analytics deploy/op-api --timeout=300s
```

**Downtime:** dashboard + ingest down for the whole procedure — budget 15-20
min at this data size.

**Verify:** `kubectl exec -n platform-analytics deploy/op-postgres -- psql -U openpanel -d openpanel -c '\dt'`
lists the OpenPanel tables; the dashboard loads projects; a test event reaches
`analytics.jterrazz.com/api/track` and appears in ClickHouse.

**Rollback:** scale everything to 0, `mv` the `pgdata-pg14-*` directory back to
`pgdata`, restore the `postgres:14-alpine` image, scale up. The old cluster
directory is untouched, which is the entire reason step 3 moves rather than
deletes it.
