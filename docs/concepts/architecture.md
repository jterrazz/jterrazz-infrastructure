# Architecture

One machine, four layers, two charts and the library they share. This page is
the shape of the system; its boundary gate by gate is
[Security](security.md), and what to type when it breaks is
[Operate](../guides/operate.md).

## The machine

A single OrbStack VM (`studio-infrastructure`, Debian 13 trixie, arm64) on
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

| Layer             | What it covers                                                                                                                                                                                                                                                            | Applied by                                      |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------- |
| Host              | the VM itself: `roles/{base,security,resolved,tailscale,k3s,backup}`                                                                                                                                                                                                      | `make deploy`, from the Mac only                |
| Cluster           | the `cluster` release, `src/kubernetes/charts/cluster`: the platform namespaces and their NetworkPolicy baselines, the `manual` StorageClass, the RBAC, the two admission policies, Traefik's shared objects; plus Traefik's bundled config and CoreDNS (`roles/cluster`) | the first helmfile release, and `roles/cluster` |
| Platform services | `src/kubernetes/services/<svc>/`, one helmfile release per values file                                                                                                                                                                                                    | CI on merge, or `make deploy-platform`          |
| Apps              | each app's own repository, through `charts/app`, into `<app>-<env>` namespaces it creates                                                                                                                                                                                 | each app's own pipeline                         |

Every file under `src/kubernetes/services/<svc>/` is a values file named after
the chart that consumes it: `values.yaml` for an upstream chart, `service.yaml`
for `charts/platform` (release `<svc>-platform`, a name frozen because
it owns live volumes), and any other name for one app-chart release
(`op-api.yaml`, or `app.yaml` for a single workload). A name starting with
`_` is values several releases share (`openpanel/_common.yaml`). The
platform's dashboards and alert rules live at the repository root, in
`.infrastructure/{dashboards,alerts}/`, the layout every app ships them in,
and `grafana-platform` renders them. The one raw manifest is
cert-manager's ClusterIssuers, applied once its CRDs exist.

## Two charts and the library they share

`charts/common` is a library chart: installed by nothing, it is the one
implementation of every object the other two share (IngressRoute and its
middlewares, the wildcard Certificates, the hostPath PV and PVC, NetworkPolicy,
InfisicalSecret, the smoke annotations). It invents no name, since those names
address live volumes and routes. `charts/platform` renders a platform
service's shared surface from its `service.yaml`. `charts/app` renders any
workload, an app's or a platform service's; it is published to the registry
and pulled unversioned
([ADR-010](../decisions/010-every-workload-renders-through-two-charts.md)).
A fourth, `charts/cluster`, is local and owns the cluster's own objects, so a
file removed there is an object removed.

## Two ways in, neither an open port

Public traffic arrives through an outbound tunnel (QUIC, HTTP/2 as fallback): the Cloudflare edge,
then `cloudflared`, a pod in `platform-networking`, then Traefik's `tunnel`
entrypoint, then the app; external-dns writes each public host's record off its
IngressRoute. Private traffic (the products' `*.internal` hosts, Grafana, the
registry, the API server, staging) is tailnet-only: Traefik's LoadBalancer
admits the Tailscale range alone, a private route sits on `websecure`, which
cloudflared cannot reach, and the nft guard keeps every other port of the node
shut
([ADR-002](../decisions/002-public-traffic-enters-through-a-cloudflare-tunnel.md),
[ADR-003](../decisions/003-traefiks-service-is-the-tailnet-gate.md),
[ADR-006](../decisions/006-the-host-has-no-public-inbound-path.md),
[ADR-026](../decisions/026-a-public-route-is-published-by-its-ingressroute.md)).

```text
 INTERNET · Cloudflare edge                       TAILNET · SSH, CI runners, laptops
        ▲ outbound QUIC tunnel                      │
        │                                           │ tailscale0, 100.64.0.0/10
┌───────┼─── OrbStack VM · nft guard ───────────────┼────────────────────────┐
│ ┌─────┼───── k3s ─────────────────────────────────┼──────────────────────┐ │
│ │     │                                           │                      │ │
│ │ cloudflared ──► :tunnel ── Traefik ── :websecure ◄── klipper-lb        │ │
│ │ platform-networking  │                   │  admits the tailnet alone   │ │
│ │                      ▼                   ▼                             │ │
│ │      public: jterrazz.com        private: console · intelligence       │ │
│ │      sig.news · spwn.sh          signews · grafana · registry          │ │
│ │                                  openpanel · *.staging                 │ │
│ └────────────────────────────────────────────────────────────────────────┘ │
└────────────────────────────────────────────────────────────────────────────┘
```

## Data outlives the cluster

Every `manual` PV is a hostPath under `/var/lib/k8s-data`, a symlink to
`~/.studio-infrastructure/data` on the Mac through OrbStack's `/mnt/mac`
share, so `make destroy && make deploy` repaves the VM and keeps the data
([ADR-008](../decisions/008-storage-on-orbstack-spends-fsyncs-not-bytes.md)).

## Names

Every name says who owns the thing
([ADR-023](../decisions/023-names-follow-the-owner-and-one-name-runs-through-everything.md)).
A platform namespace is `platform-<capability>`, declared in
`charts/cluster/values.yaml`. An app is `<brand>-<role>` (`studio-console`,
`signews-api`), and that one name is its release, image, volume, data
directory and Infisical folder; each environment gets a namespace
`<app>-<env>`, created by the app's own deploy, and an app every environment
calls (`scope: shared`) one namespace `<app>`.

Every namespace but
Kubernetes' own carries `studio.jterrazz.com/tier: platform | app`, and an app
namespace also `studio.jterrazz.com/repository`, `studio.jterrazz.com/app` and
`studio.jterrazz.com/environment` (or `studio.jterrazz.com/scope: shared`),
which the ownership policy and the platform contract select on; every key the
estate invents is under `studio.jterrazz.com/`
([ADR-029](../decisions/029-an-app-is-declared-strictly-reads-its-own-secrets-and-is-reached-by-consent.md)).

Two words carry more than one meaning here:

- **platform** is the layer above k3s, so `playbooks/platform.yml`,
  `make deploy-platform`, the `platform-*` namespaces, the `<svc>-platform` releases of `charts/platform` and
  the platform's own services all name the layer, never the chart.
- **tier** is only the namespace label above. The helmfile's deploy passes are
  `pass: cluster | operators | claims` ([ADR-009](../decisions/009-one-helmfile-declares-every-platform-release.md)).

## The tree

```text
src/
├── ansible/        playbooks/site.yml      base → security → resolved → tailscale → k3s → platform
│                   playbooks/platform.yml  cluster → cloudflare → helm → releases → publish, what CI runs
│                   inventories/            laptop.yml (OrbStack SSH) · ci.yml (tailnet) · k3d.yml
│                                           group_vars/all/, the config surface
├── kubernetes/     helmfile.yaml.gotmpl    every platform release, declared once (ADR-009)
│                   charts/                 common · platform · app · cluster
│                   services/<svc>/         one values file per release
│                   schemas/                a vendored kubeconform CRD schema
└── scripts/        deploy.sh · helmfile.sh · backup.sh · redeploy-apps.sh · lib/
specs/specs/        the platform contract on @jterrazz/test (ADR-022): api · cluster · health
                    · routes · admission · host
docs/               this manual and its decisions
skills/             the agent skill other repositories load
```
