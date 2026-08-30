# CLAUDE.md

Delta-only notes for agents: what the tree does **not** tell you. Architecture
is in [README.md](README.md), operations in [docs/RUNBOOK.md](docs/RUNBOOK.md),
the `application.yaml` schema in
[kubernetes/charts/app/README.md](kubernetes/charts/app/README.md).

## Active state

One cluster: k3s on an OrbStack VM (`jterrazz-infrastructure`, Debian 13
trixie, arm64) on the dev Mac. Pulumi stack `jterrazz/local`, Ansible inventory
`inventories/laptop.yml`. Hetzner is a recipe in `docs/hetzner.md` and git
history, **not** a live mode — do not reintroduce a `target` / `manageDns` /
`deployment_target` branch anywhere.

## Vocabulary

One word, one meaning. Everything below "platform" is one of four layers.

- **Host layer** — the VM and what runs directly on it: `roles/{base,security,resolved,tailscale,k3s}`, applied only by `make deploy` from the Mac.
- **Cluster layer** — objects that belong to no single release: `kubernetes/cluster/` (namespaces, StorageClass, NetworkPolicies, Traefik middlewares + TLSOption), applied by `roles/platform`'s `cluster-manifests`.
- **Platform services** — `kubernetes/services/<x>/`, one release block each in `kubernetes/helmfile.yaml.gotmpl`. `values.yaml` = values for the UPSTREAM chart; `service.yaml` = values for our `charts/platform-service`; the release it produces is `<x>-platform` and **that name is frozen** (renaming it orphans the hostPath PV).
- **Apps** — deployed from their own repos through `charts/app`, into `prod-*` / `next-*` / `staging-*`. This repo owns the chart, not the app.

