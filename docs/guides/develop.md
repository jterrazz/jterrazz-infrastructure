# Developing

How a change to this tree is made: what to run before a pull request, the rules
for editing any values file, and the conventions the layout implies but does not
state. What the system IS is [Architecture](../concepts/architecture.md); what
proves a change is [Test](test.md); what to type when something
is down is [Operate](operate.md).

## Before you commit

`make check` (alias `make lint`, the name every app repo's CI uses) runs what CI
runs on the tree: shellcheck, python syntax, the cross-file sync assertions,
ansible-lint, helm lint and unittest, actionlint. What each one proves, and what
none of them can, is [Test](test.md).

A change to a chart template also needs its `version:` bumped in that chart's
`Chart.yaml`. The app chart is consumed unversioned and both publish guards skip
rather than overwrite, so a forgotten bump ships nothing, silently; the pair
and its consequences are in
[Hand-synced pairs](../reference/hand-synced-pairs.md).

## Editing config

The best comment is a deleted line of config. Apply these five rules
mechanically when editing any values file, manifest or template in this repo.

1. **Check the upstream default before writing a comment that justifies a
   value** (`helm show values <chart> --version <pin>`, the binary's `--help`,
   the Kubernetes API defaults). If your value equals the default, delete the
   value and the comment: a restated default is a line that reads as a
   decision and is not one. If it differs, keep it and write one sentence
   naming the default and the reason for diverging.
2. **A knob nothing sets is dead weight, and its comment is pure cost.** Grep
   before adding a values key; if no consumer sets it, it does not belong in
   the chart. Never default the same key in two places either: a `| default`
   in a template whose key already has a value in `values.yaml` can never fire,
   so `values.yaml` owns defaults and templates read them plainly.
3. **Prefer the default when it fails faster, uses less memory, or is one fewer
   moving part**, and state the improvement in numbers. A `failureThreshold: 30`
   on the Kubernetes default 10s period buys the same 300s of grace as
   `5s × 60`, at half the probe traffic and one fewer override.
4. **A comment's subject must be a live invariant, not history.** The keep-bar
   is one of three: a cross-resource invariant (this name must match that one),
   a data-destroying constraint (change this and the volume is orphaned), or a
   silent-failure trap (the wrong spelling applies cleanly and does nothing).
   Past measurements, incident narratives, alternatives rejected and
   verification transcripts belong in a decision record under
   [decisions/](../decisions/), which the comment links in one line (`#
   hazard: ...; docs/decisions/NNN-....md`); a comment nobody can re-verify
   becomes a comment nobody trusts. Every kept comment opens with its kind:
   `invariant:`, `hazard:`, `outside:` or `value:`, which `make docs` checks.
5. **Say it once.** One file owns each rationale and the others point at it.
   When you delete a value, grep the tree for comments that reference it: a
   dangling "see the note in X" is worse than no note at all.

## Storage and configuration

- **One directory per app** under `/var/lib/k8s-data`. A multi-component app
  nests its volumes (`openpanel/{postgres,clickhouse,redis}`) through
  `storage.<key>.pathSuffix`.
- **`ansible/inventories/group_vars/all.yml` is the config surface.** It sits
  next to the inventory files, which is the only place Ansible auto-loads it
  from here: a top-level `ansible/group_vars/` was adjacent to neither
  inventory nor playbook and was silently never loaded. Role `defaults/` is for
  values a human should not touch; `k3s_version` is single-sourced in
  group_vars and deliberately absent from `roles/k3s/defaults/`, which is why
  that file does not exist.
- **Namespaces** are `prod-<app>` / `next-<app>` / `staging-<app>` for apps and
  `platform-*` for infrastructure. All platform namespaces are declared in
  `kubernetes/cluster/namespaces.yaml`, never by `kubectl create ns`.

## The VM is built one way

- **`orb create debian` gives you bookworm.** Debian is the one distro where
  OrbStack's bare image name resolves to the previous stable, so `vm_up` in
  `scripts/deploy.sh` spells out `debian:trixie`. Never drop the tag: every
  Ansible role is Debian-13-native (deb822 repositories, socket-activated
  sshd, systemd-resolved as a separate package).
- **`orbctl create -u root` is broken** since OrbStack 2.2.0: its setup runs
  `usermod --uid 501 root`, which fails against PID 1. The VM is created with
  the default macOS-named user; Ansible connects as `root@<vm>@orb`.
- **kubelet's resolv-conf is pinned** to `/run/systemd/resolve/resolv.conf` in
  `roles/k3s/templates/config.yaml.j2`. Point it at `/etc/resolv.conf` and
  CoreDNS (which uses `dnsPolicy: Default`) forwards into its own 127.0.0.53
  stub and the loop plugin fatals on startup. The DHCP resolver this works
  around, and how to diagnose it on a live VM, are
  [Operate](operate.md#dns-on-the-vm).

## How the platform layer is applied

- **One helmfile, applied in three passes.** Every platform release lives in
  `kubernetes/helmfile.yaml.gotmpl` and nowhere else; Ansible holds no chart
  name, no version and no values path. `roles/platform` applies it three times
  because two things must happen in the middle: the `InfisicalSecret`s need the
  operator's CRD and cert-manager the Certificate one, so `tier: bootstrap`
  goes first; and cloudflared's raw Deployment mounts a Secret the
  `<svc>-platform` releases declare, so `tier: platform` goes second. The last
  pass carries no selector, which is what guarantees a release with no tier
  label still deploys. Redeploying one service is `helmfile apply -l
  name=<release>`, not an Ansible tag.
- **The `.gotmpl` suffix is load-bearing.** helmfile 1.x renders the state file
  as a Go template only when the extension says so, and this one resolves
  `NODE_NAME` (the hostPath PV's nodeAffinity) and `GRAFANA_ADMIN_PASSWORD`
  from the environment at parse time. Rename it to `helmfile.yaml` and every
  `requiredEnv` becomes a YAML syntax error.
- **`deploy-platform.yaml` never runs the host layer.** The base, security,
  resolved, tailscale and k3s roles restart sshd or tailscaled and would kill
  the runner's own SSH session. Anything below the platform layer is `make
  deploy` from the laptop, creating the VM most of all, since that is `orbctl`
  on the Mac, which no runner has.

## Workloads

- **A workload is an app-chart release or an upstream chart.** The only raw
  Deployment left is cloudflared, and it is an exception on purpose:
  `hostNetwork: true` (the CNI bridge mangles its tunnel handshake; see
  [Networking](#networking)) plus `dnsPolicy: ClusterFirstWithHostNet`,
  neither of which the app chart expresses, for the one workload in the cluster
  that needs them. Its `cloudflared-platform` release still carries the
  tunnel-token InfisicalSecret, so the manifest is a Deployment and nothing
  else.

  Everything that used to sit beside it (OpenPanel's six workloads,
  the registry) now renders through `charts/app`, which is
  why that chart grew `command`/`args`, an exec/tcp probe, `storage.claimName`,
  `servicePort` and `network.isolated`. Reach for a new raw manifest only when
  the app chart genuinely cannot express the thing, and say why in this list
  when you do.
- **Immutable fields mean delete-and-recreate**: Deployment selectors, PV
  `hostPath.type`, PVC `spec.selector`. Changing a `pathSuffix` or a PV name in
  a `service.yaml` moves live data: the current paths are byte-identical to
  what the pre-chart manifests produced, on purpose. The Helm release names
  `<x>-platform` are frozen for the same class of reason: the chart behind them
  is `platform-service`, but a renamed release is a new release, and the old one
  keeps the hostPath PV it bound.
- **Smoke and `redeploy-apps` discover their targets from the cluster; the
  expectations are annotations the charts stamp.** `scripts/smoke.sh` lists
  every IngressRoute and probes what its
  `smoke.jterrazz.com/{path,expect,method,location,probe}` annotations say;
  `scripts/trigger-app-deploys.sh` reads `app.jterrazz.com/repository` off every
  app Deployment. Neither holds a list of hostnames, status codes or repos. Add
  a surface and it is probed with no edit here; the contract is
  `kubernetes/charts/common/templates/_smoke.tpl`.

  Two consequences: an
  unannotated route is probed with a `GET / -> 200` fallback and named in the
  output, which means an app has not redeployed onto the current chart rather
  than that it is uninteresting; and a repave leaves nothing to discover, hence
  `--dry-run > file` before and `--from file` after, in
  [the repave sequence](operate.md#repaving-the-cluster).

## Networking

- **cloudflared must run `hostNetwork: true`** on this target. The CNI bridge
  mangles outbound TCP/7844 to the Cloudflare edge and the tunnel handshake gets
  RSTed, while plain `curl` from the same pod IP works fine. `--protocol http2`
  is set for the same class of reason: OrbStack's NAT eats outbound UDP/443.
- **A kube-system NetworkPolicy must allow klipper-lb explicitly.** The svclb
  pods receive the node's own address after DNAT, so no pod or namespace
  selector ever covers them. Miss it and public traffic keeps working (cloudflared dials
  Traefik's ClusterIP) while every tailnet client, CI included, gets
  `connection refused` on 443.
- **buildkit needs `network=host` in CI.** `jterrazz-actions/actions/docker-build`
  sets it so buildkit sees the runner's Tailscale resolver; without it
  `docker push registry.internal.jterrazz.com/...` NXDOMAINs on the public CNAME
  chain.

## The fsync tax

**Every guest `fsync` is a macOS `F_FULLFSYNC` on the Mac SSD**, so the cost
is per fsync, not per byte, and every storage tuning in this tree issues fewer
fsyncs, never fewer bytes. Two paths, two levers:

- **virtiofs** (`/var/lib/k8s-data`, every PV): the workload is the only
  lever, `inmemoryDataFlushInterval` on the Victoria stores and
  `--appendfsync no` on OpenPanel's Redis. `findmnt` on the symlink prints
  nothing; `readlink -f` first.
- **The VM disk** (`/dev/vdb`: kine, containerd, `/var/log/pods`):
  `virtio-blk-write-through.service` in `roles/base` stops the FLUSHes,
  OrbStack-wide, and does nothing for virtiofs.

The measurements, the durability contract and the open trade (moving
`k8s-data` onto `vdb`) are
[ADR-008](../decisions/008-storage-on-orbstack-spends-fsyncs-not-bytes.md).

## DNS has exactly three owners

- **Private**: `<svc>.internal.jterrazz.com`, covered by the `*.internal`
  wildcard CNAME, and `<app>.staging.jterrazz.com`, covered by `*.staging`: the
  staging environments are tailnet-only, never public. Adding one needs no DNS
  change at all, only a line in `private_hostnames` (group_vars) so in-cluster
  lookups skip the public CNAME chain, and `public: false` on the route.
- **Public**: the Cloudflare Zero Trust tunnel owns the record. Add a Public
  Hostname in its UI; nothing lands in this repo.
- **The platform deploy**: the records nothing else creates, `dns_records` in
  group_vars, converged on every run and written down in
  [Operate](operate.md#dns-records-converged-by-the-platform-deploy): the
  `*.internal` and `*.staging` wildcards, and `analytics`, which is the
  exception to "the tunnel owns every public record" because its route is a
  Public Hostname but its record is not.

Never grow `dns_records` into a per-service list (one wildcard per private zone
is the ceiling); that is what made the hostname list live in two files with a
CI assertion holding them together.

A new public zone is three steps: add it to both ClusterIssuers in
`kubernetes/services/cert-manager/issuers.yaml`, add a Public Hostname in the
Cloudflare Zero Trust tunnel UI (which auto-creates the CNAME), and set the
zone's SSL mode to Full (Strict).

## Absent on purpose

fail2ban and auditd are not installed, and that is a decision, not an omission.
fail2ban guarded a public SSH port that does not exist (there is no public
inbound path at all), and auditd needs `CAP_AUDIT_*`, which the OrbStack
hypervisor withholds. Do not restore them
([ADR-006](../decisions/006-the-host-has-no-public-inbound-path.md)).
