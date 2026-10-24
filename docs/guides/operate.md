# Operating

Where the secrets are, what to run when something is down, and how to rebuild
from nothing. The design is [Architecture](../concepts/architecture.md); the
rules a change follows are [Develop](develop.md).

## Reaching the cluster

```bash
orb -m jterrazz-infrastructure -u root kubectl get pod -A   # from the Mac, always
ssh root@jterrazz-infrastructure@orb                        # OrbStack's SSH proxy
export KUBECONFIG=./kubeconfig.yaml                         # from a tailnet client
```

Every `make deploy` writes `kubeconfig.yaml` with the node's MagicDNS name as
its server, so it works only from the tailnet; `make kubeconfig` rewrites it
without a deploy. The `orb` SSH alias needs `~/.orbstack/ssh/config`, which is
why `inventories/laptop.yml` passes it explicitly.

## Secrets inventory

### Read by the deploy

`ansible/roles/secrets`, the first role of both playbooks, fetches the list
`infisical_secrets` in group_vars on the controller (the Mac or the runner),
each folder explicitly, and stops on a missing key before anything deploys
([ADR-015](../decisions/015-deploy-secrets-are-fetched-once-by-ansible.md)).

| Project, path                                  | Keys                                                                      | Read by                      |
| ---------------------------------------------- | ------------------------------------------------------------------------- | ---------------------------- |
| `jterrazz`, `/jterrazz-infrastructure`         | `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_TUNNEL_TOKEN`                         | both playbooks               |
|                                                | `TAILSCALE_OAUTH_CLIENT_ID`, `TAILSCALE_OAUTH_CLIENT_SECRET`              | `site.yml` only              |
|                                                | `BACKUP_ENCRYPTION_KEY`                                                   | `make backup` only           |
| `jterrazz`, `/jterrazz-infrastructure/grafana` | `ADMIN_PASSWORD`                                                          | both playbooks               |
| `jterrazz-ci`, `/`                             | `DOCKER_REGISTRY_USERNAME`, `DOCKER_REGISTRY_PASSWORD`: the push account  | both playbooks, app CI       |
|                                                | `REGISTRY_PULL_USERNAME`, `REGISTRY_PULL_PASSWORD`: the read-only account | both playbooks, the operator |

The Infisical identity itself (`INFISICAL_CLIENT_ID`, `INFISICAL_CLIENT_SECRET`)
comes from `.env` locally and from the repository's GitHub secrets in CI; the
deploy writes it into `platform-secrets/infisical-credentials` for the
operator.

`jterrazz-ci` is a project of its own because CI reads it over GitHub OIDC:
the machine identity `github-actions` (subject
`repo:jterrazz@18480834/*:ref:refs/heads/main`, audience
`https://github.com/jterrazz`) is a Viewer of that project and of nothing else.

### Synced into the cluster

The operator syncs an `InfisicalSecret` rendered by the release that needs it
(a `service.yaml`'s `secrets:`, an app's `spec.secrets`):

| Infisical path                            | Secret                                       | Keys                                                                         |
| ----------------------------------------- | -------------------------------------------- | ---------------------------------------------------------------------------- |
| `/jterrazz-infrastructure`                | `cloudflared-secrets`                        | `CLOUDFLARE_TUNNEL_TOKEN`                                                    |
| `/jterrazz-infrastructure/openpanel`      | `op-{api,worker,dashboard,postgres}-secrets` | the keys each release names                                                  |
| `/jterrazz-infrastructure/otel-collector` | `otel-collector-secrets`                     | `LANGFUSE_BASIC_AUTH`                                                        |
| `/jterrazz-infrastructure/grafana`        | `grafana-alerting`                           | `contact-point-slack.yaml`, from the optional `SLACK_WEBHOOK_URL`            |
| `jterrazz-ci`, `/`                        | `registry-credentials`                       | `.dockerconfigjson` from the read-only account, in every app namespace pulling from our registry |
| `/<app>`                                  | `<app>-secrets`                              | the app's `spec.secrets.env`                                                 |

### GitHub and local secrets

| Where                              | Secrets                                                                                                                       |
| ---------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| `jterrazz/jterrazz-infrastructure` | `INFISICAL_CLIENT_ID`, `INFISICAL_CLIENT_SECRET`, `CI_DEPLOY_SSH_PRIVATE` (whose public half is `security_ci_deploy_pubkey`) |
| every app repository               | none: an app deploy authenticates with its job's OIDC token                                                                  |
| `.env` (gitignored)                | `INFISICAL_CLIENT_ID`, `INFISICAL_CLIENT_SECRET`                                                                              |

