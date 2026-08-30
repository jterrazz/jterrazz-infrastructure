# @jterrazz/infrastructure

## How it all fits

**One machine.** A single OrbStack VM (`jterrazz-infrastructure`, Debian 13
trixie, arm64) on the dev Mac, running single-node k3s. There is no second
target: the Hetzner VPS this repo used to also support was removed. The
resurrection recipe is [docs/hetzner.md](docs/hetzner.md); the implementation
is intact in git history.

**Two tools, one script.** `scripts/deploy.sh` creates the VM (one `orbctl
create`, skipped when it already exists), Ansible configures it (host
hardening, Tailscale, k3s, then the release layer) and Helmfile deploys onto
it. Every platform release — name, namespace, chart, pinned version, values
file — is declared once, in `kubernetes/helmfile.yaml.gotmpl`. There is no
GitOps controller: a deploy is `helmfile apply`, run on the node from CI or
from the laptop. The two Cloudflare DNS records that point at the machine are
made by hand, once, and written down in
[docs/RUNBOOK.md](docs/RUNBOOK.md#dns-records-set-once-survive-everything) —
they never change, because the VM keeps its hostname across every repave.

**Two ways in, neither an open port.** Public traffic arrives through an
outbound QUIC tunnel: Cloudflare edge → `cloudflared` pod → Traefik → app.
Private traffic (Grafana, LibreChat, the registry, the API server) is
tailnet-only: Traefik's LoadBalancer is pinned to the Tailscale CGNAT range by
`loadBalancerSourceRanges`, and UFW double-enforces. Nothing listens on a
public address.

**Apps deploy themselves.** An app repo owns one file,
`.infrastructure/application.yaml`, and calls the shared workflow in
`jterrazz/jterrazz-actions`, which renders it through the `app` chart pulled
**unversioned** from `oci://registry.internal.jterrazz.com/charts/app`. This repo does
not know an app exists until its Certificate shows up.

**Data outlives the cluster.** Every `manual` PV is a hostPath under
`/var/lib/k8s-data`, which on this target is a symlink to
`~/.jterrazz-infrastructure/data` on the Mac (through OrbStack's `/mnt/mac`
auto-share). `make destroy && make deploy` repaves the VM; the data stays.

**k3s runs on SQLite, not etcd.** No `cluster-init`: embedded etcd keeps the
whole keyspace in RAM and runs its own compaction and snapshotting — roughly
150-300Mi of RSS for no benefit on a single node. The cluster is reproducible
from this repo in one command, and the data etcd would snapshot lives on the
Mac anyway. Re-add `cluster-init: true` the day a second node exists.

## Quick start

```bash
make deploy           # create the VM if absent + ansible site.yml — the whole machine
make deploy-platform  # ansible platform.yml only — everything above k3s
make diff             # what a deploy would change, without changing it (helmfile diff)
make redeploy-apps    # trigger every app's CI to rebuild + redeploy
make destroy          # delete the VM (the Mac-side data directory stays)
make check            # the checks CI runs, locally (alias: make lint)
make check-tools      # ansible / kubectl / orbctl / helm / helmfile / shellcheck / ansible-lint / python3 present?
make kubeconfig       # regenerate ./kubeconfig.yaml from the VM (needs the tailnet)
```

`scripts/deploy.sh` is the entry point behind all of them. It sources the
tokens in `.env`, pulls the Ansible-bound secrets from Infisical through
`scripts/infisical-vars.py` into a 0600 tempfile, and runs the playbook. A
missing secret hard-fails the run; there are no fallback defaults.

## Architecture

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
│   │     ├─ public   spwn.sh · sig.news · clawrr.com · analytics    │  │
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

## Project layout

```
ansible/
├── playbooks/     site.yml     base → security → resolved → tailscale → k3s → platform
│                  platform.yml the platform layer alone (what CI runs)
├── roles/         base · security · resolved · tailscale · k3s · platform
└── inventories/   laptop.yml (OrbStack SSH proxy) · ci.yml (over Tailscale)
                   group_vars/all.yml — THE config surface: k3s_version,
                   helm_version, helmfile_version, private_hostnames

kubernetes/
├── helmfile.yaml.gotmpl  every platform Helm release, declared ONCE: name,
│                     namespace, chart, pinned version, values file. Applied on
│                     the node by roles/platform; previewed by `make diff`.
├── charts/common/    LIBRARY chart, installed by nothing: the ONE
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
│                     middlewares + TLS options, and the NAMESPACE-BASELINE
│                     NetworkPolicy file per namespace (per-service rules live
│                     with the service, in its `network:` block)
├── schemas/          vendored kubeconform CRD schemas, for the one CRD whose
│                     public catalog copy lags the operator we run
└── services/<svc>/   one VALUES FILE per release, named after the chart that
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
              (smoke.sh and trigger-app-deploys.sh DISCOVER their targets from
              the cluster — the charts stamp the expectations as annotations)
```

## CI

| Workflow               | Trigger                                                                                          | Does                                                                                                                                                                                             |
| ---------------------- | ------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `validate.yaml`        | PR to main **and** push to main                                                                    | shellcheck + python syntax on `scripts/`; `ansible-lint -c ansible/.ansible-lint` + `--syntax-check` on both playbooks; kubeconform over `kubernetes/cluster` and every raw manifest under `kubernetes/services`; both charts rendered against their `ci/test-values.yaml`; `helmfile template` over every declared release. Plus gitleaks, helm-unittest, and assertions on the hand-synced pairs. |
| `deploy-platform.yaml` | push to main touching `ansible/**`, `kubernetes/{services,cluster,charts}/**`; or manual   | Runs `platform.yml` only, over Tailscale, from a runner joined as `tag:ci`. Never the host layer — those roles restart sshd/tailscaled and would kill the runner's own session.                    |
| `publish-chart.yaml`   | push to main touching `kubernetes/charts/app/**` or `scripts/publish-app-chart.sh`; or manual                                        | Packages and pushes the app chart. Refuses to overwrite a published version (it is consumed unversioned); a no-op when the version already exists.                                                 |
| `smoke.yaml`           | after `deploy-platform.yaml` completes; weekly schedule; or manual                                  | Runs `scripts/smoke.sh --public --private --certs` against the live cluster — the only workflow that checks the deployed state rather than the tree. It lists every IngressRoute (kubectl on the node, over the deploy SSH key) and probes what each one's `smoke.jterrazz.com/*` annotations say, so a surface an app added yesterday is checked with no edit here. |

The CI fixtures are the validation contract: both charts render near-zero
objects with default values, so a template branch no fixture reaches is a
branch CI does not check.

## Where to look next

| Question                                   | File                                                             |
| ------------------------------------------ | ---------------------------------------------------------------- |
| It's 2am and something is broken           | [docs/RUNBOOK.md](docs/RUNBOOK.md)                                |
| How do I deploy / configure an app?        | [kubernetes/charts/app/README.md](kubernetes/charts/app/README.md) |
| What do the two charts share?              | [kubernetes/charts/common/README.md](kubernetes/charts/common/README.md) |
| How do I add a new platform service / app? | [docs/RUNBOOK.md](docs/RUNBOOK.md#add-a-new-platform-service)     |
| What does an agent need to know?           | [CLAUDE.md](CLAUDE.md)                                            |
| How is public traffic wired?               | [kubernetes/services/cloudflared/README.md](kubernetes/services/cloudflared/README.md) |
| LibreChat / OpenPanel specifics            | [librechat](kubernetes/services/librechat/README.md) · [openpanel](kubernetes/services/openpanel/README.md) |
| How do I bring Hetzner back?               | [docs/hetzner.md](docs/hetzner.md)                                |
