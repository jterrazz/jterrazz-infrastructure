# Architecture

One machine, four layers, three charts. This page is the shape of the
system; what to type when it breaks is [Operate](../guides/operate.md).

## The machine

A single OrbStack VM (`jterrazz-infrastructure`, Debian 13 trixie, arm64) on
the dev Mac, running single-node k3s on SQLite
([ADR-007](../decisions/007-k3s-runs-single-node-on-sqlite.md)).
`src/scripts/deploy.sh` creates it with one `orbctl create` when it does not
exist, Ansible configures it, and Helmfile deploys onto it.

There is no provisioning state: the VM's existence is the state, probed with
`orbctl info`. There is no GitOps controller either: a deploy is `helmfile
apply`, run on the node from CI or from the Mac. There is no second target:
bringing a rented one back is [Resurrect Hetzner](../guides/resurrect-hetzner.md)
([ADR-004](../decisions/004-one-orbstack-vm-is-the-only-target.md)).

## Four layers

| Layer             | What it covers                                                                                  | Applied by                             |
| ----------------- | ----------------------------------------------------------------------------------------------- | -------------------------------------- |
| Host              | the VM itself: `roles/{base,security,resolved,tailscale,k3s}`                                   | `make deploy`, from the Mac only       |
| Cluster           | objects of no release, `src/kubernetes/cluster/`: namespaces, the `manual` StorageClass, namespace NetworkPolicy baselines, the app-deployer RBAC and admission policy, Traefik middlewares | `roles/platform`'s `cluster-manifests` |
| Platform services | `src/kubernetes/services/<svc>/`, one helmfile release per values file                          | CI on merge, or `make deploy-platform` |
| Apps              | each app's own repository, through `charts/app`, into `<app>-<env>` namespaces it creates | each app's own pipeline           |

Every file under `src/kubernetes/services/<svc>/` is a values file named after
the chart that consumes it: `values.yaml` for an upstream chart, `service.yaml`
for `charts/platform-service` (release `<svc>-platform`, a name frozen because
it owns live volumes), and any other name for one app-chart release
(`op-api.yaml`, or `app.yaml` for a single workload). The exceptions are
cert-manager's ClusterIssuers and Traefik's HelmChartConfig, raw manifests, and the infrastructure dashboards under `grafana/dashboards/`, one ConfigMap per JSON file.

## The three charts

`charts/common` is a library chart: installed by nothing, it is the one
implementation of every object the other two share (IngressRoute and its
middlewares, Certificate, the hostPath PV and PVC, NetworkPolicy,
InfisicalSecret, the smoke annotations). It invents no name, since those names
address live volumes and routes. `charts/platform-service` renders a platform
service's shared surface from its `service.yaml`. `charts/app` renders any
workload, an app's or a platform service's; it is published to the registry
and pulled unversioned
([ADR-010](../decisions/010-every-workload-renders-through-two-charts.md)).

## Two ways in, neither an open port

Public traffic arrives through an outbound HTTP/2 tunnel, from the Cloudflare
edge to `cloudflared`, then Traefik, then the app. Private traffic (Grafana,
the registry, the API server, staging) is tailnet-only: Traefik's LoadBalancer
admits the Tailscale range alone and UFW repeats it
([ADR-003](../decisions/003-traefiks-service-is-the-tailnet-gate.md),
[ADR-006](../decisions/006-the-host-has-no-public-inbound-path.md)).

```text
┌───────────────────────────── INTERNET ────────────────────────────────┐
│                          Cloudflare edge                              │
└──────────────────────────────┬────────────────────────────────────────┘
                               │ outbound HTTP/2 tunnel, no inbound port
                               ▼
┌────────────── OrbStack VM · Debian 13 trixie · arm64 ─────────────────┐
│   Tailscale tailnet                       cloudflared                 │
│   (SSH · private hosts · CI runners)                 │                │
│              └──────────────────┬────────────────────┘                │
│                                 ▼                                     │

│   ┌─────────────────── k3s · SQLite datastore ─────────────────────┐  │
│   │  Traefik ──► IngressRoutes                                     │  │
│   │     ├─ public   jterrazz.com · spwn.sh · sig.news · analytics  │  │
│   │     └─ private  grafana · registry · openpanel · staging       │  │
│   │                                                                │  │
│   │  cert-manager · Infisical operator · Zot registry              │  │
│   │  VictoriaMetrics · VictoriaLogs · VictoriaTraces · Grafana     │  │
│   │  kube-state-metrics · node-exporter · OTel Collector           │  │
│   │  OpenPanel (6 workloads)                                       │  │
│   └────────────────────────────────────────────────────────────────┘  │

│   /var/lib/k8s-data ─symlink─► /mnt/mac/.../.jterrazz-infrastructure  │
└───────────────────────────────────────────────────────────────────────┘
```

## Data outlives the cluster

Every `manual` PV is a hostPath under `/var/lib/k8s-data`, a symlink to
`~/.jterrazz-infrastructure/data` on the Mac through OrbStack's `/mnt/mac`
share, so `make destroy && make deploy` repaves the VM and keeps the data
([ADR-008](../decisions/008-storage-on-orbstack-spends-fsyncs-not-bytes.md)).

## The tree

```text
src/
├── ansible/        playbooks/site.yml   base → security → resolved → tailscale → k3s → platform
│                   playbooks/platform.yml  the platform layer alone, what CI runs
│                   inventories/         laptop.yml (OrbStack SSH) · ci.yml (tailnet) · k3d.yml
│                                        group_vars/all.yml, the config surface

├── kubernetes/     helmfile.yaml.gotmpl every platform release, declared once (ADR-009)
│                   charts/              common · platform-service · app
│                   cluster/             manifests applied with `kubectl apply -R`
│                   services/<svc>/      one values file per release
│                   schemas/             a vendored kubeconform CRD schema

└── scripts/        deploy.sh · helmfile.sh · backup.sh · redeploy-apps.sh · lib/
specs/              the platform contract, a TypeScript project on @jterrazz/test (ADR-022)
docs/               this manual and its decisions
skills/             the agent skill other repositories load
```

`roles/platform`, `playbooks/platform.yml`, `make deploy-platform`, the
`platform-*` namespaces and the app chart's `platformServices` all name the
layer, not the chart.
