# ADR-002: Public traffic enters through a Cloudflare tunnel, never an open port

**Status:** Accepted
**Date:** 2026-05-10

Written 2026-10-24 from the comments in `src/kubernetes/services/cloudflared/`,
`group_vars` and `roles/platform` that this record replaces (the tunnel
landed in 10ac6e2, before public 80/443 were closed in 6dc3915).

## Context

The cluster runs on an OrbStack VM on a Mac, behind NAT, with no public
address worth exposing; the rented host it replaced had public 80/443 open.
Public sites (the apex zones `jterrazz.com`, `sig.news`, `spwn.sh`, and
subdomains such as `analytics.jterrazz.com`) still need to be served.
OrbStack's network adds two traps for anything dialling out: its NAT eats
outbound UDP/443, and its CNI bridge mangles outbound TCP/7844 to Cloudflare
so that cloudflared's tunnel handshake is RSTed at the edge (`connect:
connection refused`), while `curl` from the same pod IP connects fine.

## Decision

The only public ingress is a remote-managed (token-based) Cloudflare tunnel:
cloudflared dials the edge, and the edge sends traffic back to Traefik's
ClusterIP. Nothing listens on a public address.

- **Routing is per hostname, not by wildcard.** Every public hostname,
  apex or subdomain, has its own Public Hostname rule in the Zero Trust UI
  pointing at `traefik.kube-system.svc.cluster.local:443`; adding one there
  creates its CNAME, and a bare CNAME with no rule 404s. Adding a hostname
  never touches this repo. The one exception is `analytics`, whose route is
  a Public Hostname but whose record is not, so `dns_records` owns it:
  proxied (a `cfargotunnel.com` name resolves only at the edge), targeting
  the tunnel id read from the connector token's `t` field.
- **cloudflared is a raw Deployment**, the one workload the app chart does
  not own: `hostNetwork: true` bypasses the CNI bridge (safe, cloudflared
  listens on nothing), and `dnsPolicy: ClusterFirstWithHostNet` keeps
  cluster DNS. `--protocol http2` runs the tunnel over TCP/443, since QUIC
  dials time out with "no recent network activity". Neither setting should be
  removed without testing the handshake on a fresh VM; both are harmless on a
  target that does not need them.
- **One replica, `Recreate`.** A replica holds four redundant edge
  connections, and Cloudflare fails over to the new pod, so a rolling update
  protects nothing. `/ready` (200 once an edge connection is up) backs both
  probes, so a stuck process restarts.
- **The token is the only secret**, synced by the `cloudflared-platform`
  release into `cloudflared-secrets`, a name the Deployment reads by literal
  string. cloudflared reads it once at startup: a rotation needs a
  `kubectl rollout restart`.

## Consequences

- No inbound port exists on the host, so no firewall rule guards the public
  path; the tunnel token is the credential to protect.
- Because cloudflared runs in the host network, NetworkPolicy never sees its
  traffic; its rules cannot be separated from cert-manager's in
  `platform-networking.yaml`.
- Traefik's peer for public traffic is always a node or cluster address,
  which shapes its `forwardedHeaders.trustedIPs` (see
  [the Traefik record](003-traefiks-service-is-the-tailnet-gate.md)).
- The tunnel accepts up to four connectors, load-balanced, so a second
  cluster with the same token serves at once.
