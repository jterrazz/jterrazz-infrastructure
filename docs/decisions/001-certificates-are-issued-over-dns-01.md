# ADR-001: Certificates are issued over DNS-01

**Status:** Accepted
**Date:** 2026-05-10

Written 2026-10-24 from the comments in
`src/kubernetes/services/cert-manager/issuers.yaml` and the network policies that
this record replaces. DNS-01 itself dates from the first cert-manager setup
(2025-12-30, 587d6df); it became the only possible answer when public 80/443
closed (6dc3915).

Revised 2026-10-25: two wildcards and the default TLSStore replace every per-host
certificate; the staging issuer and the zone list went.

## Context

Every route, public or private, terminates TLS at Traefik with a certificate
cert-manager issues from Let's Encrypt. HTTP-01 proves control of a name by
serving a token on port 80 of that name. The cluster has no public inbound
path at all (public traffic arrives through the Cloudflare tunnel, private
hosts resolve to a tailnet address), so Let's Encrypt could never reach an
HTTP-01 challenge for a private name, and reaching one through the tunnel
would mean a Public Hostname per private host.

## Decision

One ClusterIssuer, `letsencrypt-production`, solves DNS-01 through the
Cloudflare API, and it issues two certificates: `*.internal.jterrazz.com` and
`*.staging.jterrazz.com`, from the `traefik-platform` release. Traefik's
default TLSStore serves them by SNI to every private route, which writes
`tls: {}`.

- **No route gets a certificate of its own.** A public route's TLS ends at the
  Cloudflare edge, and cloudflared reaches Traefik's `tunnel` entrypoint over
  plain HTTP (it used `noTLSVerify` HTTPS until 2026-10-25, ADR-026), so a
  per-host certificate there was checked by nobody. Per-host certificates also
  published every hostname to the CT logs and left a gap while each issued.
- The private wildcards are DNS-only, so a two-label name such as
  `grafana.internal.jterrazz.com` gets a valid certificate, where Cloudflare's
  Universal SSL stops at `*.jterrazz.com`.
- cert-manager needs egress to the Cloudflare API and to public DNS for its
  propagation checks, which its NetworkPolicy grants.

## Consequences

- Private hosts get publicly trusted certificates without being reachable
  from the internet.
- The Cloudflare API token can write DNS records in the zone; it is an
  Infisical secret, fetched by the deploy.
- Every ACME TXT record is cert-manager's; none belongs in `dns_records`.
