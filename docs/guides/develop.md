# Developing

How a change to this tree is made: what it owes before a commit, the rules for
editing any values file, and the conventions the layout implies but does not
state. What the system is lives in [Architecture](../concepts/architecture.md),
what proves a change in [Test](test.md), what to type when something is down
in [Operate](operate.md).

## Before you commit

`make check` (alias `make lint`) runs what CI runs on the tree: shellcheck,
ansible-lint, helm lint and helm-unittest on the charts, actionlint, the
content check (`make check-docs`) and the specs project's own check
(`make check-specs`). What each proves, and what CI adds, is [Test](test.md).

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
   which `make check-docs` checks: `invariant:` (this must match that), `hazard:`
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

- **`src/ansible/inventories/group_vars/all/` is the config surface**, one
  file per concern (`versions`, `k3s`, `dns`, `secrets`), and it must stay
  beside the inventories, the only place Ansible loads it from.
  Role `defaults/` hold what nobody should touch (`k3s_data_dir`,
  `infisical_api`); a knob, such as `k3s_version`, lives in group_vars alone.
- **A role is one responsibility against one system.** The host play is
  `base`, `security`, `resolved`, `tailscale`, `k3s`; the platform play is
  `cluster` (the objects of no release and CoreDNS), `cloudflare` (the records
  nothing else creates, from the controller), `helm` (the node's tools),
  `releases` (every helmfile pass) and `publish` (the app chart). Each role's
  name is its tag.
- **One directory per app** under `/var/lib/k8s-data`; a multi-component
  service nests its volumes (`openpanel/{postgres,clickhouse,redis}`).
- **A new name follows the owner**: `platform-<capability>` for the platform,
  `<brand>-<role>` for an app, and the app's one name everywhere
  ([Architecture](../concepts/architecture.md#names)).
- **Immutable fields mean delete and recreate**: a Deployment selector, a PV's
  `hostPath.type`, a binding's `roleRef`. A changed `pathSuffix`, PV name or
  `<svc>-platform` release name moves or orphans live data.
- **One helmfile, four passes.** Every platform release is declared in
  `src/kubernetes/helmfile.yaml.gotmpl` and nowhere else; its `.gotmpl` suffix
  is what renders its `requiredEnv` calls. The play applies it four times:
  `pass: cluster` (the namespaces the bootstrap Secrets land in),
  `pass: operators` (cert-manager and the Infisical operator, whose CRDs the
  rest uses), `pass: claims` (the `<svc>-platform` releases: volumes,
  certificates and Secrets that workloads mount by name), then every release
  ([ADR-009](../decisions/009-one-helmfile-declares-every-platform-release.md)).
  A new release needs no label unless something in an earlier pass reads it.
  One release is redeployed with `helmfile apply -l name=<release>`.
- **CI never runs the host layer**: those roles restart sshd and tailscaled
  under the runner's own session, and creating the VM is `orbctl` on the Mac.
- **A workload is an app-chart release or an upstream chart.** cloudflared,
  the registry and OpenPanel's services are app-chart releases; no workload is
  a raw manifest.
- **The cluster is discovered, never listed.** The platform contract
  (`specs/specs/api`) probes what each IngressRoute's `studio.jterrazz.com/smoke-*`
  annotations say, and `make redeploy-apps` reads `studio.jterrazz.com/repository`
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
  (`studio-actions/actions/build-image`), or the registry's name
  NXDOMAINs on the public CNAME chain.

## DNS has exactly three owners

- **Private**: one wildcard per private zone, `*.internal.jterrazz.com` for
  products and platform services (`console.internal`, `grafana.internal`) and
  `*.staging.jterrazz.com` for staging environments. A new private host needs
  no change here, only `public: false` on its route: CoreDNS answers both
  zones in-cluster, the public wildcards outside.
- **Public**: external-dns owns each public host's record. A route with
  `public: true` sits on Traefik's `tunnel` entrypoint and carries the
  annotation external-dns reads, which writes a proxied CNAME to
  `tunnel.jterrazz.com` within seconds of the deploy; nothing lands here
  ([ADR-026](../decisions/026-a-public-route-is-published-by-its-ingressroute.md)).
- **The platform deploy**: `dns_records` in group_vars, the three records
  nothing else creates, converged on every platform deploy (tag `cloudflare`)
  with `CLOUDFLARE_RECORDS_TOKEN`, each name held to exactly that one record,
  so a record edited in the dashboard comes back. It never grows into a
  per-service list
  ([ADR-012](../decisions/012-private-hostnames-are-wildcard-zones.md)).

| Name         | Type  | Content                                                      | Proxied |
| ------------ | ----- | ------------------------------------------------------------ | ------- |
| `*.internal` | CNAME | the node's tailnet name (`tailscale_dns_hostname`)           | no      |
| `*.staging`  | CNAME | the node's tailnet name                                      | no      |
| `tunnel`     | CNAME | `<tunnel id>.cfargotunnel.com`, the tunnel token's `t` field | yes     |

The wildcards only make a name resolve to a `100.x` address; the route's
entrypoint is the enforcement ([Security](../concepts/security.md)): a private
route sits on `websecure`, which cloudflared cannot reach, so a staging host
marked `public: true` is the mistake to look for, and the platform contract
fails on it. A wildcard matches one label: `svc.internal`, never
`a.b.internal`. Why each record exists is
[ADR-012](../decisions/012-private-hostnames-are-wildcard-zones.md).

Removing an entry from `dns_records` does not delete its record, and
external-dns runs upsert-only, so a public route removed leaves its CNAME:
delete either from the dashboard.

```bash
dig +short grafana.internal.jterrazz.com    # the tailnet name
dig +short signews.staging.jterrazz.com     # the tailnet name
dig +short analytics.jterrazz.com           # Cloudflare addresses
```

A new public zone is two steps: add it to `CLOUDFLARE_RECORDS_TOKEN`'s zones,
and set its SSL mode to Full (Strict). Nothing here issues it a certificate:
its TLS ends at the Cloudflare edge.
