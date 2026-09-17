# Developing

How a change to this tree is made: what to run before a pull request, the rules
for editing any values file, and the conventions the layout implies but does not
state. What the system IS is [01-architecture.md](01-architecture.md); what
proves a change is [03-testing.md](03-testing.md); what to type when something
is down is [04-operating.md](04-operating.md).

## Before you commit

`make check` (alias `make lint`, the name every app repo's CI uses) runs what CI
runs on the tree: shellcheck, python syntax, the cross-file sync assertions,
ansible-lint, helm lint and unittest, actionlint. What each one proves, and what
none of them can, is [03-testing.md](03-testing.md).

A change to a chart template also needs its `version:` bumped in that chart's
`Chart.yaml`. The app chart is consumed unversioned and both publish guards skip
rather than overwrite, so a forgotten bump ships nothing, silently — the pair
and its consequences are in
[07-hand-synced-pairs.md](07-hand-synced-pairs.md).

## Editing config

The best comment is a deleted line of config. Apply these five rules
mechanically when editing any values file, manifest or template in this repo.

1. **Check the upstream default before writing a comment that justifies a
   value** (`helm show values <chart> --version <pin>`, the binary's `--help`,
   the Kubernetes API defaults). If your value equals the default, delete the
   value and the comment — a restated default is a line that reads as a
   decision and is not one. If it differs, keep it and write one sentence
   naming the default and the reason for diverging.
2. **A knob nothing sets is dead weight, and its comment is pure cost.** Grep
   before adding a values key; if no consumer sets it, it does not belong in
   the chart. Never default the same key in two places either — a `| default`
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
   Delete past measurements, incident narratives, dated right-sizing diaries,
   completed-migration tables and verification transcripts — git history keeps
   them, and a comment nobody can re-verify becomes a comment nobody trusts.
5. **Say it once.** One file owns each rationale and the others point at it.
   When you delete a value, grep the tree for comments that reference it: a
   dangling "see the note in X" is worse than no note at all.

## Storage and configuration

- **One directory per app** under `/var/lib/k8s-data`. A multi-component app
  nests its volumes (`librechat/{mongo,uploads}`,
  `openpanel/{postgres,clickhouse,redis}`) through `storage.<key>.pathSuffix`.
- **`ansible/inventories/group_vars/all.yml` is the config surface.** It sits
  next to the inventory files, which is the only place Ansible auto-loads it
  from here — a top-level `ansible/group_vars/` was adjacent to neither
  inventory nor playbook and was silently never loaded. Role `defaults/` is for
  values a human should not touch; `k3s_version` is single-sourced in
  group_vars and deliberately absent from `roles/k3s/defaults/`, which is why
  that file does not exist.
- **Namespaces** are `prod-<app>` / `next-<app>` / `staging-<app>` for apps and
  `platform-*` for infrastructure. All platform namespaces are declared in
  `kubernetes/cluster/namespaces.yaml` — never `kubectl create ns`.

## The VM is built one way

- **`orb create debian` gives you bookworm.** Debian is the one distro where
  OrbStack's bare image name resolves to the previous stable, so `vm_up` in
  `scripts/deploy.sh` spells out `debian:trixie`. Never drop the tag — every
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
  [04-operating.md](04-operating.md#dns-on-the-vm).

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
  deploy` from the laptop — creating the VM most of all, since that is `orbctl`
  on the Mac, which no runner has.

## Workloads

- **A workload is an app-chart release or an upstream chart.** The only raw
  Deployment left is cloudflared, and it is an exception on purpose:
  `hostNetwork: true` (the CNI bridge mangles its tunnel handshake — see
  [Networking](#networking)) plus `dnsPolicy: ClusterFirstWithHostNet`,
  neither of which the app chart expresses, for the one workload in the cluster
  that needs them. Its `cloudflared-platform` release still carries the
  tunnel-token InfisicalSecret, so the manifest is a Deployment and nothing
  else. Everything that used to sit beside it — OpenPanel's six workloads,
  LibreChat's MongoDB, the registry — now renders through `charts/app`, which is
  why that chart grew `command`/`args`, an exec/tcp probe, `storage.claimName`,
  `servicePort` and `network.isolated`. Reach for a new raw manifest only when
  the app chart genuinely cannot express the thing, and say why in this list
  when you do.
- **Immutable fields mean delete-and-recreate**: Deployment selectors, PV
  `hostPath.type`, PVC `spec.selector`. Changing a `pathSuffix` or a PV name in
  a `service.yaml` moves live data — the current paths are byte-identical to
  what the pre-chart manifests produced, on purpose. The Helm release names
  `<x>-platform` are frozen for the same class of reason: the chart behind them
  is `platform-service`, but a renamed release is a new release, and the old one
  keeps the hostPath PV it bound.
- **Smoke and `redeploy-apps` discover their targets from the cluster; the
  expectations are annotations the charts stamp.** `scripts/smoke.sh` lists
  every IngressRoute and probes what its
  `smoke.jterrazz.com/{path,expect,method,location,probe}` annotations say;
  `scripts/trigger-app-deploys.sh` reads `app.jterrazz.com/repository` off every
  app Deployment. Neither holds a list of hostnames, status codes or repos, and
  `assert-sync.py` no longer needs a check to hold two such lists together. Add
  a surface and it is probed with no edit here; the contract is
  `kubernetes/charts/common/templates/_smoke.tpl`. Two consequences: an
  unannotated route is probed with a `GET / -> 200` fallback and named in the
  output, which means an app has not redeployed onto the current chart rather
  than that it is uninteresting; and a repave leaves nothing to discover, hence
  `--dry-run > file` before and `--from file` after, in
  [the repave sequence](04-operating.md#repaving-the-cluster).

## Networking

- **cloudflared must run `hostNetwork: true`** on this target. The CNI bridge
  mangles outbound TCP/7844 to the Cloudflare edge and the tunnel handshake gets
  RSTed, while plain `curl` from the same pod IP works fine. `--protocol http2`
  is set for the same class of reason: OrbStack's NAT eats outbound UDP/443.
- **A kube-system NetworkPolicy must allow klipper-lb explicitly.** The svclb
  pods receive the node's own address after DNAT, so `allow-same-namespace`
  never covers them. Miss it and public traffic keeps working (cloudflared dials
  Traefik's ClusterIP) while every tailnet client, CI included, gets
  `connection refused` on 443.
- **Never chain `private-access` and `cluster-internal-access`.** Traefik ANDs
  chained ipAllowLists, so chaining allows strictly less, not more. The second
  is a strict superset of the first; a route picks one.
- **buildkit needs `network=host` in CI.** `jterrazz-actions/actions/docker-build`
  sets it so buildkit sees the runner's Tailscale resolver; without it
  `docker push registry.internal.jterrazz.com/…` NXDOMAINs on the public CNAME
  chain.

## The fsync tax

**Every guest `fsync` is a macOS `F_FULLFSYNC` on the Mac SSD, and there are
two paths with different levers.** OrbStack honours a guest `fsync()` with a
real durable barrier, an APFS journal commit, about 135KB of SSD writes each,
whatever it commits; macOS' own `fsync()` does not, it only pushes to the drive
cache. So the tax is per-fsync, not per-byte — sequential writes run 1:1 — and
every storage-side tuning in this tree is about issuing fewer fsyncs, never
fewer bytes. Upstream tracks the symptom in orbstack/orbstack#1332, open and
undiagnosed; there is no OrbStack setting for it.

- **virtiofs** — `/var/lib/k8s-data`, a symlink into the Mac home, so every PV.
  The fsync is a FUSE request the guest cannot suppress, and the workload is
  the only lever: `inmemoryDataFlushInterval` on the three Victoria stores,
  `--appendfsync no` on OpenPanel's Redis. A store that writes 15MB/day can
  cost tens of GB/day of SSD if it fsyncs on a 5s timer. `findmnt` on the
  symlink prints nothing; `readlink -f` first.
- **The VM disk** — `/dev/vdb`, btrfs: k3s' kine SQLite, containerd,
  `/var/log/pods`. The fsync is a virtio-blk FLUSH, and
  `queue/write_cache=write through` makes the block layer stop sending them
  (300 fsyncs: 99MB → 0MB). `roles/base` installs
  `virtio-blk-write-through.service` for that, re-applied at every boot
  because the attribute is runtime-only. Two things to know: OrbStack runs ONE
  Linux VM and every "machine" plus Docker is a container in it on the same
  `vdb`, so the setting is OrbStack-wide; and the writes still land in the
  Mac's page cache, so only a macOS panic or hard power-off can lose the last
  seconds — the contract a native macOS `fsync()` gives every Mac app. It does
  nothing for virtiofs (verified), so it is not a reason to skip the workload
  tuning above.

Moving `k8s-data` onto `vdb` would make its fsyncs free too, but the Mac dir
is what lets the data survive `make destroy`; that trade is a decision, not a
tuning.

## DNS has exactly three owners, and none of them is this repo's code

- **Private** — `<svc>.internal.jterrazz.com`, covered by the single
  `*.internal` wildcard CNAME. Adding one needs no DNS change at all, only a
  line in `private_hostnames` (group_vars) so in-cluster lookups skip the public
  CNAME chain.
- **Public** — the Cloudflare Zero Trust tunnel owns the record. Add a Public
  Hostname in its UI; nothing lands in this repo.
- **The machine** — two records made by hand in the Cloudflare dashboard and
  written down in [04-operating.md](04-operating.md#dns-records-set-once-survive-everything):
  the `*.internal` wildcard, and `analytics`, which is the exception to "the
  tunnel owns every public record" because its route is a Public Hostname but
  its record is manual, so deleting it falls back to nothing.

Both hand-made records are set once and survive every repave: the VM keeps its
hostname, the tunnel keeps its id, and nothing a deploy runs ever touches them.
Never grow that pair into a per-service list — that is what made the hostname
list live in two files with a CI assertion holding them together.

A new public zone is three steps: add it to both ClusterIssuers in
`kubernetes/services/cert-manager/issuers.yaml`, add a Public Hostname in the
Cloudflare Zero Trust tunnel UI (which auto-creates the CNAME), and set the
zone's SSL mode to Full (Strict).

## Absent on purpose

fail2ban and auditd are not installed, and that is a decision, not an omission.
fail2ban guarded a public SSH port that does not exist — there is no public
inbound path at all — and auditd needs `CAP_AUDIT_*`, which the OrbStack
hypervisor withholds. Do not restore them.
