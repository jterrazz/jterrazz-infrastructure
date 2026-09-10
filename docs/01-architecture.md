# Architecture

One machine, four layers, three charts. This chapter is the shape of the
system; what to type when it breaks is [04-operating.md](04-operating.md).

## The machine

A single OrbStack VM (`jterrazz-infrastructure`, Debian 13 trixie, arm64) on
the dev Mac, running single-node k3s. `scripts/deploy.sh` creates it with one
`orbctl create` (`vm_up`, skipped when the VM already exists), Ansible
configures it from `inventories/laptop.yml`, and Helmfile deploys onto it.

There is no provisioning state anywhere: the VM's existence is the state,
probed with `orbctl info`. There is no GitOps controller either — a deploy is
`helmfile apply`, run on the node from CI or from the laptop. Every platform
release, with its name, namespace, chart, pinned version and values file, is
declared once in `kubernetes/helmfile.yaml.gotmpl`.

There is no second target. The Hetzner VPS this repo also supported was
removed; the resurrection recipe is [09-hetzner.md](09-hetzner.md) and the
implementation is intact in git history. Do not reintroduce a `target`,
`manageDns` or `deployment_target` branch anywhere.

## Four layers

Everything above the machine belongs to one of four layers, and the vocabulary
is strict: one word, one meaning.

| Layer             | What it covers                                                   | Applied by                             |
| ----------------- | ---------------------------------------------------------------- | -------------------------------------- |
| Host              | The VM and what runs directly on it: `roles/{base,security,resolved,tailscale,k3s}` | `make deploy`, from the Mac only       |
| Cluster           | Objects belonging to no single release: `kubernetes/cluster/` — namespaces, the `manual` StorageClass, NetworkPolicies, Traefik middlewares and TLSOption | `roles/platform`'s `cluster-manifests` |
| Platform services | `kubernetes/services/<x>/`, one helmfile release block per file  | CI on merge, or `make deploy-platform` |
| Apps              | Deployed from their own repos through `charts/app`, into `prod-*` / `next-*` / `staging-*` | each app's own pipeline                |

Every file under `kubernetes/services/<x>/` is a values file, named after the
chart that consumes it:

- `values.yaml` — the upstream chart.
- `service.yaml` — `charts/platform-service`. Its release is `<x>-platform`,
  and that name is frozen: renaming it orphans the hostPath PV.
- anything else — one app-chart release, named after it (`op-api.yaml`,
  `mongodb.yaml`, or `app.yaml` when the service is a single workload).

The one exception is `cloudflared/deployment.yaml`, a raw Deployment on
purpose — [02-developing.md](02-developing.md) says why.

This repo owns the app chart, not the apps. What an app repo signs up to is
[05-deploy-contract.md](05-deploy-contract.md).

## The three charts

`charts/common` is a Helm library chart: installed by nothing, rendered by
nothing on its own. It is the one implementation of every concern the other
two charts share — IngressRoute with its middlewares and the access-middleware
choice, Certificate, the hostPath PV/PVC pair, NetworkPolicy, InfisicalSecret.
Both consumers pull it through a relative `file://../common` dependency, and
`helm package` bundles it into the app chart's `.tgz`. If a concern exists in
both charts, it belongs there.

The library invents no object name. The two charts name the same kind of
object differently, and those names address live volumes and live routes, so
every name is an input.

`charts/platform-service` renders a platform service's shared surface — route,
certificate, volumes, credentials, network policy — from one values file.
`charts/app` is what every app repo deploys through; it is published to the
private OCI registry and pulled unversioned. Reference documentation for each
lives beside it, in `kubernetes/charts/<chart>/README.md`.

## Two ways in, neither an open port

Public traffic arrives through an outbound QUIC tunnel: Cloudflare edge →
`cloudflared` pod → Traefik → app. Private traffic (Grafana, LibreChat, the
registry, the API server) is tailnet-only: Traefik's LoadBalancer is pinned to
the Tailscale CGNAT range by `loadBalancerSourceRanges`, and UFW double-enforces.
Nothing listens on a public address.