A repave needs nothing new in Infisical: an app job reads the CA from k3s'
`/cacerts` and its identity from GitHub.

## Security controls

| Control                   | Where                                             | Verify                                                                                     |
| ------------------------- | ------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| Peer-isolation firewall   | `roles/security`, `nft-guard.service`             | `make test-host`; from another OrbStack machine, `echo > /dev/tcp/<node-ip>/6443` must fail |
| Secrets encrypted at rest | `secrets-encryption: true` in the k3s config      | `make test-host`; a real Secret value grepped in `state.db` is not found                   |
| API audit log             | `audit-policy.yaml.j2`, Metadata level            | `<data-dir>/server/logs/audit.log` grows                                                   |
| Pod Security              | `pod-security.yaml.j2`, `cluster/namespaces.yaml` | `make test-host`; `kubectl get ns -L pod-security.kubernetes.io/enforce`                   |
| kube-system NetworkPolicy | `cluster/network-policies/kube-system.yaml`       | DNS from a fresh pod, `kubectl top nodes`, and the tailnet curls below                     |

The reasons are [ADR-006](../decisions/006-the-host-has-no-public-inbound-path.md)
and [ADR-018](../decisions/018-pod-security-baseline-is-enforced-by-default.md).

### Test the tailnet path from a peer

cloudflared dials Traefik's ClusterIP, so a broken kube-system policy or a
masquerading tailscaled leaves the public sites up while every tailnet client,
CI included, is refused. Probe from a peer, never from the node, whose own
traffic never crosses `tailscale0`:

```bash
curl -sk -H "Host: registry.internal.jterrazz.com" https://<tailnet-ip>/v2/        # 401
curl -sk -H "Host: grafana.internal.jterrazz.com" https://<tailnet-ip>/api/health  # 200
```

If peers time out, `tcpdump -i any 'tcp port 443 and net 100.64.0.0/10'` on the
node shows the SYNs arriving on `tailscale0`, and `iptables -t nat -L
ts-postrouting` must list no MASQUERADE (`--snat-subnet-routes=false`, ADR-006).

## Troubleshooting

```bash
kubectl get pod -A | grep -v Running ; helm list -A --failed ; kubectl get certificate -A
make smoke                                     # the platform contract, from the Mac
make diff                                      # what the next platform deploy changes (tailnet)
./scripts/helmfile.sh diff -l name=grafana     # one release

# cert-manager after k3s churn: the webhook and cainjector lose the API; restart all three
kubectl rollout restart -n platform-networking \
  deploy/cert-manager deploy/cert-manager-webhook deploy/cert-manager-cainjector

# the tunnel
kubectl logs -n platform-networking deploy/cloudflared --tail=30 | grep -E 'Registered|edge'

# no pod logs in VictoriaLogs: the collector tails /var/log/pods itself
kubectl logs -n platform-telemetry deploy/otel-collector | grep -iE 'permission denied|file_log|k8s_attributes'

# a fleet-wide ImagePullBackOff: on the node, the registry must resolve to a 100.x address
getent hosts registry.internal.jterrazz.com ; tailscale status
```

