# ADR-012: Private hostnames are wildcard zones, answered in-cluster by CoreDNS

**Status:** Accepted
**Date:** 2026-08-30

Written 2026-10-24 from the comments in `group_vars` and
`src/ansible/roles/platform/tasks/{coredns,dns-records}.yml` that this record
replaces. The records moved from Pulumi to the platform deploy with Pulumi's
deletion (2026-08-30); the `*.staging` zone was added on 2026-10-24
(9d03e09).

## Context

Private services (the registry, Grafana, OpenPanel's dashboard, private app
routes) are reached over the tailnet at `<svc>.internal.jterrazz.com`. Each
name used to be its own public record pointing at the node's MagicDNS name,
listed once for DNS and once for CoreDNS, with a CI assertion holding the two
lists together. Inside the cluster a second problem appears: CoreDNS does not
chase a CNAME from the public zone into the `*.ts.net` tailnet zone, so a
pod's lookup NXDOMAINs, which is how containerd fails to pull from the
registry.

## Decision

- **One wildcard record per private zone**, never a per-service record:
  `*.internal` and `*.staging` (staging environments live in their own
  tailnet-only zone, so staging is never reachable from the internet). Both
  are DNS-only CNAMEs to the node's tailnet name, which resolve to a 100.x
  address; the route's `private-access` allow-list is the enforcement, and
  being unproxied is what lets a two-label name carry cert-manager's
  certificate.
- **`dns_records` holds only what no other owner creates**: the two wildcards
  and `analytics` (see [the tunnel record](002-public-traffic-enters-through-a-cloudflare-tunnel.md)).
  Every other public record belongs to a tunnel Public Hostname and every
  ACME record to cert-manager. The platform deploy converges them on every
  run with the token cert-manager already holds; `solo: true` makes a changed
  target replace the old record; the record `comment` names its owner for
  whoever opens the Cloudflare dashboard (the Pulumi-era records still
  claimed Pulumi years after). Both targets are derived, so a re-created VM
  or tunnel needs no edit.
- **CoreDNS answers private names itself.** `private_hostnames` renders into
  the `coredns-custom` ConfigMap as a `jterrazz.com` server block whose
  `hosts` plugin maps each name to the node's tailnet IP; everything else
  falls through to public DNS. It is an explicit list because `hosts` matches
  exact names only, and k3s' CoreDNS build has no `template` plugin. It is the
  one private-hostname fact the cluster cannot supply (CoreDNS needs it before
  any route exists), so smoke checks it against the live IngressRoutes in
  both directions. CoreDNS reloads it only on restart, so the handler is
  flushed at once: everything after needs the records.
- **`private_hostnames_via_traefik`** maps a name to Traefik's ClusterIP
  instead, for a pod that fetches its own public URL (a pod cannot hairpin to
  the node's ServiceLB). Traefik's ClusterIP is looked up at deploy time, never
  hardcoded. The list is empty since OpenPanel stopped needing it
  (2026-09-19); its next user also needs its namespace admitted by
  `allow-traefik-ingress`.
- **The deploy stops before an empty tailnet IP** reaches the template: a
  one-field hosts entry crashloops CoreDNS.

## Consequences

- A new private service is one line in `private_hostnames` and
  `public: false` on its route, and no DNS change at all.
- `dns_records` must never grow into a per-service list; that is what made the
  hostname list live in two files.
- DNS has exactly three owners, written down in
  [Develop](../guides/develop.md#dns-has-exactly-three-owners).
