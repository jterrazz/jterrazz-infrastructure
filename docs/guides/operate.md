# Operating

The 2am document: where the secrets are, what to run when something is down,
and how to rebuild from nothing. Design lives in
[Architecture](../concepts/architecture.md); the rules a change to the tree
follows are [Develop](develop.md).

## Reaching the cluster

```bash
orb -m jterrazz-infrastructure -u root kubectl get pod -A   # most reliable
ssh root@jterrazz-infrastructure@orb                        # OrbStack SSH proxy
export KUBECONFIG=./kubeconfig.yaml                         # make kubeconfig
```

`kubeconfig.yaml` is fetched by the k3s role at the end of every `make deploy`
and rewritten to the node's MagicDNS name, so it only works from a tailnet
client. `make kubeconfig` regenerates it (fetch + rewrite) without a deploy,
which is what `make diff` tells you to run when the file is missing or stale. The `orb` SSH alias resolves only with `~/.orbstack/ssh/config` in play
(which is why `inventories/laptop.yml` passes it explicitly); `orb -m ...` needs
nothing but OrbStack.

## Secrets inventory

### Infisical: project `jterrazz`, environment `prod`

Fetched at deploy time by `ansible/roles/secrets`, the first role of both
playbooks, from the list `infisical_secrets` in group_vars, on the controller
(the laptop or the CI runner). Each path is fetched **explicitly**, never
recursively, so short key names can repeat across folders. A missing key aborts
the run before anything deploys.

| Path                               | Key                             | Ansible var                     | Scope         |
| ---------------------------------- | ------------------------------- | ------------------------------- | ------------- |
| `/jterrazz-infrastructure`         | `CLOUDFLARE_API_TOKEN`          | `cloudflare_api_token`          | site+platform |
|                                    | `CLOUDFLARE_TUNNEL_TOKEN`       | `cloudflare_tunnel_token`       | site+platform |
|                                    | `DOCKER_REGISTRY_USERNAME`      | `registry_username`             | site+platform |
|                                    | `DOCKER_REGISTRY_PASSWORD`      | `registry_password`             | site+platform |
|                                    | `TAILSCALE_OAUTH_CLIENT_ID`     | `tailscale_oauth_client_id`     | site only     |
|                                    | `TAILSCALE_OAUTH_CLIENT_SECRET` | `tailscale_oauth_client_secret` | site only     |
| `/jterrazz-infrastructure/grafana` | `ADMIN_PASSWORD`                | `grafana_admin_password`        | site+platform |

