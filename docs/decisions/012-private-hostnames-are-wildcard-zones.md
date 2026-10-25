# ADR-012: Private hostnames are wildcard zones, answered in-cluster by CoreDNS

**Status:** Accepted
**Date:** 2026-08-30

Written 2026-10-24 from the comments in `group_vars` and
`src/ansible/roles/platform/tasks/{coredns,dns-records}.yml` that this record
replaces. The records moved from Pulumi to the platform deploy with Pulumi's
deletion (2026-08-30); the `*.staging` zone was added on 2026-10-24
(9d03e09).

Revised 2026-10-25: CoreDNS answers the private zones with a `template`, and
the `private_hostnames` list is gone.

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
  address; the route's entrypoint, `websecure`, is the enforcement, and
  being unproxied is what lets a two-label name carry cert-manager's
  certificate.
- **`dns_records` holds only what no other owner creates**: the two wildcards
  and `tunnel`, the tunnel's alias (see [ADR-026](026-a-public-route-is-published-by-its-ingressroute.md)).
  Every public host's record is external-dns's and every ACME record
  cert-manager's. The platform deploy converges them on every run with
  `CLOUDFLARE_RECORDS_TOKEN`; `solo: true` makes a changed
  target replace the old record; the record `comment` names its owner for
  whoever opens the Cloudflare dashboard (the Pulumi-era records still
  claimed Pulumi years after). Both targets are derived, so a re-created VM
  or tunnel needs no edit.
- **CoreDNS answers the private zones itself.** Pods cannot follow the public
  CNAME into `*.ts.net`, so the `coredns-custom` ConfigMap holds a
  `jterrazz.com` server block whose `template` plugin answers every name one
  label under `internal` or `staging` with the node's tailnet IP, and AAAA
  with no record; everything else falls through to public DNS. It matches
  the zones, as the public wildcards do, so no hostname is listed anywhere.
  An explicit list (`private_hostnames`, rendered into a `hosts` block) stood
  here until 2026-10-25, on the belief that k3s' CoreDNS lacked `template`;
  its 1.14.7 build has it. CoreDNS reads the file only on restart, so the
  handler is flushed at once: everything after needs the answers.
- **A pod that fetches its own public URL** cannot hairpin to the node's
  ServiceLB. That case once had `private_hostnames_via_traefik`, mapping a
  name to Traefik's ClusterIP; it was deleted on 2026-10-25, empty since
  OpenPanel stopped needing it (2026-09-19). Its next user restores it with
  the ClusterIP looked up at deploy time, and admits its namespace in
  `allow-traefik-ingress`.
- **The deploy stops before an empty tailnet IP** reaches the template: an A
  answer with no address takes cluster DNS down.

## Consequences

- A new private service is `public: false` on its route, under one of the
  two zones, and nothing in this repository.
- `dns_records` must never grow into a per-service list; that is what made the
  hostname list live in two files.
- DNS has exactly three owners, written down in
  [Develop](../guides/develop.md#dns-has-exactly-three-owners).
