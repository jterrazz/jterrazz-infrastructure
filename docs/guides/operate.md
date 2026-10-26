# Operating

What to run when something is down, how to rebuild from nothing, and the
gestures that rotate a credential or add a service. Where each secret lives is
[Secrets](../reference/secrets.md), the boundary is
[Security](../concepts/security.md), and the rules a change follows are
[Develop](develop.md).

## Reaching the cluster

```bash
orb -m studio-infrastructure -u root kubectl get pod -A   # from the Mac, always
ssh root@studio-infrastructure@orb                        # OrbStack's SSH proxy
export KUBECONFIG=./kubeconfig.yaml                         # from a tailnet client
```

Every `make deploy` writes `kubeconfig.yaml` with the node's MagicDNS name as
its server, so it works only from the tailnet; `make kubeconfig` rewrites it
without a deploy. The `orb` SSH alias needs `~/.orbstack/ssh/config`, which is
why `inventories/laptop.yml` passes it explicitly.

## Troubleshooting

```bash
kubectl get pod -A | grep -v Running ; helm list -A --failed ; kubectl get certificate -A
make smoke                                     # the platform contract, from the Mac
make diff                                      # what the next platform deploy changes (tailnet)
./src/scripts/helmfile.sh diff -l name=grafana     # one release

# cert-manager after k3s churn: the webhook and cainjector lose the API; restart all three
kubectl rollout restart -n platform-networking \
  deploy/cert-manager deploy/cert-manager-webhook deploy/cert-manager-cainjector

# the tunnel
kubectl logs -n platform-networking deploy/cloudflared --tail=30 | grep -E 'Registered|edge'

# a public host that does not resolve: external-dns writes its record off the IngressRoute
kubectl logs -n platform-networking deploy/external-dns --tail=20
kubectl get ingressroute -A -o custom-columns=NAME:.metadata.name,EP:.spec.entryPoints

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
joins as `studio-infrastructure-2` and every private hostname breaks. Delete
the stale device in the Tailscale admin console, or rename the new one:

```bash
curl -H "Authorization: Bearer $TS_API_KEY" -X POST \
  "https://api.tailscale.com/api/v2/device/<id>/name" -d '{"name":"studio-infrastructure"}'
```

A node back **logged out** after a reboot logs itself in through
`tailscale-autoauth.service`; if it did not, read that unit's journal first.

### DNS on the VM

OrbStack's DHCP hands out a resolver (`0.250.250.200`) that drops queries;
`roles/resolved` removes it (ADR-004). Check the file kubelet hands CoreDNS,
never `/etc/resolv.conf`, which always shows the 127.0.0.53 stub:

```bash
orb -m studio-infrastructure -u root cat /run/systemd/resolve/resolv.conf   # 1.1.1.1 and 9.9.9.9 only
orb -m studio-infrastructure -u root resolvectl status eth0                 # no "DNS Servers:" line
```

### Objects that need a gesture before they move

- **Use fully-qualified CRD names** with kubectl: `certificate.cert-manager.io`,
  `ingressroute.traefik.io`.
- **The cluster's own objects are a release** (`charts/cluster`): a file removed
  is an object removed on the next deploy, except a namespace, which
  `helm.sh/resource-policy: keep` leaves standing with its data; delete one by
  hand. A release dropped from the helmfile stays installed: set
  `installed: false` for one deploy, then remove its entry.
- **Helm adopts an existing object** only with the annotations
  `meta.helm.sh/release-name` and `meta.helm.sh/release-namespace` and the label
  `app.kubernetes.io/managed-by=Helm`. A Deployment whose selector changes
  cannot be adopted at all: delete it right before the deploy, an outage for
  that workload. Never do this to `registry`: the deploy workflow logs in to it
  first, so recreate it with `make deploy-platform` from the Mac.

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

## Repaving the cluster

```bash
# 0. Snapshot the fleet while the Deployments that name it still exist.
make -s redeploy-apps ARGS=--dry-run > ~/fleet-$(date +%F).txt

# 1. Stop the workloads: `systemctl stop k3s` leaves the containers writing.
orb -m studio-infrastructure -u root /usr/local/bin/k3s-killall.sh

# 2. Back up the data directory (or `make backup`).
tar -czf ~/k8s-data-$(date +%F).tar.gz -C ~/.studio-infrastructure data

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

The node snapshots every persistent volume but the registry each Sunday at
03:30, stopping the workloads for about a minute, encrypted with age to a
public key, into `~/.studio-infrastructure/backups/`, the four newest kept
([ADR-024](../decisions/024-backups-are-weekly-consistent-and-encrypted-to-a-public-key.md)).
`make backup` takes one now; `make backup ARGS=--verify` decrypts the newest
with `BACKUP_AGE_IDENTITY` and lists what it holds.