```
┌───────────────────────────── INTERNET ────────────────────────────────┐
│                          Cloudflare edge                              │
└──────────────────────────────┬────────────────────────────────────────┘
                               │ outbound QUIC tunnel — no inbound port
                               ▼
┌────────────── OrbStack VM · Debian 13 trixie · arm64 ─────────────────┐
│                                                                       │
│   Tailscale tailnet                       cloudflared (hostNetwork)   │
│   (SSH · private hosts · CI runners)                 │                │
│              └──────────────────┬────────────────────┘                │
│                                 ▼                                     │
│   ┌─────────────────── k3s · SQLite datastore ─────────────────────┐  │
│   │  Traefik ──► IngressRoutes                                     │  │
│   │     ├─ public   spwn.sh · sig.news · analytics                 │  │
│   │     └─ private  grafana · chat · registry · openpanel · gateway│  │
│   │                                                                │  │
│   │  cert-manager · Infisical operator · private Docker registry   │  │
│   │  VictoriaMetrics · VictoriaLogs · VictoriaTraces · Grafana     │  │
│   │  kube-state-metrics · node-exporter · OTel Collector           │  │
│   │  LibreChat (+ mongod) · OpenPanel (6 workloads)                │  │
│   └────────────────────────────────────────────────────────────────┘  │
│                                                                       │
│   /var/lib/k8s-data ──symlink──► /mnt/mac/…/.jterrazz-infrastructure  │
└───────────────────────────────────────────────────────────────────────┘
```

## Data outlives the cluster

Every `manual` PV is a hostPath under `/var/lib/k8s-data`, which on this target
is a symlink to `~/.jterrazz-infrastructure/data` on the Mac, through
OrbStack's `/mnt/mac` auto-share. `make destroy && make deploy` repaves the VM;
the data stays.

k3s runs on SQLite, not etcd — no `cluster-init`. Embedded etcd keeps the whole
keyspace in RAM and runs its own compaction and snapshotting, roughly
150-300Mi of RSS for no benefit on a single node. The cluster is reproducible
from this repo in one command, and the data etcd would snapshot lives on the
Mac anyway. Re-add `cluster-init: true` the day a second node exists.

## The tree

```
ansible/
├── playbooks/     site.yml     base → security → resolved → tailscale → k3s → platform
│                  platform.yml the platform layer alone (what CI runs)
├── roles/         base · security · resolved · tailscale · k3s · platform
└── inventories/   laptop.yml (OrbStack SSH proxy) · ci.yml (over Tailscale)
                   group_vars/all.yml — the config surface: k3s_version,
                   helm_version, helmfile_version, private_hostnames

kubernetes/
├── helmfile.yaml.gotmpl  every platform Helm release, declared once: name,
│                     namespace, chart, pinned version, values file. Applied on
│                     the node by roles/platform; previewed by `make diff`.
├── charts/common/    library chart, installed by nothing: the one
│                     implementation of IngressRoute, Certificate, PV/PVC,
│                     NetworkPolicy and InfisicalSecret, pulled by the two
│                     charts below through a relative file:// dependency.
│                     Reference: kubernetes/charts/common/README.md
├── charts/app/       application chart, published to the OCI registry (with
│                     charts/common bundled into the .tgz).
│                     Version: kubernetes/charts/app/Chart.yaml. Reference:
│                     kubernetes/charts/app/README.md
├── charts/platform-service/
│                     IngressRoute + Certificate + hostPath PV/PVCs + the
│                     per-service NetworkPolicy, from one values file.
│                     Reference: kubernetes/charts/platform-service/README.md
├── cluster/          cluster-wide manifests, `kubectl apply -f … -R`:
│                     namespaces, the `manual` StorageClass, Traefik
│                     middlewares + TLS options, and the namespace-baseline
│                     NetworkPolicy file per namespace (per-service rules live
│                     with the service, in its `network:` block)
├── schemas/          vendored kubeconform CRD schemas, for the one CRD whose
│                     public catalog copy lags the operator we run
└── services/<svc>/   one values file per release, named after the chart that
                      consumes it: values.yaml (an upstream chart), service.yaml
                      (platform-service: route, cert, volumes, credentials,
                      netpol) and one file per app-chart workload
                      (op-api.yaml, mongodb.yaml, app.yaml). The only raw
                      manifests left are cloudflared's Deployment and
                      cert-manager's ClusterIssuers.

scripts/      deploy.sh (creates the VM, then runs Ansible) · backup.sh ·
              infisical-vars.py · helmfile.sh · smoke.sh · assert-sync.py ·
              trigger-app-deploys.sh · publish-app-chart.sh · lib/common.sh ·
              lib/helm-plugin.sh
              (smoke.sh and trigger-app-deploys.sh discover their targets from
              the cluster — the charts stamp the expectations as annotations)
```

## Names that mean the layer

`roles/platform`, `playbooks/platform.yml`, `make deploy-platform`, the
`platform-*` namespaces and the app chart's `platformServices` all name the
layer, not the chart. They are consistent and stay as they are.
