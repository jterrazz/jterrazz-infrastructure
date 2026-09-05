# Conventions that are not obvious from the tree

Rules the layout implies but does not state. Each one has a consequence
attached; that is why it is written down.

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
  [07-gotchas.md](07-gotchas.md)) plus `dnsPolicy: ClusterFirstWithHostNet`,
  neither of which the app chart expresses, for the one workload in the cluster
  that needs them. Its `cloudflared-platform` release still carries the
  tunnel-token InfisicalSecret, so the manifest is a Deployment and nothing
  else. Everything that used to sit beside it — OpenPanel's six workloads,
  LibreChat's MongoDB, the registry — now renders through `charts/app`, which is
  why that chart grew `command`/`args`, an exec/tcp probe, `storage.claimName`,
  `servicePort` and `network.isolated`. Reach for a new raw manifest only when
  the app chart genuinely cannot express the thing, and say why in this list
  when you do.
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
  `--dry-run > file` before and `--from file` after, in the runbook's repave
  sequence.

## DNS has exactly three owners, and none of them is this repo's code

- **Private** — `<svc>.internal.jterrazz.com`, covered by the single
  `*.internal` wildcard CNAME. Adding one needs no DNS change at all, only a
  line in `private_hostnames` (group_vars) so in-cluster lookups skip the public
  CNAME chain.
- **Public** — the Cloudflare Zero Trust tunnel owns the record. Add a Public
  Hostname in its UI; nothing lands in this repo.
- **The machine** — two records made by hand in the Cloudflare dashboard and
  written down in [09-runbook.md](09-runbook.md#dns-records-set-once-survive-everything):
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