`charts/common` is the odd one out: a Helm **library chart**, installed by
nothing and rendered by nothing on its own. It is the ONE implementation of
every concern the other two charts share — IngressRoute (+ its middlewares and
the access-middleware choice), Certificate, the hostPath PV/PVC pair,
NetworkPolicy, InfisicalSecret — pulled by both through a relative
`file://../common` dependency and bundled into the app chart's `.tgz` by `helm
package`. If a concern exists in both charts, it belongs there. It invents no
object **name**: the two charts name the same kind of object differently and
those names address live volumes and live routes, so every name is an input.

`roles/platform`, `playbooks/platform.yml`, `make deploy-platform`, the
`platform-*` namespaces and the app chart's `platformServices` all name the
LAYER, not the chart — they are consistent and stay as they are.

## Hand-synced pairs

Nothing enforces these at runtime; each has drifted at least once. Change one,
change all. The **Checked by** column is literal — where it says
`assert-sync.py`, editing one side and not the other fails `make check` and the
`scripts` job of `validate.yaml`; where it says *nothing*, the only thing
standing between you and the drift is this table.

| A                                                     | B                                                        | Checked by | Why they must match                                                    |
| ----------------------------------------------------- | -------------------------------------------------------- | ---------- | ---------------------------------------------------------------------- |
| the same two lists                                    | `PRIVATE_CHECKS` (`scripts/smoke.sh`)                     | `assert-sync.py` (one-way: config ⊆ smoke) | A private hostname nothing probes is a surface whose loss nobody notices. The status codes stay a per-service judgement call, so the check never derives them. |
| `SCOPES` in `scripts/infisical-vars.py`               | the `assert` list in `roles/platform/tasks/preflight.yml` | `assert-sync.py` | Preflight is the second gate on the same secret set; a secret fetched but unasserted fails halfway through a deploy instead of at the start. |
| `forwardedHeaders.trustedIPs` (`services/traefik/helm-chart-config.yaml`) | `rate-limit` `ipStrategy.excludedIPs` (`cluster/traefik/middleware.yaml`) | `assert-sync.py` | Both enumerate "hops that are ours". If they disagree, the rate limiter keys on the wrong XFF element or on nothing. |
| `helm_version` (`group_vars/all.yml`)                 | `azure/setup-helm` version in `validate.yaml` **and** `publish-chart.yaml` | `assert-sync.py` | Three machines, one Helm. A chart packaged by one version and rendered by another is a silent behaviour difference. |
| `helmfile_version` (`group_vars/all.yml`)             | `HELMFILE_VERSION=` in `validate.yaml`                    | `assert-sync.py` | The node applies `kubernetes/helmfile.yaml.gotmpl`; CI renders it. helmfile 1.x already changed *when* a state file is templated at all, so a runner on another minor can render a file the node would refuse — or render a different one and pass. |
| `ansible-core==` in `validate.yaml`                   | `ansible-core==` in `deploy-platform.yaml`                | `assert-sync.py` | One lints the playbooks, the other applies them. Different minors, and a green lint proves nothing about the run. |
| helm-unittest version in `validate.yaml`              | the same version in the `Makefile`                        | `assert-sync.py` | The plugin embeds its own renderer, so the committed `__snapshot__` files only reproduce against the version that wrote them. |
| every `busybox@sha256:` in the tree                   | each other                                                | `assert-sync.py` | Digest pins only work if a bump touches every copy; the one that was missed is the one nobody re-rendered. |
| the `infisical` release's `version:` (`kubernetes/helmfile.yaml.gotmpl`) | `kubernetes/schemas/secrets.infisical.com/infisicalsecret_v1alpha1.json` | **nothing** — a stale schema still validates | The vendored schema overrides a datreeio catalog copy that differs in exactly one way: the catalog sets `additionalProperties: false` at every object level, while the operator's own CRD does not (the API server *prunes* unknown fields rather than refusing the object). Bump the chart, re-extract the CRD — regeneration command in `kubernetes/schemas/README.md`. Skip it and CI validates against a CRD the cluster no longer has, so the break lands at `kubectl apply`. |
| `PUBLIC_CHECKS` (`scripts/smoke.sh`)                  | `REPOS` + `PLATFORM_PUBLIC_HOSTS` (`scripts/trigger-app-deploys.sh`) | `assert-sync.py` (both ways) | `make redeploy-apps` is what brings the fleet back after a repave. A repo missing from it is a service that silently never returns while smoke keeps reporting its hosts down. |
| `scripts/publish-app-chart.sh` (run by `publish-chart.yaml`) | the guard in `roles/platform/tasks/publish-app-chart.yml` | `assert-sync.py` (pull ref, push ref, chart dir, and that the workflow calls the script) | The node has no checkout of this repo (`stage-manifests.yml` copies only `kubernetes/`), so the fresh-cluster publisher must stay a separate copy. Both must guard the same coordinates or one overwrites a version the other thinks is published. |
| `security_ci_deploy_pubkey` (`roles/security/defaults/main.yml`) | GitHub secret `CI_DEPLOY_SSH_PRIVATE`              | **nothing** — B lives outside the repo | Split keypair. Rotating needs both plus a `make deploy` to roll the pubkey onto the VM. |
| `version:` in `charts/app/Chart.yaml`                 | the published OCI chart                                   | **nothing** at PR time — B lives in the registry | The chart is pulled **unversioned** by every app. Two publish guards exist (`scripts/publish-app-chart.sh` via `publish-chart.yaml`, and `roles/platform/tasks/publish-app-chart.yml`) and both skip rather than overwrite — so forgetting the bump publishes nothing, silently. |
| `version:` in `charts/common/Chart.yaml`               | the `common` `dependencies:` pin in `charts/app/Chart.yaml` **and** `charts/platform-service/Chart.yaml` | `assert-sync.py` | A `file://` dependency resolves by EXACT version. Bump the library alone and `helm dependency update` fails — on a runner mid-validate, or on the node mid-deploy, after some releases have already been upgraded. |
| a service's `network:` block (`services/<x>/service.yaml`) | its namespace file (`cluster/network-policies/<ns>.yaml`) | **nothing** — policies union, so neither side can detect the other | One split, applied by hand: the namespace BASELINE (default-deny, allow-same-namespace, namespace-wide DNS/egress) stays in `cluster/`; anything naming ONE workload moves into that service's `network:`. Declare a rule in both and you get harmless duplication; declare it in neither and the packet is dropped by the default-deny with nothing logged anywhere. |
| `ci/test-values.yaml` fixtures                        | the chart templates                                       | **nothing** — no equality to assert | Both charts render near-zero objects with default values, so CI only *exercises* the fixtures (`helm lint` / `template` / `unittest`); it cannot tell that a new template branch went unfixtured. `charts/common` has no fixture at all — a library chart renders nothing on its own — so every branch it holds (each NetworkPolicy peer form, each middleware) is reached ONLY through these two files. |