`BACKUP_ENCRYPTION_KEY` also lives at `/jterrazz-infrastructure` but is **not**
in the table above: no deploy reads it, only `make backup` does, and it is
fetched directly rather than through the extra-vars file. See
[Backups](#backups).

The `platform` scope drops the Tailscale OAuth pair: `platform.yml` only reads
Tailscale *facts* off an already-joined node. `infisical_client_id` /
`infisical_client_secret` are the one exception to all of this: they come from
`.env` (or the GitHub secrets in CI) and are written into the extra-vars file,
because the in-cluster operator needs them and they cannot come from Infisical
itself.

Synced **into the cluster** by the operator from `InfisicalSecret` CRs, which
are rendered by the release that needs them: a platform service's `secrets:`
block (`services/<x>/service.yaml`) or an app-chart release's `spec.secrets`.
The deploy script never sees these:

| Path                                       | Becomes Secret                | Keys                                                            |
| ------------------------------------------ | ----------------------------- | --------------------------------------------------------------- |
| `/jterrazz-infrastructure`                 | `cloudflared-secrets`         | `CLOUDFLARE_TUNNEL_TOKEN`                                        |
| `/jterrazz-infrastructure/openpanel`       | `op-{api,worker,dashboard,postgres}-secrets` | `POSTGRES_PASSWORD`, `COOKIE_SECRET`, `DATABASE_URL`, `DATABASE_URL_DIRECT`, one Secret per release that needs them, each projecting only the keys it names |
| `/jterrazz-infrastructure/otel-collector`  | `otel-collector-secrets`      | `LANGFUSE_BASIC_AUTH`                                            |
| `/jterrazz-infrastructure/grafana`         | `grafana-alerting`            | `contact-point-slack.yaml`, rendered by the operator from `SLACK_WEBHOOK_URL`, optional: absent, the file provisions nothing (`kubernetes/services/grafana/service.yaml`) |
| `/jterrazz-actions`                        | `registry-credentials`        | `.dockerconfigjson`: the pull credential, assembled by the operator's own template from `DOCKER_REGISTRY_USERNAME` + `DOCKER_REGISTRY_PASSWORD`. One per app namespace whose image is on our registry; `charts/app` renders the CR beside the app's own |
| `/<app>/...`                               | `<app>-secrets`               | whatever the app's `spec.secrets.env` lists                      |

There is no `/jterrazz-infrastructure/registry` folder: the registry's account
is `DOCKER_REGISTRY_USERNAME` + `DOCKER_REGISTRY_PASSWORD` at the root path,
turned into the one `<user>:<bcrypt>` line of the `registry-auth` Secret by
`roles/platform/tasks/bootstrap.yml`. **Both halves are read, neither is
hardcoded**, and that is what lets a rotation move the fleet onto a second
account and back.

### `/jterrazz-actions`: app CI

The default `infisical-secret-path` of `jterrazz-actions/actions/infra-connect`,
consumed by every app repo's pipeline: `DOCKER_REGISTRY_USERNAME`,
`DOCKER_REGISTRY_PASSWORD`, `TAILSCALE_OAUTH_CLIENT_ID`,
`TAILSCALE_OAUTH_CLIENT_SECRET`. `KUBECONFIG_BASE64` is still stored there but
no longer read by anything: since 2026-10-24 an app deploy authenticates to the
cluster with its own GitHub OIDC token (see
[Deploy contract](../reference/deploy-contract.md#how-a-deploy-authenticates)).
Delete it from Infisical; it is an admin client certificate.

The **cluster** reads the registry pair from here too (the table above): the app
chart renders an `InfisicalSecret` per app namespace and the operator writes the
`registry-credentials` dockerconfigjson from it, so CI's `docker login` and the
kubelet's pull authenticate against ONE stored copy. Nothing carries that
password in a Helm value any more, which is what makes the rotation below a
runbook rather than a fleet redeploy.

A repave needs nothing in Infisical any more for app deploys: the CA a job
trusts comes from k3s' `/cacerts` at deploy time, and its identity from GitHub.
The namespaces and volumes come back on each app's first deploy, labelled with
the repository that owns them.

### GitHub secrets (repo `jterrazz/jterrazz-infrastructure`)

| Secret                    | Used by                                        |
| ------------------------- | ---------------------------------------------- |
| `INFISICAL_CLIENT_ID`     | `deploy-platform.yaml`, `smoke.yaml`           |
| `INFISICAL_CLIENT_SECRET` | same                                           |
| `CI_DEPLOY_SSH_PRIVATE`   | `deploy-platform.yaml`, to SSH into the VM     |

The public half of that keypair is committed as `security_ci_deploy_pubkey` in
`ansible/roles/security/defaults/main.yml`; the `security` role installs it in
root's `authorized_keys`.

### GitHub secrets (every app repo)

`INFISICAL_CLIENT_ID` / `INFISICAL_CLIENT_SECRET` are the same machine identity as
above, which `infra-connect` exchanges for `/jterrazz-actions`. One identity is
shared by CI, the cluster's Infisical operator and the local `.env`; rotating it
means updating every deploying repo. A repo that lacks them fails the *Release*
job at `Missing universal auth credentials`, after a green validate, so a first
deploy looks like it almost worked.

```bash
set -a; . ./.env; set +a
gh secret set INFISICAL_CLIENT_ID     -R jterrazz/<repo> --body "$INFISICAL_CLIENT_ID"
gh secret set INFISICAL_CLIENT_SECRET -R jterrazz/<repo> --body "$INFISICAL_CLIENT_SECRET"
```

### Local `.env` (gitignored, repo root)

```text
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
| kube-system NetworkPolicy | `cluster/network-policies/kube-system.yaml` | DNS from a fresh pod, `kubectl top nodes`, a tailnet curl (see below), and a fresh unlabelled kube-system pod timing out on Traefik's pod IP `:8443` |

### The two things that will bite

**OrbStack machines are not isolated from each other by default.** Every one
mounts every other's rootfs at `/mnt/machines/<name>/` and reads it **as
root**, so file permissions are irrelevant there, `0600` included, and the
mode on `kubeconfig.yaml` is defence in depth rather than a fix. A plain
`orb create` machine can read this cluster's data directory and its
kubeconfig. Create dev machines with `--isolated` (no `/mnt/machines` at all)
and add `--isolate-network` for the host. Note that `--isolate-network` does
NOT block peer machines despite the docs, which is why the nftables guard
exists. `--isolated` is impossible for a k3s node: the unprivileged userns
refuses kubelet's `noswap` tmpfs and k3s restart-loops without ever serving.

**Test the tailnet path, not just the public one.** cloudflared dials
Traefik's ClusterIP directly, so a kube-system policy can break every tailnet
client while smoke stays 11/11 and the cluster looks green. CI is a tailnet
client (it pulls from the registry), so this surfaces as a failed deploy:

```bash
curl -sk -H "Host: registry.internal.jterrazz.com" https://<tailnet-ip>/v2/   # 401
curl -sk -H "Host: grafana.internal.jterrazz.com" https://<tailnet-ip>/api/health  # 200
```

**Run those from a peer, not from the node.** The node reaching its own
tailnet address takes the OUTPUT path and never crosses `tailscale0`, so it
stays green while every real peer is dropped. Seen 2026-09-19: tailscaled
1.102 started masquerading forwarded tailnet traffic, klipper-lb then saw
`10.42.0.1` instead of a `100.64.0.0/10` source and its
`loadBalancerSourceRanges` filter dropped every SYN: the curls above passed
on the node, CI failed at `docker login`, the laptop got nothing. The tell is
`tcpdump -i any 'tcp port 443 and net 100.64.0.0/10'` on the node showing
SYNs on `tailscale0` and nothing leaving `cni0` with a tailnet source. The
fix is `--snat-subnet-routes=false` in the tailscale role's one copy of
`tailscale up`; `iptables -t nat -L ts-postrouting` must list no MASQUERADE.

## Troubleshooting

```bash
kubectl get pod -A | grep -v Running ; helm list -A ; kubectl get certificate -A

# What would the next platform deploy change? (read-only, needs the tailnet)
make diff

# What does smoke think it should be probing, and what did it fall back on?
./scripts/smoke.sh --public --private --list
./scripts/trigger-app-deploys.sh --dry-run     # which repos would be rebuilt
./scripts/helmfile.sh diff -l name=grafana     # one release

# cert-manager after any k3s churn (webhook + cainjector lose the API, the
# single most common cause of a stuck Certificate; restart all three together)
kubectl rollout restart -n platform-networking \
  deploy/cert-manager deploy/cert-manager-webhook deploy/cert-manager-cainjector

# Cloudflare tunnel: connected? serving?
kubectl logs -n platform-networking deploy/cloudflared --tail=30 | grep -E 'Registered|edge'
POD_IP=$(kubectl get pod -n platform-networking -l app.kubernetes.io/name=cloudflared \
  -o jsonpath='{.items[0].status.podIP}')
curl -s "http://$POD_IP:2000/metrics" | grep '^cloudflared_tunnel_total_requests '

# Every pod's stdout is in VictoriaLogs, shipped by the otel-collector's
# filelog receiver (it tails /var/log/pods off a hostPath; there is no separate
# log agent any more). Query in Grafana's "VictoriaLogs" datasource; the
# language is LogsQL, NOT LogQL:
#   {k8s.namespace.name="platform-analytics"}
#   {app="op-api"} error
#   {app="op-api"} | stats by (k8s.container.name) count()
# The four stream fields are k8s.namespace.name / k8s.pod.name /
# k8s.container.name / app, pinned by the VL-Stream-Fields header on the
# collector's exporter. Everything else (node, deployment, pod uid, file path)
# is a regular field: filter on it, just do not expect it to narrow the scan.

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
not, check that unit's journal first. The failure chain runs from a registry NXDOMAIN to an
ImagePullBackOff on every app pod, then a Cloudflare 503 on every public hostname.

### DNS on the VM

**OrbStack DHCP hands out a bogus resolver** (`0.250.250.200`) that silently
drops queries, and it takes two fixes, not one. `upstream.conf` sets the global
resolver; `UseDNS=false` removes the per-link one. The `resolved` role writes
both: `/etc/systemd/resolved.conf.d/upstream.conf` (`DNS=1.1.1.1 9.9.9.9`) and
a systemd-networkd drop-in at
`/etc/systemd/network/eth0.network.d/10-no-dhcp-dns.conf`.

Do not diagnose this by looking for a missing `upstream.conf`. That was the old
note here and it is wrong: `upstream.conf` was present the whole time the bogus
resolver was still in use, because a global `DNS=` cannot displace a
DHCP-supplied link server. The real check is the uplink file, which is the one
kubelet pins and therefore the one CoreDNS forwards to:

```bash
orb -m jterrazz-infrastructure -u root cat /run/systemd/resolve/resolv.conf
# want exactly: nameserver 1.1.1.1 / nameserver 9.9.9.9, no third line
orb -m jterrazz-infrastructure -u root resolvectl status eth0
# want: "DNS Servers:" absent under Link N (eth0)
```

`/etc/resolv.conf` is useless for this: it is symlinked to `stub-resolv.conf`
and always shows a single `nameserver 127.0.0.53`. `networkctl status eth0 |
grep 'Network File'` names the file the drop-in must sit beside; the role
derives it rather than hardcoding `eth0.network`. Which file kubelet is pinned
to, and why, is [Develop](develop.md#the-vm-is-built-one-way).

### Objects that need a gesture before they move

- **Use fully-qualified CRD names** with kubectl: `certificate.cert-manager.io`,
  `ingressroute.traefik.io`.
- **Delete by hand an object you remove from `kubernetes/cluster/`.** The deploy
  runs `kubectl apply -R` on that tree without pruning, so the live object
  survives its manifest. Run the delete after the deploy that stops
  referencing it, never before: a Middleware deleted while a route still names
  it turns that route into a 404. The fully-qualified form is
  `kubectl -n <ns> delete middleware.traefik.io <name>` or
  `kubectl -n <ns> delete networkpolicy <name>`.
- **Remove finalizers before deleting an `Application` object** when tearing
  down a controller that manages resources through it, or the cascade takes the
  managed resources with it. Learned dismantling ArgoCD, which is long gone from
  this tree; the lesson is kept because nothing here can teach it again.

### `make deploy-platform` from the Mac died at fact-gathering

**Resolved by 2026-10-24.** From 2026-09-06, `ansible.legacy.setup` over the
`orb` connection returned an empty `module_stdout` (`Module result
deserialization failed: No start of json char found`). On 2026-10-24 the same
setup module answered from the Mac and `site.yml --tags k3s,security` ran
green through it, with no change in this repo; the likeliest fix is the
ansible-core / OrbStack versions moving underneath. If it returns, the
workflow is still the way in for the platform layer.

## DNS records (converged by the platform deploy)

Three records in the `jterrazz.com` zone (zone id
`ca5eefcd2d8b1d8895fc255f26141d46`) have no other owner, so the platform deploy
owns them: `dns_records` in `ansible/inventories/group_vars/all.yml`, applied
by `roles/platform/tasks/dns-records.yml` on every run (tag `dns-records`).
Each name is held to exactly that one record (`solo`), so a record deleted or
edited in the dashboard comes back on the next deploy, and neither target is a
literal: both follow the VM and the tunnel.

| Name         | Type  | Content (derived from)                                         | Proxied |
| ------------ | ----- | -------------------------------------------------------------- | ------- |
| `*.internal` | CNAME | the node's tailnet name (`tailscale_dns_hostname`)             | no      |
| `*.staging`  | CNAME | the node's tailnet name (`tailscale_dns_hostname`)             | no      |
| `analytics`  | CNAME | `<tunnel id>.cfargotunnel.com`, the tunnel token's `t` field   | yes     |

The credential is `cloudflare_api_token` (Infisical,
`/jterrazz-infrastructure/CLOUDFLARE_API_TOKEN`), the same DNS:Edit token
cert-manager solves DNS-01 with; no second credential exists for this.

### The private wildcards

`*.internal` covers every private surface at once, and `*.staging` every
staging environment (`<app>.staging.jterrazz.com`), which is why adding a
private service needs no DNS work, only a line in `private_hostnames`
(group_vars) and `public: false` on the route. DNS-only on purpose: proxied
wildcards need a paid plan, tailnet traffic must skip the Cloudflare edge
anyway, and an unproxied record is why a two-label name gets valid HTTPS: the
certificate is cert-manager's (one per host, DNS-01), not Cloudflare's Universal
SSL, which stops at `*.jterrazz.com`. One label deep, because a DNS wildcard
matches one label: `svc.internal`, not `a.b.internal`.

The record only makes the name resolve to a `100.x` address; the `private-access`
ipAllowList on the route is the enforcement. A staging host on the public
tunnel, or a staging route with `public: true`, is the mistake to look for.

### `analytics`

`analytics` is the one public hostname whose record is NOT created by the
tunnel's Public Hostname feature (every other one is; see
[cloudflared](../../kubernetes/services/cloudflared/README.md)). Its *route* is in
Zero Trust, its *record* is this one. Proxied is mandatory: `cfargotunnel.com`
only resolves at the edge. To hand it to the tunnel, remove its `dns_records`
entry first, then add `analytics.jterrazz.com` as a Public Hostname in Zero
Trust (it adopts the record), and confirm `dig` still answers.

### Retiring a record, verifying them all

A record is never removed by deleting its entry: the task only ensures what is
listed. Retiring one is the entry out of the list, then the record out of the
dashboard.

Verify: `dig +short grafana.internal.jterrazz.com` and
`dig +short signews.staging.jterrazz.com` answer the tailnet name,
`dig +short analytics.jterrazz.com` answers proxied Cloudflare addresses.

## Repaving the cluster

The sequence as executed on 2026-07-25 (Debian 13 migration):

```bash
# 0. Snapshot the fleet WHILE IT STILL EXISTS. `make redeploy-apps` discovers
#    the repos from the live Deployments' app.jterrazz.com/repository
#    annotation, and a rebuilt cluster has no Deployments to read.
./scripts/trigger-app-deploys.sh --dry-run > ~/fleet-$(date +%F).txt

# 1. Stop the workloads. `systemctl stop k3s` does NOT stop running
#    containers: they keep writing to /var/lib/k8s-data mid-backup.
orb -m jterrazz-infrastructure -u root /usr/local/bin/k3s-killall.sh

# 2. Back up the data directory (it lives on the Mac, so tar it there).
tar -czf ~/k8s-data-$(date +%F).tar.gz -C ~/.jterrazz-infrastructure data

# 3. Repave. `make destroy` deletes the VM only; the Mac-side data dir stays.
make destroy
make deploy

# 4. Rebuild + redeploy every app onto the new (empty) registry, from the
#    snapshot taken in step 0 (there is nothing left in the cluster to
#    discover). `make redeploy-apps` is the discovery form, for every other day.
./scripts/trigger-app-deploys.sh --from ~/fleet-YYYY-MM-DD.txt
```

Step 5 is required, not optional: registry blobs are hostPath and do survive,
but no app's Helm release does: the cluster is new. The script staggers the
dispatches by 20s so simultaneous Docker builds don't compete for RAM
on one node. Post-repave verification items (uid pins, remaining egress narrowing)
live in the pinned GitHub issue. Every PLATFORM namespace in
`kubernetes/cluster/namespaces.yaml` has a baseline NetworkPolicy file; an app
namespace has only what its own chart renders. The OpenPanel
`API_URL_SSR` rationale lives in `kubernetes/services/openpanel/config.yaml`;
do not retell it here.

## Backups

`make backup` writes an AES-256 archive of `~/.jterrazz-infrastructure/data` to
`~/.jterrazz-infrastructure/backups/` and verifies it by decrypting it back:
an archive nobody has opened is a guess, not a backup.

Most of that tree is the registry's blobs. `registry-gc` (below) keeps them at
the size of the live tags: 1.0G after the first collection on 2026-09-23,
against 14G before it, which was also the size of the backup taken on
2026-09-19. See [Registry garbage collection](#registry-garbage-collection).

`make backup ARGS=--consistent` runs `k3s-killall.sh` first. Without it the
databases are captured mid-write: `systemctl stop k3s` does NOT stop the
containers, which is how two earlier backups came out torn.

The passphrase is `BACKUP_ENCRYPTION_KEY` in Infisical at
`/jterrazz-infrastructure` (env `prod`). Nothing local is needed: with
`INFISICAL_CLIENT_ID` / `INFISICAL_CLIENT_SECRET` in `.env`, `make backup`
fetches it itself. It is deliberately NOT in `infisical_secrets`: those become
variables of every deploy, and this key has no business there.
It is **permanent**: rotating it does not re-encrypt existing archives, it
orphans them, and losing it loses every archive it ever produced. That is the
whole point: a copy on Time Machine, an external disk or a future machine is
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

```text
data/
├── grafana/                    grafana.db (users, API keys, alert state)
├── victoria-metrics/           metrics (30d)
├── victoria-logs/              logs (90d)
├── victoria-traces/            traces (720h)
├── registry/                   Docker registry blobs
├── openpanel/                  postgres/ + clickhouse/ + redis/
└── signews-api-{prod,next,staging}/, gateway-intelligence-prod/, os-prod/
                                per-app volumes from the app chart
```

Every directory here is claimed by a live PV; the tree carried orphans for
months and no longer does. `prometheus/`, `loki/` and `tempo/` (the
pre-migration metrics and logs), `n8n/` and `portainer/` were deleted once the
Victoria stores had a window worth trusting, and `librechat/` went with the
service on 2026-09-21. `grafana/` was deleted the same day for a different
reason: Grafana's volume moved to the node-local `/var/lib/grafana-node-local`
(`services/grafana/service.yaml`), so the copy here had been stale since
2026-07-26. Note the asymmetry with a repave: these directories are what
survives one, so deleting a directory here is the deletion the `Retain` policy
was protecting against.

For consistent database dumps rather than a file copy, see the backup section
of [openpanel](../../kubernetes/services/openpanel/README.md#backup--restore).

## Rotating credentials

| What                              | How                                                                                                   |
| --------------------------------- | ------------------------------------------------------------------------------------------------------ |
| Any Infisical-held secret         | Change it in the Infisical UI, then `make deploy-platform`. No `InfisicalSecret` in this repo sets `spec.syncConfig`, so every one resyncs on the **operator's own default interval** (5 minutes at operator 0.11.9); `kubectl delete pod -n platform-secrets -l control-plane=controller-manager` forces it now. Note the resync only updates the **Secret**; a consumer that reads it as `env` still needs a rollout restart. |
| `CLOUDFLARE_TUNNEL_TOKEN`         | Create a new connector token in Zero Trust, store it at `/jterrazz-infrastructure`, wait for the resync (or force it as above), then `kubectl rollout restart deploy/cloudflared -n platform-networking` (it reads `TUNNEL_TOKEN` once, at startup). |
| `DOCKER_REGISTRY_PASSWORD`        | Two accounts overlapping, never a single swap: [Rotating the registry password](#rotating-the-registry-password). |
| CI deploy SSH key                 | `ssh-keygen -t ed25519`, paste the pubkey into `security_ci_deploy_pubkey`, `gh secret set CI_DEPLOY_SSH_PRIVATE -R jterrazz/jterrazz-infrastructure`, then `make deploy` to roll it onto the VM. |
| The three owned DNS records       | Nothing to rotate in the records: they follow `cloudflare_api_token`, the token cert-manager uses. A lost record comes back on the next platform deploy: [DNS records](#dns-records-converged-by-the-platform-deploy). |

### A deleted managed Secret does not come back

The operator reconciles on the Infisical VALUE, not on the Kubernetes object.
It caches the server's ETag per `InfisicalSecret`, and while the value is
unchanged it writes nothing:

```text
Secrets unchanged (server ETag match), skipping reconciliation
```

Every CR here leaves `creationPolicy` at its default `Orphan`, which also means
the operator never re-checks that the Secret it once created still exists. So a
Secret deleted by hand (or by a `helm upgrade` that used to own a Secret of the
same name) stays gone: the CR reports `Ready`, the resync interval passes, and
restarting the operator changes nothing, because the ETag is the state.

Two repairs, and waiting is not one of them: change the value in Infisical, or
delete and recreate the CR, which drops the cached ETag.

```bash
kubectl get infisicalsecret <name> -n <ns> -o yaml > /tmp/cr.yaml   # keeps the Helm ownership annotations
kubectl delete -f /tmp/cr.yaml && kubectl apply -f /tmp/cr.yaml
rm -f /tmp/cr.yaml
```

### Rotating the registry password

One credential authenticates **every** direction at once: CI's `docker login`
and `helm registry login`, containerd's pull through the synced
`registry-credentials`, and the chart publisher. A single swap therefore breaks
whichever side has not caught up yet, and one of those sides is the pipeline
that would fix it. So the two accounts overlap: add the new one, move
everything onto it, remove the old one.

An account is a NAME and a password, and both move. The name **alternates**:
from `deploy` to `deploy-next` this time, from `deploy-next` to `deploy` the next. Nothing
hardcodes it: `bootstrap.yml` hashes `DOCKER_REGISTRY_USERNAME` from
`/jterrazz-infrastructure` into the htpasswd line, the same key CI and the
kubelet authenticate with from `/jterrazz-actions`, which is what makes the
overlap below work as written. Before this was true, step 5 regenerated a line
for `deploy` while everything else spoke as `deploy-next`, and the fleet went
ImagePullBackOff (2026-09-06).

Nothing below ever prints a value: read them from the Infisical UI and pass
them through the environment.

1. **Add a second account to the registry.** `bootstrap.yml` generates exactly
   one htpasswd line, so the second one is by hand, and it lasts only until the
   next `make deploy` / `make deploy-platform` regenerates the Secret, which is
   step 5. Which name is live is the server's own answer, and reading it prints
   no hash:

   ```bash
   kubectl get secret registry-auth -n platform-registry \
     -o jsonpath='{.data.htpasswd}' | base64 -d | cut -d: -f1
   ```

   The new name is the other one. Append its line to what is already there:

   ```bash
   kubectl get secret registry-auth -n platform-registry \
     -o jsonpath='{.data.htpasswd}' | base64 -d > /tmp/htpasswd
   # stdin, never `htpasswd -nbB <user> <password>`: an argument is in
   # `ps` for as long as the command runs, and in your shell history forever.
   printf '%s' "$NEW_REGISTRY_PASSWORD" \
     | htpasswd -niB "$NEW_REGISTRY_USERNAME" >> /tmp/htpasswd
   kubectl create secret generic registry-auth -n platform-registry \
     --from-file=htpasswd=/tmp/htpasswd --dry-run=client -o yaml | kubectl apply -f -
   rm -f /tmp/htpasswd
   kubectl rollout restart deploy/registry -n platform-registry   # the file is a mount
   ```

2. **Store the new pair at BOTH paths** in the Infisical UI: four values, one
   account. `/jterrazz-infrastructure` holds `DOCKER_REGISTRY_USERNAME` +
   `DOCKER_REGISTRY_PASSWORD`, which Ansible reads as `registry_username` /
   `registry_password` and hashes into the server's htpasswd;
   `/jterrazz-actions` holds the same two keys, which CI and the cluster
   authenticate with. They are one hand-synced pair, name included; a value
   moved at one path only is a half-rotation that passes every check here.
   Generate the password **without whitespace**:
   `jterrazz-actions/actions/docker-cleanup` authenticates curl from a netrc
   file it writes one line at a time, and that format cannot carry a space.

3. **Pull the new values into the cluster**, or wait out the resync:

   ```bash
   kubectl delete pod -n platform-secrets -l control-plane=controller-manager
   ```

   No app redeploy is needed; the pull secret is not a chart value.

4. **Verify every namespace is fresh** before removing anything. The operator
   stamps an etag on what it wrote, so identical values across namespaces mean
   they came from the same Infisical revision, with no value on screen:

   ```bash
   kubectl get secret registry-credentials -A \
     -o custom-columns='NS:.metadata.namespace,VERSION:.metadata.annotations.secrets\.infisical\.com/version'
   kubectl get infisicalsecret -A     # every CR Ready
   ```

   A namespace missing from that list is an app that has not deployed since app
   chart 2.12.0: deploy it (its CR is what creates the Secret) before step 5.

   A namespace whose CR is `Ready` while the Secret is absent is the other
   case, and no amount of waiting fixes it: the operator is holding an ETag
   for a value it has already synced, and never looks at the missing object
   ([above](#a-deleted-managed-secret-does-not-come-back)). Recreate that CR
   before continuing.

5. **Drop the old account.** With both new halves already at
   `/jterrazz-infrastructure`, the platform play regenerates a single-line
   `registry-auth` for the new account, the hand-added line and the old account gone
   in one pass:

   ```bash
   gh workflow run deploy-platform.yaml -R jterrazz/jterrazz-infrastructure
   # or, as a fallback: make deploy-platform   # from the Mac, see below
   kubectl rollout restart deploy/registry -n platform-registry
   ```

   Then confirm the server now answers to the new name alone:

   ```bash
   kubectl get secret registry-auth -n platform-registry \
     -o jsonpath='{.data.htpasswd}' | base64 -d | cut -d: -f1   # exactly one, the new one
   ```

**Step 5 is `deploy-platform.yaml`; the Mac is the fallback.** That workflow's
own `infra-connect` logs in to the registry before it can do anything, which is
the whole reason the rotation overlaps: while both accounts are live on the
server, the run authenticates with either half and is safe; that is how the
2026-09-06 rotation was finished. What is unsafe is starting it *outside* the
overlap, before step 1 or after the old line is gone but a path still holds the
old value: it then dies at its first step, the same loop as taking the
`registry` release down. So the order matters, not the machine.

`make deploy-platform` from the Mac needs only `.env` and `orb`, and it is the
way in when the workflow cannot run at all, but on this workstation it
currently fails at fact-gathering
([above](#make-deploy-platform-from-the-mac-died-at-fact-gathering), open since
2026-09-06). Check that before you rely on it mid-rotation.

**The old value outlives the rotation in Helm history.** Every release deployed
before app chart 2.12.0 stored it in its revision Secret, and Helm keeps the
last ten per release. They age out on their own; to end it sooner, delete the
stale revision Secrets (never the current revision):

```bash
kubectl get secret -n <env>-<app> -l owner=helm,name=<env>-<app>   # sh.helm.release.v1.<release>.v<n>
```

## Registry garbage collection

The registry never deletes anything on its own: every CI push moves `:latest`
to a new manifest and leaves the old one behind, untagged but still holding
its layers. `registry-gc`, a CronJob in `platform-registry`, runs
`registry garbage-collect --delete-untagged` every Sunday at 03:30 UTC. Why
that command is safe, and why the run is guarded rather than read-only, is the
comment on `cronJobs:` in `kubernetes/services/registry/app.yaml`.

- **It skips itself** when any upload was touched in the last 30 minutes, and
  says so in its log. A skip exits 0.
- **Grafana alerts** (`registry-gc-stale`) when the last success is more than 8
  days old, or when the CronJob is gone. It is delivered to Slack once the
  webhook is set, and shows in the Alerting UI either way; delivery is
  `kubernetes/services/grafana/service.yaml`'s.

Run it now, the same way the schedule does:

```bash
kubectl create job -n platform-registry --from=cronjob/registry-gc registry-gc-manual-$(date +%s)
kubectl logs -n platform-registry -l app.jterrazz.com/cronjob=gc --tail=5
```

See what it would delete, without deleting it (the last line is the count):

```bash
kubectl exec -n platform-registry deploy/registry -- \
  registry garbage-collect --dry-run --delete-untagged /etc/distribution/config.yml | tail -1
```

It depends on one setting beside it: `REGISTRY_STORAGE_CACHE_BLOBDESCRIPTOR`
is empty, which turns off the registry's in-memory blob cache. With that cache
on, a layer the job sweeps stays "present" in the running registry's memory,
and the next push that re-uses it skips the upload and writes a tag that
cannot be pulled (distribution#1803, still open). At boot the registry logs
`unknown cache type ... caching disabled`, which confirms the setting.

Three things not to do:

- **Do not re-enable the blob-descriptor cache.** See above. The only other
  safe arrangement is restarting the registry after every collection, which
  under `Recreate` is an outage every week.

- **Do not set `REGISTRY_STORAGE_MAINTENANCE_READONLY_ENABLED` on the
  Deployment.** distribution 3.1.1 panics at boot on it
  (`readonly config key must contain additional keys`), and the Deployment is
  `Recreate`, so the running pod is already gone: the registry is down, and so
  is the deploy that would restore it. That happened on 2026-09-23 for about
  five minutes. `kubectl rollout undo deployment/registry -n
  platform-registry` brings back the Helm-applied spec.
- **Do not bump `image:` without re-running the dry run.** Every live tag is
  an OCI index whose child manifests have no tag. 3.1.1 keeps them; an older
  distribution swept them and broke the tag. In the dry run's output, the
  index and both children of each tag must appear as `marking`, never as
  `eligible for deletion`.

## Add a new platform service

A "platform service" is a directory under `kubernetes/services/` and one or
more releases. Which chart renders the workload decides the shape: an UPSTREAM
chart (`values.yaml`) when one exists and is maintained, otherwise the **app
chart**: one values file per release, named after it (`op-api.yaml`,
`mongodb.yaml`, or `app.yaml` for a single-workload service). Writing a raw
Deployment is the last resort, for something no chart can express; cloudflared
(`hostNetwork: true`) is the only one left.

1. Namespace: add it to `kubernetes/cluster/namespaces.yaml` if it doesn't
   already have one; never `kubectl create ns`. A NEW namespace also needs a
   baseline NetworkPolicy file under `kubernetes/cluster/network-policies/`:
   default-deny, allow-same-namespace, namespace-wide DNS egress, and nothing
   that names one workload.
2. Values: add `kubernetes/services/<svc>/service.yaml` (the platform-service
   chart: certificate, route, volumes, credentials, per-service NetworkPolicy)
   plus either `values.yaml` for the upstream chart or one app-chart values
   file per workload. Follow an existing service as a template: `registry/`
   for a single app-chart workload, `openpanel/` for several.
3. Release: add ONE block to `kubernetes/helmfile.yaml.gotmpl` with its name,
   namespace, chart, pinned `version:` and `values:`. Its `<svc>-platform`
   sibling is `inherit: [{template: platform-service}]` and needs no version. That block
   is the whole declaration: Ansible applies it, `make diff` previews it and
   Renovate bumps it, with nothing to keep in sync. If the chart comes from a
   repository not already listed at the top of the file, add that too.
4. Ingress: `access` in `service.yaml` defaults to `private` (`public` is the
   other value); add the private hostname to `private_hostnames` in group_vars: CoreDNS needs the name before the route exists, and `smoke.sh`
   fails if the list and the live routes disagree either way. A public service
   needs a new zone; the three steps are in
   [Develop](develop.md#dns-has-exactly-three-owners).
   Smoke: **nothing**, unless the default (`GET /` -> 200) is wrong for this
   service, in which case add `smoke: { path, expect }` to the same
   `service.yaml`. The chart stamps it on the route and `scripts/smoke.sh`
   discovers it.
5. Network: for an upstream chart, declare `network:` in the same
   `service.yaml`: the pod selector (read it off that chart's pods, it cannot
   be derived) plus the ingress and egress the workload needs. For an app-chart
   workload it is `spec.network` in its own values file, and a datastore wants
   `isolated: true` so the chart derives no Traefik ingress and no internet
   egress. Schema and peer vocabulary:
   `kubernetes/charts/platform-service/README.md`. Nothing goes in
   `cluster/network-policies/` for a service that has a release, and every
   port is a POD port, never a Service port.
6. Secrets: `secrets: { path, secretName }` in `service.yaml` for a name an
   upstream chart reads literally, or `spec.secrets` on the app-chart release
   for one that becomes env vars. Nothing is applied by Ansible any more.
7. `make check` locally, then a PR; `deploy-platform.yaml` deploys on merge.

   If the release replaces a live object the cluster already has, Helm must
   ADOPT it first: annotate `meta.helm.sh/release-name` +
   `meta.helm.sh/release-namespace` and label
   `app.kubernetes.io/managed-by=Helm`, or the install fails on conflict. A
   Deployment whose SELECTOR changes cannot be adopted at all (the field is
   immutable), so it is `kubectl delete deployment <name>` immediately before
   the deploy, which is a real outage for that workload. Never do that to
   `registry`: the deploy workflow's own setup logs into it, so the run that
   would recreate it cannot start (`make deploy-platform` from the Mac is the
   way out, and it is itself broken right now,
   [above](#make-deploy-platform-from-the-mac-died-at-fact-gathering)).

## Add a new app

Apps live in their own repo and deploy themselves; this repo only owns the
chart they render through. Full schema and merge semantics:
[kubernetes/charts/app/README.md](../../kubernetes/charts/app/README.md).

1. Add `.infrastructure/application.yaml` to the app repo, with `tag:` set on
   every environment; omitting it silently deploys "staging" instead. Smoke
   needs **nothing**: the chart derives each route's probe from the path and
   the `health.path` the app already declares. Add `smoke: { path, expect }`
   to an ingress entry only when that derivation is wrong, `smoke: false` to
   opt a route out.
2. Set `INFISICAL_CLIENT_ID` / `INFISICAL_CLIENT_SECRET` as GitHub secrets on
   the app repo; see [GitHub secrets (every app repo)](#github-secrets-every-app-repo)
   above.
3. Expose `make build`, `make lint`, `make test` and call the shared workflow
   in `jterrazz/jterrazz-actions`.
4. The calling job grants `permissions: { contents: read, id-token: write }`:
   the deploy authenticates with the job's GitHub OIDC token.
5. First deploy creates the namespace, its RoleBinding and the Certificate;
   this repo needs no changes: `make redeploy-apps` picks the repo up from the
   `app.jterrazz.com/repository` annotation its Deployment now carries. A
   tailnet-only hostname is the one exception: add it to `private_hostnames`
   in group_vars, or smoke fails on the mismatch.

## Version decisions

Pins held below the current upstream release. Do not re-open without new
evidence.

| Component  | Held at        | Why                                                                                                                                                                                              |
| ---------- | -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| PostgreSQL | `17-alpine`    | Above OpenPanel's own pin (`postgres:14-alpine`, which it documents nowhere else); Prisma 6 (the ORM) supports 9.6-18. Moved from 14 to 17 on 2026-09-19 ahead of 14's 2026-11-12 EOL, by the dump/restore below. Not 18: its image moved the default data layout. `pgdata-pg14-2026-09-19` beside the live dir is the rollback. |
| ClickHouse | `26.3` LTS     | Above OpenPanel's compose pin (26.1.3.52, out of support since 2026-05 and affected by CVE-2026-51992), moved 2026-10-24 after booting 26.3.60.2 on a copy of the live data. Not past 26.4: 26.5/26.7 change event-ingest datetime parsing and reject the AggregatingMergeTree schema shape OpenPanel uses. `clickhouse-26.1-2026-10-24` beside the live dir is the rollback. |
| Redis 8.x  | staying on 7.x | Neither OpenPanel nor BullMQ publishes a Redis 8 support statement.                                                                                                                                |

### The PostgreSQL major migration (14 to 17 was run this way on 2026-09-19)

Kept as the procedure for the next major. DB was ~26 MB, ~5 minutes of
dashboard/ingest downtime end to end. **Dump with the *newer* server's
`pg_dumpall`**, which is what the PostgreSQL docs require across majors.

**Step 2 cannot be a throwaway pod.** The namespace's baseline egress policy
allows DNS only, so a `kubectl run` pod gets `connection refused` from
`op-postgres` even with the API's labels. Run the newer client as an ephemeral
container *inside* the Postgres pod instead (it shares the network namespace,
so `127.0.0.1:5432` needs no policy), and under `--profile=baseline`, because
the default debug profile adds `SYS_PTRACE`, which PodSecurity rejects:

```bash
kubectl debug -q -i pod/<op-postgres-pod> -n platform-analytics --profile=baseline \
  --image=postgres:17-alpine --env PGPASSWORD="$POSTGRES_PASSWORD" -- \
  pg_dumpall -h 127.0.0.1 -U openpanel --quote-all-identifiers > openpanel-all-$(date +%F).sql
```

Check the dump before touching anything: it must end in `\unrestrict`, hold
`CREATE DATABASE "openpanel"` and every `CREATE TABLE`. The `kubectl run`
variant below is what the docs said first and it silently writes a 200-byte
error instead of a dump.

```bash
# 1. Stop the writers (NOT postgres itself: it must serve the dump). A scale
#    is reverted by the next `helmfile apply`, so do this with the deploy
#    workflow quiet.
kubectl scale -n platform-analytics --replicas=0 deploy/op-api deploy/op-worker deploy/op-dashboard

# 2. Dump using a throwaway PG 17 client against the live PG 14 service.
kubectl run pgdump-17 -n platform-analytics --rm -i --restart=Never \
  --image=postgres:17-alpine --env PGPASSWORD="$POSTGRES_PASSWORD" -- \
  pg_dumpall -h op-postgres -U openpanel --quote-all-identifiers > openpanel-all-$(date +%F).sql
test -s openpanel-all-*.sql && grep -c "CREATE DATABASE" openpanel-all-*.sql   # sanity

# 3. Stop postgres and MOVE the old data dir aside, never delete it: it is the
#    rollback. A PG 17 server cannot read a PG 14 cluster directory.
kubectl scale -n platform-analytics --replicas=0 deploy/op-postgres
#    On the Mac (/var/lib/k8s-data is a symlink to ~/.jterrazz-infrastructure/data):
mv ~/.jterrazz-infrastructure/data/openpanel/postgres/pgdata \
   ~/.jterrazz-infrastructure/data/openpanel/postgres/pgdata-pg14-$(date +%F)
mkdir -p ~/.jterrazz-infrastructure/data/openpanel/postgres/pgdata

# 4. Swap the image to postgres:17-alpine in
#    kubernetes/services/openpanel/op-postgres.yaml, push, and let the deploy
#    apply it (or run `helmfile apply -l name=op-postgres` on the node).
#    uid/gid 70:70 is correct for the alpine variant on 17 as well; the
#    fix-permissions initContainer chowns the new empty dir. PGDATA stays
#    /var/lib/postgresql/data/pgdata so initdb never sees lost+found.
kubectl rollout status -n platform-analytics deploy/op-postgres --timeout=180s

# 5. Restore, then bring the app back. op-api runs Prisma migrations on boot.
kubectl exec -i -n platform-analytics deploy/op-postgres -- \
  psql -X -U openpanel -d postgres < openpanel-all-YYYY-MM-DD.sql
kubectl scale -n platform-analytics --replicas=1 deploy/op-api deploy/op-worker deploy/op-dashboard
kubectl rollout status -n platform-analytics deploy/op-api --timeout=300s
```

**Downtime:** dashboard + ingest down for the whole procedure; budget 15-20
min at this data size.

**Verify:** `kubectl exec -n platform-analytics deploy/op-postgres -- psql -U openpanel -d openpanel -c '\dt'`
lists the OpenPanel tables; the dashboard loads projects; a test event reaches
`analytics.jterrazz.com/api/track` and appears in ClickHouse.

**Rollback:** scale everything to 0, `mv` the `pgdata-pg14-*` directory back to
`pgdata`, restore the `postgres:14-alpine` image, scale up. The old cluster
directory is untouched, which is the entire reason step 3 moves rather than
deletes it.