## Restoring from backup

All persistent state is `/var/lib/k8s-data` on the node, a symlink to
`~/.studio-infrastructure/data` on the Mac. To restore, stop the consumer,
replace its directory from a snapshot, and start it again:

```bash
age -d -i <identity file> k8s-data-<stamp>.tar.gz.age | tar -xzf - -C <target>
```

The registry is not in a snapshot: after restoring onto a new node,
`make redeploy-apps` rebuilds every image.

```text
data/
├── victoria-metrics/ · victoria-logs/ · victoria-traces/
├── registry/zot/        Zot's OCI store
├── openpanel/           postgres/ · clickhouse/ · redis/
└── <app>-<env>/         one per app volume, from the app chart
```

Grafana's volume lives in the VM (`/var/lib/grafana-node-local`), and a repave
resets it. Every directory here survives a repave, so deleting one is the
deletion the `Retain` policy protects against. Database-consistent dumps are
in [the OpenPanel README](../../src/kubernetes/services/openpanel/README.md#backup-and-restore).

## Rotating credentials

| What                       | How                                                                                                                                                                                                                                                                                                        |
| -------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Any Infisical-held secret  | Change it in Infisical. The operator resyncs every 5 minutes (its default; no CR sets `syncConfig`), and `kubectl delete pod -n platform-secrets -l control-plane=controller-manager` forces it. A consumer reading it as env still needs a rollout restart, and a deploy secret a `make deploy-platform`. |
| `CLOUDFLARE_TUNNEL_TOKEN`  | A new connector token in Zero Trust, stored at `/studio-infrastructure`, a resync, then `kubectl rollout restart deploy/cloudflared -n platform-networking`.                                                                                                                                             |
| `CLOUDFLARE_DNS01_TOKEN`   | A new token (Zone, DNS, Edit on `jterrazz.com`) at `/studio-infrastructure`, then `make deploy-platform`, which rewrites `cloudflare-api-token`; revoke the old one.                                                                                                                                     |
| `CLOUDFLARE_RECORDS_TOKEN` | A new token (Zone, DNS, Edit on every public zone; Account, Cloudflare Tunnel, Edit) at `/studio-infrastructure`, a resync, then `kubectl rollout restart deploy/external-dns -n platform-networking`; revoke the old one.                                                                               |
| The registry accounts      | Two accounts overlapping, never a swap: [below](#rotating-the-registry-password).                                                                                                                                                                                                                          |
| CI deploy SSH key          | `ssh-keygen -t ed25519`, the public half into `security_ci_deploy_pubkey`, `gh secret set CI_DEPLOY_SSH_PRIVATE -R jterrazz/studio-infrastructure`, then `make deploy`.                                                                                                                                  |

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

2. **Store the new pair in `studio-ci`**, generated without whitespace: a
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
   gh workflow run deploy-platform.yaml -R jterrazz/studio-infrastructure   # or make deploy-platform
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

A platform service is a directory under `src/kubernetes/services/` holding one
values file per release, named after the chart that renders it
([Architecture](../concepts/architecture.md#four-layers)). Prefer a maintained
upstream chart, else the app chart; a raw manifest is the last resort.

1. **Namespace**: add it to `src/kubernetes/charts/cluster/values.yaml` with its
   Pod Security level and baseline flags; a rule for a workload goes there,
   under `templates/network-policies/`, only when no release of ours can
   declare it (cert-manager's).
2. **Values**: `service.yaml` for the route, certificate, volumes, credentials
   and policy, plus `values.yaml` for an upstream chart or one app-chart file
   per workload. `registry/` is the single-workload example, `openpanel/` the
   multi-workload one.
3. **Release**: one block in `src/kubernetes/helmfile.yaml.gotmpl` with its pinned
   `version:`; the `<svc>-platform` sibling inherits the `platform-service`
   template. That block is the whole declaration.
4. **Route**: `access` defaults to `private`, under `*.internal`. A public zone is
   [three steps](develop.md#dns-has-exactly-three-owners). Add `smoke:` only
   when `GET /` does not answer 200.
5. **Network**: a `network:` block in `service.yaml` for an upstream chart, with
   the pod labels read off the running pods; `spec.network` for an app-chart
   workload, where a datastore is `isolated: true`. Ports are pod ports.
6. **Secrets**: `secrets: { path, secretName }` in `service.yaml` for a name a
   chart reads literally, `spec.secrets` for env vars.
7. `make check`, then merge: `deploy-platform.yaml` deploys it.