## Gotchas

Repo-specific, each one paid for at least once.

- **`orb create debian` gives you bookworm.** Debian is the one distro where
  OrbStack's bare image name resolves to the *previous* stable, so
  `pulumi/src/targets/orbstack.ts` pins `version: "trixie"` explicitly. Never
  drop it — every Ansible role is Debian-13-native (deb822 repositories,
  socket-activated sshd, systemd-resolved as a separate package).
- **`orbctl create -u root` is broken** since OrbStack 2.2.0 (its setup runs
  `usermod --uid 501 root`, which fails against PID 1). The VM is created with
  the default macOS-named user; Ansible connects as `root@<vm>@orb`.
- **OrbStack DHCP hands out a bogus resolver** (`0.250.250.200`) that silently
  drops queries, and it takes **two** fixes, not one. `upstream.conf` sets the
  *global* resolver; `UseDNS=false` removes the *per-link* one. The `resolved`
  role writes both:
  `/etc/systemd/resolved.conf.d/upstream.conf` (`DNS=1.1.1.1 9.9.9.9`) and a
  systemd-networkd drop-in at
  `/etc/systemd/network/eth0.network.d/10-no-dhcp-dns.conf`.
  **Do not diagnose this by looking for a missing `upstream.conf`** — that was
  the old note here and it is wrong. `upstream.conf` was present the whole time
  the bogus resolver was still in use, because a global `DNS=` cannot displace a
  DHCP-supplied link server. The real check is the *uplink* file, which is the
  one kubelet pins and therefore the one CoreDNS forwards to:

  ```bash
  orb -m jterrazz-infrastructure -u root cat /run/systemd/resolve/resolv.conf
  # want exactly: nameserver 1.1.1.1 / nameserver 9.9.9.9 — no third line
  orb -m jterrazz-infrastructure -u root resolvectl status eth0
  # want: "DNS Servers:" absent under Link N (eth0)
  ```

  `/etc/resolv.conf` is useless for this: it is symlinked to `stub-resolv.conf`
  and always shows a single `nameserver 127.0.0.53`.
  `networkctl status eth0 | grep 'Network File'` names the file the drop-in must
  sit beside — the role derives it rather than hardcoding `eth0.network`.
- **cloudflared must run `hostNetwork: true`** on this target. The CNI bridge
  mangles outbound TCP/7844 to the Cloudflare edge and the tunnel handshake
  gets RSTed — while plain `curl` from the same pod IP works fine. `--protocol
  http2` is set for the same class of reason (OrbStack's NAT eats outbound
  UDP/443).
- **kubelet's resolv-conf is pinned** to `/run/systemd/resolve/resolv.conf` in
  `roles/k3s/templates/config.yaml.j2`. Point it at `/etc/resolv.conf` and
  CoreDNS (which uses `dnsPolicy: Default`) forwards into its own 127.0.0.53
  stub and the loop plugin fatals on startup.
- **buildkit needs `network=host` in CI.** `jterrazz-actions/actions/docker-build`
  sets it so buildkit sees the runner's Tailscale resolver; without it
  `docker push registry.internal.jterrazz.com/…` NXDOMAINs on the public CNAME chain.
- **Tailscale identity collision.** A VM destroyed without `tailscale logout`
  leaves its device behind; the replacement joins as `<hostname>-2` and MagicDNS
  stops resolving the canonical name, which breaks every private hostname. Fix
  in `docs/RUNBOOK.md`.
- **cert-manager loses its API connection after any k3s churn** — restart
  cert-manager, its webhook and cainjector together. This is the single most
  common cause of a stuck Certificate.
