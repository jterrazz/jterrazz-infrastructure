# Developing

How a change to this tree is made: what it owes before a commit, the rules for
editing any values file, and the conventions the layout implies but does not
state. What the system is lives in [Architecture](../concepts/architecture.md),
what proves a change in [Test](test.md), what to type when something is down
in [Operate](operate.md).

## Before you commit

`make check` (alias `make lint`) runs what CI runs on the tree: shellcheck,
ansible-lint, helm lint and helm-unittest on both charts, actionlint, the
content check (`make docs`) and the specs project's own check
(`make specs-check`). What each proves, and what CI adds, is [Test](test.md).

A change to a chart template that changes what it renders bumps `version:` in
that chart's `Chart.yaml`: apps pull the app chart unversioned and the
publisher never overwrites a version, so a forgotten bump ships nothing,
silently ([Hand-synced pairs](../reference/hand-synced-pairs.md)).

## Editing config

The best comment is a deleted line of config. Apply these rules to every
values file, manifest, template, role and workflow.

1. **Check the upstream default before writing a value** (`helm show values
   <chart> --version <pin>`, the binary's `--help`, the Kubernetes API
   defaults). A value equal to the default is deleted with its comment; one
   that differs keeps one line naming the reason.
2. **A knob nothing sets is dead weight.** Grep before adding a key, and never
   default one key in two places: `values.yaml` owns the defaults and templates
   read them plainly.
3. **Prefer the default when it fails faster, uses less memory or is one fewer
   moving part**, and say the improvement in numbers.
4. **A comment states a live fact the line cannot.** Each opens with its kind,
   which `make docs` checks: `invariant:` (this must match that), `hazard:`
   (change it and something breaks or data moves), `outside:` (a fact of a
   system beyond this tree) or `value:` (why this number). One line where
   possible. History, measurements and alternatives belong in a decision record
   under [decisions/](../decisions/), which the comment names as `(ADR-NNN)`.
5. **Say it once.** The ADR owns the why, the guide the how, the comment the
   line-level hazard. When you delete a value, grep for what pointed at it.

Comments inside a file rendered onto the node (the k3s templates, the nftables
guard, the systemd units) are file content: editing one re-renders the file and
fires its handler, a k3s restart for the k3s templates.

## Conventions the layout implies

- **`src/ansible/inventories/group_vars/all.yml` is the config surface**, and
  it must stay beside the inventories, the only place Ansible loads it from.
  Role `defaults/` hold what nobody should touch; `k3s_version` lives in
  group_vars alone, which is why `roles/k3s` has no defaults file.
- **One directory per app** under `/var/lib/k8s-data`; a multi-component
  service nests its volumes (`openpanel/{postgres,clickhouse,redis}`).
- **Names** follow [ADR-023](../decisions/023-names-follow-the-owner-and-one-name-runs-through-everything.md):
  `platform-<capability>` namespaces, declared in
  `src/kubernetes/cluster/namespaces.yaml`, and `<app>-<env>` namespaces,
  created by the app's own deploy, with `<app>` = `<brand>-<role>` as the one
  name of its release, image, volume, data directory and Infisical folder.
- **Immutable fields mean delete and recreate**: a Deployment selector, a PV's
  `hostPath.type`, a binding's `roleRef`. A changed `pathSuffix`, PV name or
  `<svc>-platform` release name moves or orphans live data.
- **One helmfile, three passes.** Every platform release is declared in
  `src/kubernetes/helmfile.yaml.gotmpl` and nowhere else; its `.gotmpl` suffix
  is what renders its `requiredEnv` calls
  ([ADR-009](../decisions/009-one-helmfile-declares-every-platform-release.md)).
  One release is redeployed with `helmfile apply -l name=<release>`.
- **CI never runs the host layer**: those roles restart sshd and tailscaled
  under the runner's own session, and creating the VM is `orbctl` on the Mac.
- **A workload is an app-chart release or an upstream chart.** A raw manifest
  is the last resort, kept only for what no chart expresses (cloudflared's
  `hostNetwork`).
- **The cluster is discovered, never listed.** The platform contract
  (`specs/specs/api`) probes what each IngressRoute's `smoke.jterrazz.com/*`
  annotations say, and `make redeploy-apps` reads `app.jterrazz.com/repository`
  off the app Deployments
  ([ADR-016](../decisions/016-every-fact-has-one-home.md)). An unannotated route
  is probed with `GET / -> 200` and named `fallback`.

## The VM is built one way

The OrbStack image has quirks a stock server does not: `orb create debian` is
bookworm, `orbctl create -u root` is broken, sshd is absent, the DHCP resolver
drops queries. `deploy.sh` and `roles/{base,resolved}` repair each, and every
OrbStack image change is a review of them
([ADR-004](../decisions/004-one-orbstack-vm-is-the-only-target.md)). Storage
tuning on this host spends fewer fsyncs, never fewer bytes: a guest fsync is a
`F_FULLFSYNC` on the Mac
([ADR-008](../decisions/008-storage-on-orbstack-spends-fsyncs-not-bytes.md)).

## Networking

- **Ports in a NetworkPolicy are pod ports**, and hostNetwork clients match
  only an ipBlock ([ADR-011](../decisions/011-every-namespace-is-default-deny.md)).
- **The kube-system policy must admit klipper-lb**: miss it and public traffic
  works while every tailnet client is refused
  ([ADR-003](../decisions/003-traefiks-service-is-the-tailnet-gate.md)).
- **buildkit runs with `network=host` in app CI**
  (`jterrazz-actions/actions/docker-build`), or the registry's name
  NXDOMAINs on the public CNAME chain.

## DNS has exactly three owners

- **Private**: `<svc>.internal.jterrazz.com` and `<app>.staging.jterrazz.com`,
  covered by one wildcard per zone. A new private host needs no DNS change, only
  a line in `private_hostnames` and `public: false` on its route.
- **Public**: the Cloudflare tunnel's Public Hostnames own the records; add one
  in the Zero Trust dashboard, and nothing lands here.
- **The platform deploy**: `dns_records`, the records nothing else creates
  ([Operate](operate.md#dns-records-converged-by-the-platform-deploy)). It never
  grows into a per-service list
  ([ADR-012](../decisions/012-private-hostnames-are-wildcard-zones.md)).

A new public zone is three steps: add it to both ClusterIssuers in
`src/kubernetes/services/cert-manager/issuers.yaml`, add its Public Hostname in
the tunnel, and set the zone's SSL mode to Full (Strict).