Logs are queried in Grafana's VictoriaLogs datasource in
[LogsQL](https://docs.victoriametrics.com/victorialogs/logsql/), not LogQL:
`{k8s.namespace.name="platform-analytics"}`, `{app="op-api"} error`,
`{app="op-api"} | stats by (k8s.container.name) count()`. The stream fields are
`k8s.namespace.name`, `k8s.pod.name`, `k8s.container.name` and `app`; every
other attribute filters without narrowing the scan.

A failed release stays failed: the next apply diffs against the failed
revision and skips it. Read `helm history <release> -n <ns>`, fix the cause,
then run `helmfile sync -l name=<release>` on the node, which does not diff.

**Tailscale identity collision.** A VM recreated without `tailscale logout`
joins as `jterrazz-infrastructure-2` and every private hostname breaks. Delete
the stale device in the Tailscale admin console, or rename the new one:

```bash
curl -H "Authorization: Bearer $TS_API_KEY" -X POST \
  "https://api.tailscale.com/api/v2/device/<id>/name" -d '{"name":"jterrazz-infrastructure"}'
```

A node back **logged out** after a reboot logs itself in through
`tailscale-autoauth.service`; if it did not, read that unit's journal first.

### DNS on the VM

OrbStack's DHCP hands out a resolver (`0.250.250.200`) that drops queries;
`roles/resolved` removes it (ADR-004). Check the file kubelet hands CoreDNS,
never `/etc/resolv.conf`, which always shows the 127.0.0.53 stub:

```bash
orb -m jterrazz-infrastructure -u root cat /run/systemd/resolve/resolv.conf   # 1.1.1.1 and 9.9.9.9 only
orb -m jterrazz-infrastructure -u root resolvectl status eth0                 # no "DNS Servers:" line
```

### Objects that need a gesture before they move

- **Use fully-qualified CRD names** with kubectl: `certificate.cert-manager.io`,
  `ingressroute.traefik.io`.
- **Delete by hand an object you remove from `kubernetes/cluster/`**: the deploy
  applies that tree without pruning. Delete it after the deploy that stops
  referencing it: a Middleware deleted while a route names it 404s the route.
- **Helm adopts an existing object** only with the annotations
  `meta.helm.sh/release-name` and `meta.helm.sh/release-namespace` and the label
  `app.kubernetes.io/managed-by=Helm`. A Deployment whose selector changes
  cannot be adopted at all: delete it right before the deploy, an outage for
  that workload. Never do this to `registry`: the deploy workflow logs in to it
  first, so recreate it with `make deploy-platform` from the Mac.

## DNS records converged by the platform deploy

`dns_records` in group_vars holds the three records nothing else creates in
the `jterrazz.com` zone, converged on every platform deploy (tag `dns-records`)
with the token cert-manager uses. Each name is held to exactly that one record,
so a record edited in the dashboard comes back.

| Name         | Type  | Content                                                      | Proxied |
| ------------ | ----- | ------------------------------------------------------------ | ------- |
| `*.internal` | CNAME | the node's tailnet name (`tailscale_dns_hostname`)           | no      |
| `*.staging`  | CNAME | the node's tailnet name                                      | no      |
| `analytics`  | CNAME | `<tunnel id>.cfargotunnel.com`, the tunnel token's `t` field | yes     |

The wildcards only make a name resolve to a `100.x` address; the route's
`private-access` allow-list is the enforcement, so a staging host on the public
tunnel is the mistake to look for. A wildcard matches one label:
`svc.internal`, never `a.b.internal`. Why each record exists is
[ADR-012](../decisions/012-private-hostnames-are-wildcard-zones.md).

Removing an entry does not delete its record: retire it from the list, then
from the dashboard. To hand `analytics` to the tunnel, remove its entry first,
then add the Public Hostname, which adopts the record.

```bash
dig +short grafana.internal.jterrazz.com    # the tailnet name
dig +short signews.staging.jterrazz.com     # the tailnet name
dig +short analytics.jterrazz.com           # Cloudflare addresses
```

## Repaving the cluster

```bash
# 0. Snapshot the fleet while the Deployments that name it still exist.
make -s redeploy-apps ARGS=--dry-run > ~/fleet-$(date +%F).txt

# 1. Stop the workloads: `systemctl stop k3s` leaves the containers writing.
orb -m jterrazz-infrastructure -u root /usr/local/bin/k3s-killall.sh

# 2. Back up the data directory (or `make backup`).
tar -czf ~/k8s-data-$(date +%F).tar.gz -C ~/.jterrazz-infrastructure data

# 3. Repave: the VM goes, the data directory on the Mac stays.
make destroy && make deploy

# 4. Rebuild every app onto the new cluster from the snapshot.
make redeploy-apps ARGS="--from $HOME/fleet-YYYY-MM-DD.txt"
```

Step 4 is required: the registry's blobs survive, no Helm release does. The
dispatches are staggered by 20s so the builds do not compete for the node's
memory. Each app's first deploy recreates its namespaces and volumes, labelled
with its repository.

## Backups

`make backup` writes an AES-256 archive of `~/.jterrazz-infrastructure/data` to
`~/.jterrazz-infrastructure/backups/` and decrypts it back to verify it.
`ARGS=--consistent` stops the workloads first, since a live copy captures the
databases mid-write, and restarts k3s after.

The passphrase is `BACKUP_ENCRYPTION_KEY` (Infisical `/jterrazz-infrastructure`,
env `prod`), fetched by the script itself through `.env`, and deliberately not a
deploy variable. It is permanent: rotating it orphans every archive it made,
and losing it loses them all.

Encryption, not `chmod`, because the pods write through virtiofs as uids 70,
101, 472, 999 and 1000, so the tree must stay traversable by "other"; what can
be protected is the copy that leaves it. Most of the tree is the registry, and
distribution's old store (`registry/docker`, ADR-014) is in every archive until
it is deleted.

## Restoring from backup

All persistent state is `/var/lib/k8s-data` on the node, a symlink to
`~/.jterrazz-infrastructure/data` on the Mac. To restore, stop the consumer,
replace its directory, and start it again.

```text
data/
├── victoria-metrics/ · victoria-logs/ · victoria-traces/
├── registry/            zot/ (live) and docker/ (distribution's rollback)
├── openpanel/           postgres/ · clickhouse/ · redis/
└── <app>-<env>/         one per app volume, from the app chart
```

Grafana's volume lives in the VM (`/var/lib/grafana-node-local`), and a repave
resets it. Every directory here survives a repave, so deleting one is the
deletion the `Retain` policy protects against. Database-consistent dumps are
in [the OpenPanel README](../../kubernetes/services/openpanel/README.md#backup-and-restore).

## Rotating credentials

| What                      | How                                                                                                   |
| ------------------------- | ------------------------------------------------------------------------------------------------------ |
| Any Infisical-held secret | Change it in Infisical. The operator resyncs every 5 minutes (its default; no CR sets `syncConfig`), and `kubectl delete pod -n platform-secrets -l control-plane=controller-manager` forces it. A consumer reading it as env still needs a rollout restart, and a deploy secret a `make deploy-platform`. |
| `CLOUDFLARE_TUNNEL_TOKEN` | A new connector token in Zero Trust, stored at `/jterrazz-infrastructure`, a resync, then `kubectl rollout restart deploy/cloudflared -n platform-networking`. |
| The registry accounts     | Two accounts overlapping, never a swap: [below](#rotating-the-registry-password).                     |
| CI deploy SSH key         | `ssh-keygen -t ed25519`, the public half into `security_ci_deploy_pubkey`, `gh secret set CI_DEPLOY_SSH_PRIVATE -R jterrazz/jterrazz-infrastructure`, then `make deploy`. |

### A deleted managed Secret does not come back

The operator caches the Infisical ETag per `InfisicalSecret` and writes nothing
while the value is unchanged (`Secrets unchanged (server ETag match), skipping
reconciliation`), and with `creationPolicy: Orphan` it never checks that the
Secret it created still exists. A Secret deleted by hand stays gone while the
CR reports `Ready`. Change the value in Infisical, or recreate the CR:

```bash
kubectl get infisicalsecret <name> -n <ns> -o yaml > /tmp/cr.yaml   # keeps the Helm annotations
kubectl delete -f /tmp/cr.yaml && kubectl apply -f /tmp/cr.yaml && rm -f /tmp/cr.yaml
```

### Rotating the registry password

The push account authenticates CI's pushes and the chart publish; the
read-only account every kubelet pull. A single swap breaks whichever side has
not caught up, and one of those is the pipeline that would fix it. So the
accounts overlap: add the new one, move everything onto it, drop the old one.
The push account's name alternates between `deploy` and `deploy-next`, the two
names Zot grants write to; any other name only reads. Never print a value: read
it from Infisical and pass it through the environment.

1. **Add the new account to the server by hand.** The live names:

   ```bash
   kubectl get secret registry-auth -n platform-registry \
     -o jsonpath='{.data.htpasswd}' | base64 -d | cut -d: -f1
   ```

   Append the new name's line, the password on stdin, never as an argument:

   ```bash
   kubectl get secret registry-auth -n platform-registry \
     -o jsonpath='{.data.htpasswd}' | base64 -d > /tmp/htpasswd
   printf '%s' "$NEW_REGISTRY_PASSWORD" | htpasswd -niB "$NEW_REGISTRY_USERNAME" >> /tmp/htpasswd
   kubectl create secret generic registry-auth -n platform-registry \
     --from-file=htpasswd=/tmp/htpasswd --dry-run=client -o yaml | kubectl apply -f -
   rm -f /tmp/htpasswd
   kubectl rollout restart deploy/registry -n platform-registry   # Zot reads it at start
   ```

2. **Store the new pair in `jterrazz-ci`**, generated without whitespace: a
   netrc line cannot carry one.

3. **Resync** with `kubectl delete pod -n platform-secrets -l
   control-plane=controller-manager`; no app redeploy is needed.

4. **Verify every namespace is fresh**: identical versions mean one Infisical
   revision, and every CR must be `Ready`. A `Ready` CR whose Secret is absent
   is [the ETag trap](#a-deleted-managed-secret-does-not-come-back): recreate it.

   ```bash
   kubectl get secret registry-credentials -A \
     -o custom-columns='NS:.metadata.namespace,VERSION:.metadata.annotations.secrets\.infisical\.com/version'
   kubectl get infisicalsecret -A
   ```

5. **Drop the old account**: a platform deploy regenerates `registry-auth` from
   Infisical alone. Restart the registry, then list the names again.

   ```bash
   gh workflow run deploy-platform.yaml -R jterrazz/jterrazz-infrastructure   # or make deploy-platform
   kubectl rollout restart deploy/registry -n platform-registry
   ```

The workflow logs in to the registry before anything else, so it is safe while
both accounts are live, and only then.

## Registry garbage collection

Zot collects on its own: every 6h it removes manifests untagged for 24h, with
their referrers, and the blobs nothing references
([ADR-014](../decisions/014-the-registry-collects-its-own-garbage.md)). Since
apps deploy by digest, a digest lives 24h after its tag moves: a pod of an
environment a failed deploy left behind may later fail to pull, and
redeploying the app fixes it. The node prunes its own image cache weekly
(`image-prune.timer`), which frees the node's disk, not the registry's.

```bash
regctl repo ls registry.internal.jterrazz.com
regctl tag ls registry.internal.jterrazz.com/<app>
```

## Add a platform service

A platform service is a directory under `kubernetes/services/` holding one
values file per release, named after the chart that renders it
([Architecture](../concepts/architecture.md#four-layers)). Prefer a maintained
upstream chart, else the app chart; a raw manifest is the last resort.

1. **Namespace**: add it to `kubernetes/cluster/namespaces.yaml`, and its
   baseline to `kubernetes/cluster/network-policies/<ns>.yaml`: default-deny,
   same-namespace, DNS egress, nothing naming a workload.
2. **Values**: `service.yaml` for the route, certificate, volumes, credentials
   and policy, plus `values.yaml` for an upstream chart or one app-chart file
   per workload. `registry/` is the single-workload example, `openpanel/` the
   multi-workload one.
3. **Release**: one block in `kubernetes/helmfile.yaml.gotmpl` with its pinned
   `version:`; the `<svc>-platform` sibling inherits the `platform-service`
   template. That block is the whole declaration.
4. **Route**: `access` defaults to `private`; add the hostname to
   `private_hostnames`. A public zone is
   [three steps](develop.md#dns-has-exactly-three-owners). Add `smoke:` only
   when `GET /` does not answer 200.
5. **Network**: a `network:` block in `service.yaml` for an upstream chart, with
   the pod labels read off the running pods; `spec.network` for an app-chart
   workload, where a datastore is `isolated: true`. Ports are pod ports.
6. **Secrets**: `secrets: { path, secretName }` in `service.yaml` for a name a
   chart reads literally, `spec.secrets` for env vars.
7. `make check`, then merge: `deploy-platform.yaml` deploys it.

## Add an app

Apps deploy themselves; this repo owns only their chart
([the deploy contract](../reference/deploy-contract.md)).

1. Add `.infrastructure/application.yaml` to the app repo, with `tag:` on every
   environment ([the schema](../../kubernetes/charts/app/README.md)).
2. Expose `make build`, `make lint` and `make test`, and call the shared
   workflow in `jterrazz/jterrazz-actions` from a job granting
   `permissions: { contents: read, id-token: write }`.
3. Add a tailnet-only hostname to `private_hostnames`; nothing else changes
   here.

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
mv ~/.jterrazz-infrastructure/data/openpanel/postgres/pgdata \
   ~/.jterrazz-infrastructure/data/openpanel/postgres/pgdata-pg<old>-$(date +%F)
mkdir -p ~/.jterrazz-infrastructure/data/openpanel/postgres/pgdata

# 4. Bump the image in kubernetes/services/openpanel/op-postgres.yaml and deploy it.
kubectl rollout status -n platform-analytics deploy/op-postgres --timeout=180s

# 5. Restore, then bring the writers back; op-api migrates on boot.
kubectl exec -i -n platform-analytics deploy/op-postgres -- \
  psql -X -U openpanel -d postgres < openpanel-all-YYYY-MM-DD.sql
kubectl scale -n platform-analytics --replicas=1 deploy/op-api deploy/op-worker deploy/op-dashboard
```

Verify that `\dt` lists the tables, the dashboard loads its projects and a test
event reaches ClickHouse. To roll back, scale everything to 0, move the old
directory back to `pgdata`, restore the old image and scale up.