- **Helm adoption of existing objects** needs the annotations
  `meta.helm.sh/release-name` + `meta.helm.sh/release-namespace` and the label
  `app.kubernetes.io/managed-by=Helm`, or the install fails on conflict.
- **Immutable fields mean delete-and-recreate**: Deployment selectors, PV
  `hostPath.type`, PVC `spec.selector`. Changing a `pathSuffix` or a PV name in
  a `service.yaml` moves live data — the current paths are byte-identical to
  what the pre-chart manifests produced, on purpose. **The Helm release names
  `<x>-platform` are frozen** for the same class of reason: the chart behind
  them is `platform-service`, but a renamed release is a NEW release, and the
  old one keeps the hostPath PV it bound.
- **Never chain `private-access` and `cluster-internal-access`.** Traefik ANDs
  chained ipAllowLists, so chaining allows strictly *less*, not more. The
  second is a strict superset of the first; a route picks one.
- **Use fully-qualified CRD names** with kubectl: `certificate.cert-manager.io`,
  `ingressroute.traefik.io`.
- **A kube-system NetworkPolicy must allow klipper-lb explicitly.** The svclb
  pods receive the node's own address after DNAT, so `allow-same-namespace`
  never covers them. Miss it and public traffic keeps working (cloudflared
  dials Traefik's ClusterIP) while every tailnet client — CI included — gets
  `connection refused` on 443.
- **Other OrbStack machines read this VM's filesystem as root.** `/mnt/machines`
  makes file modes irrelevant, so `0600` on the kubeconfig is defence in depth,
  not a fix. The controls that work are the nftables guard in `roles/security`
  and creating dev machines with `--isolated`.
- **`chmod` cannot protect `/var/lib/k8s-data`.** Pods write through virtiofs as
  uids 70/101/472/999/1000; dropping world-execute breaks Postgres, ClickHouse,
  Mongo, Grafana and signews-api at once. Encrypt what leaves the tree
  (`make backup`) instead of tightening the tree.
- **Every guest `fsync` costs ~135KB of Mac SSD writes, whatever it commits.**
  OrbStack honours a guest `fsync()` with a real durable barrier — macOS
  `F_FULLFSYNC` — which forces an APFS journal commit. macOS' own `fsync()` does
  not: it only pushes to the drive cache. Measured, 2000 x 4KB files
  created+fsynced+deleted: 7MB natively, 7MB from the VM with no fsync, **271MB**
  from the VM with fsync, **281MB** natively with `F_FULLFSYNC`. So the tax is
  per-fsync, not per-byte and not virtiofs bandwidth — sequential writes run 1:1
  — and moving data into the VM's own disk image makes it WORSE (598MB), because
  the guest filesystem's journal adds its own barriers on top.

  This is why the storage-side tuning in this tree is all about issuing fewer
  fsyncs, never about writing fewer bytes: `inmemoryDataFlushInterval` on the
  three Victoria stores, `--appendfsync no` on OpenPanel's Redis. A store that
  writes 15MB/day can cost tens of GB/day of SSD if it fsyncs on a 5s timer.
  Upstream tracks the symptom in orbstack/orbstack#1332, open and undiagnosed;
  there is no OrbStack setting for it, so the workload is the only lever.

## Conventions that are not obvious from the tree

- **One directory per app** under `/var/lib/k8s-data`. A multi-component app
  nests its volumes (`librechat/{mongo,uploads}`,
  `openpanel/{postgres,clickhouse,redis}`) via `storage.<key>.pathSuffix`.
- **`ansible/inventories/group_vars/all.yml` is the config surface.** It sits
  next to the *inventory files*, which is the only place Ansible auto-loads it
  from here — a top-level `ansible/group_vars/` was adjacent to neither
  inventory nor playbook and was silently never loaded. Role `defaults/` is for
  values a human should not touch; `k3s_version` is single-sourced in
  group_vars and deliberately absent from `roles/k3s/defaults/` (which is why
  that file does not exist).
- **One helmfile, applied in three passes.** Every platform release lives in
  `kubernetes/helmfile.yaml.gotmpl` and nowhere else — Ansible holds no chart
  name, no version and no values path. `roles/platform` applies it three times
  because two things must happen in the middle: the `InfisicalSecret`s need the
  operator's CRD (so `tier: bootstrap` goes first), and the hand-written
  workloads in `raw-manifests.yml` mount PVCs the `<svc>-platform` releases
  create (so `tier: platform` goes second). The last pass carries **no
  selector**, which is what guarantees a release with no tier label still
  deploys. A `--tags telemetry`-style redeploy of one service is now
  `helmfile apply -l name=<release>`, not an Ansible tag.
- **The `.gotmpl` suffix is load-bearing.** helmfile 1.x renders the state file
  as a Go template only when the extension says so, and this one resolves
  `NODE_NAME` (the hostPath PV's nodeAffinity) and `GRAFANA_ADMIN_PASSWORD`
  from the environment at parse time. Rename it to `helmfile.yaml` and every
  `requiredEnv` becomes a YAML syntax error.
- **Namespaces**: `prod-<app>` / `next-<app>` / `staging-<app>` for apps,
  `platform-*` for infrastructure. All platform namespaces are declared in
  `kubernetes/cluster/namespaces.yaml` — never `kubectl create ns`.
- **DNS has exactly three owners, and only one of them is this repo.**
  *Private* = `<svc>.internal.jterrazz.com`, covered by the single `*.internal`
  wildcard in `pulumi/src/dns.ts` — adding one needs **no DNS change at all**,
  only a line in `private_hostnames` (group_vars) so in-cluster lookups skip the
  public CNAME chain. *Public* = the Cloudflare Zero Trust tunnel owns the
  record; add a Public Hostname in its UI, nothing lands in this repo. *The
  machine* = the wildcard itself, which is the one DNS fact Pulumi legitimately
  owns. Never add a per-service record to `dns.ts`; that is what made the
  hostname list live in two files with a CI assertion holding them together.
- **New public zone** = add it to both ClusterIssuers in
  `kubernetes/services/cert-manager/issuers.yaml`, add a Public Hostname in the
  Cloudflare Zero Trust tunnel UI (which auto-creates the CNAME), and set the
  zone's SSL mode to Full (Strict).
- **fail2ban and auditd are absent on purpose.** fail2ban guarded a public SSH
  port that does not exist (there is no public inbound path at all), and auditd
  needs `CAP_AUDIT_*` which the OrbStack hypervisor withholds. Do not "restore"
  them.
- **`deploy-platform.yaml` never runs the host layer.** The base/security/
  resolved/tailscale/k3s roles restart sshd or tailscaled and would kill the
  runner's own SSH session. Anything below the platform layer is `make deploy`
  from the laptop. Pulumi is out of scope for CI entirely — it drives `orbctl`
  on the Mac.

## Config discipline

**The best comment is a deleted line of config.** Apply these mechanically when
editing any values file, manifest, or template in this repo.

1. **Check the upstream default BEFORE writing a comment that justifies a value**
   (`helm show values <chart> --version <pin>`, the binary's `--help`, the
   Kubernetes API defaults). If your value **equals** the default, delete the
   value *and* the comment — a restated default is a line that reads as a
   decision and is not one. If it **differs**, keep it and write **one sentence**
   naming the default and the reason for diverging.
2. **A knob nothing sets is dead weight, and its comment is pure cost.** Grep
   before adding a values key; if no consumer sets it, it does not belong in the
   chart. And never default the same key in two places — a `| default` in a
   template whose key already has a value in `values.yaml` can never fire, so
   `values.yaml` owns defaults and templates read them plainly.
3. **Prefer the default when it fails faster, uses less memory, or is one fewer
   moving part**, and state the improvement in numbers. (A `failureThreshold: 30`
   on the k8s default 10s period buys the same 300s of grace as `5s × 60` at half
   the probe traffic and one fewer override.)
4. **A comment's subject must be a live invariant, not history.** The keep-bar is
   one of: a cross-resource invariant (this name must match that one), a
   data-destroying constraint (change this and the volume is orphaned), or a
   silent-failure trap (the wrong spelling applies cleanly and does nothing).
   Delete past measurements, incident narratives, dated right-sizing diaries,
   completed-migration tables and verification transcripts — git history keeps
   them, and a comment nobody can re-verify becomes a comment nobody trusts.
5. **Say it once.** One file owns each rationale and the others point at it. When
   you delete a value, `grep` the tree for comments that reference it — a
   dangling "see the note in X" is worse than no note at all.

## Deployed services

Each has its own README with versions, data paths, secrets and gotchas:

- **LibreChat** — private AI chat at `chat.internal.jterrazz.com`, `platform-ai`.
  [README](kubernetes/services/librechat/README.md)
- **OpenPanel** — product analytics; private dashboard at
  `openpanel.internal.jterrazz.com`, public ingest at `analytics.jterrazz.com/api/track`,
  `platform-analytics`. [README](kubernetes/services/openpanel/README.md)
- **cloudflared** — the public-traffic tunnel, `platform-networking`.
  [README](kubernetes/services/cloudflared/README.md)
- Telemetry (`platform-telemetry`): the **VictoriaMetrics family** —
  VictoriaMetrics (metrics, 30d, scrapes via `-promscrape.config` *and* receives
  Prometheus remote-write), VictoriaLogs (logs, 90d), VictoriaTraces (traces,
  720h, **pre-1.0 on purpose**) — plus Grafana, kube-state-metrics,
  node-exporter and the OTel Collector. Prometheus, Loki, Tempo and Alloy are
  **gone**; do not resurrect them when editing lists. The collector does double
  duty: OTLP from instrumented apps *and* a `filelog` receiver tailing
  `/var/log/pods` for every pod's stdout, which is the job Alloy used to do — so
  `kubectl logs` is never the only copy. Grafana's datasource UIDs are still
  `prometheus` / `loki` / `tempo` (dashboards and app-shipped alert rules
  reference them); only the names, URLs and two of the types changed.
- **Registry** — `registry.internal.jterrazz.com`, `platform-registry`. Its IngressRoute
  uses `cluster-internal-access` because containerd's hairpin pull is sourced
  from a pod-CIDR/node address, not a tailnet IP.
- **gateway-intelligence** (an app-chart workload, deployed by its own repo)
  runs CLIProxyAPI with `api-keys: []`, which leaves its auth middleware
  allowing everything. The security boundary is **NetworkPolicy + private-only
  ingress**, not a bearer token; consumers pass the non-secret placeholder
  `gateway-noauth` only because the OpenAI/Anthropic SDKs require a non-empty
  string. There is no gateway API key in Infisical.

n8n and Portainer were **removed**. Their `/var/lib/k8s-data` directories are
kept (PVs were `Retain`); everything else — namespace, CNAME, manifests — is
gone. Do not resurrect them by accident when editing lists.

## App repos

Apps are deployed by `jterrazz/jterrazz-actions`, not from here. This repo only
owns the chart they render through. Working on an app repo:

- `application.yaml` schema, merge semantics, `platformServices`, storage:
  [kubernetes/charts/app/README.md](kubernetes/charts/app/README.md).
- A repo deploying for the first time needs `INFISICAL_CLIENT_ID` /
  `INFISICAL_CLIENT_SECRET` set on it — see
  [docs/RUNBOOK.md](docs/RUNBOOK.md#github-secrets-every-app-repo).
- Every app repo must expose `make build`, `make lint`, `make test` — the
  universal CI interface, regardless of toolchain.
- `tag:` is mandatory on every environment. Without it the workflow takes a
  legacy branch that deploys "staging" and leaves prod silently stale.
- Node/Next.js packaging traps (pnpm `--ignore-scripts`, `output: 'standalone'`,
  `mkdir -p public`) live with the shared workflows in `jterrazz-actions`.
- Renaming an app creates a *new* Helm release; the old one keeps running.
  `helm uninstall <env>-<old> -n <env>-<old> && kubectl delete ns <env>-<old>`.
