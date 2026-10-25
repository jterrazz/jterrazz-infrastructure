# ADR-002: Public traffic enters through a Cloudflare tunnel, never an open port

**Status:** Accepted
**Date:** 2026-05-10

Written 2026-10-24 from the comments in `src/kubernetes/services/cloudflared/`,
`group_vars` and `roles/platform` that this record replaces (the tunnel
landed in 10ac6e2, before public 80/443 were closed in 6dc3915).

Revised 2026-10-25: cloudflared is an app-chart release on pod networking, its
token a mounted file, and `platform-networking`'s allowances select cert-manager
alone, so cloudflared's egress is its own release's. Later that day the
per-hostname rules gave way to one catch-all rule to Traefik's `tunnel`
entrypoint, each record now written by external-dns
([ADR-026](026-a-public-route-is-published-by-its-ingressroute.md)).

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
`traefik-tunnel` ClusterIP. Nothing listens on a public address.

- **One catch-all rule, the hostnames on the IngressRoutes.** The tunnel's
  remote config is a single rule to Traefik's `tunnel` entrypoint, which holds
  the public routes alone; each public host's CNAME is external-dns's, read
  off its IngressRoute ([ADR-026](026-a-public-route-is-published-by-its-ingressroute.md)).
  Until 2026-10-25 every hostname was a Public Hostname rule clicked into the
  Zero Trust UI.
- **cloudflared is an app-chart release** (`services/cloudflared/app.yaml`)
  on ordinary pod networking, `isolated` with egress only to the edge and to
  Traefik's pod port. It ran with `hostNetwork` until 2026-10-25 to dodge an
  OrbStack CNI reset of the tunnel handshake; a probe from a plain pod that
  day completed the HTTP/2 handshake, so the host network, the raw manifest
  and the namespace's `privileged` Pod Security level all went.
  The protocol is cloudflared's own choice, QUIC over UDP 7844 with HTTP/2 as
  its fallback: the `--protocol http2` pin, written against a NAT that ate
  UDP/443, went once a pod registered four QUIC connections (2026-10-25).
- **One replica, rolling.** A replica holds four redundant edge connections;
  during a rollout the old and the new connector serve together. `/ready`
  (200 once an edge connection is up) backs both probes.
- **The token is the only secret**, synced by the `cloudflared-platform`
  release into `cloudflared-secrets` and mounted as a file (`--token-file`),
  so it is in no environment variable and no argv. It is read once at start:
  a rotation needs a `kubectl rollout restart`.

## Consequences

- No inbound port exists on the host, so no firewall rule guards the public
  path; the tunnel token is the credential to protect.
- cloudflared's egress is its release's own NetworkPolicy, and
  `allow-traefik-ingress` admits it to the tunnel entrypoint alone.
- Traefik's peer for public traffic is always a node or cluster address,
  which shapes its `forwardedHeaders.trustedIPs` (see
  [the Traefik record](003-traefiks-service-is-the-tailnet-gate.md)).
- The tunnel accepts up to four connectors, load-balanced, so a second
  cluster with the same token serves at once.
