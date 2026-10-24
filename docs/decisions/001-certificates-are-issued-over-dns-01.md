# ADR-001: Certificates are issued over DNS-01

**Status:** Accepted
**Date:** 2026-05-10

Written 2026-10-24 from the comments in
`src/kubernetes/services/cert-manager/issuers.yaml` and the network policies that
this record replaces. DNS-01 itself dates from the first cert-manager setup
(2025-12-30, 587d6df); it became the only possible answer when public 80/443
closed (6dc3915).

## Context

Every route, public or private, terminates TLS at Traefik with a certificate
cert-manager issues from Let's Encrypt. HTTP-01 proves control of a name by
serving a token on port 80 of that name. The cluster has no public inbound
path at all (public traffic arrives through the Cloudflare tunnel, private
hosts resolve to a tailnet address), so Let's Encrypt could never reach an
HTTP-01 challenge for a private name, and reaching one through the tunnel
would mean a Public Hostname per private host.

## Decision

Both ClusterIssuers (`letsencrypt-production`, and `letsencrypt-staging` for
testing issuance with higher rate limits and an untrusted chain) solve
DNS-01 through the Cloudflare API, for the zones listed in their
`dnsZones`.

- A new public zone is added to the `dnsZones` of BOTH issuers.
- cert-manager needs egress to the Cloudflare API and to public DNS for its
  propagation checks, which its NetworkPolicy grants.
- The private wildcards are DNS-only, so a two-label name such as
  `grafana.internal.jterrazz.com` gets a valid certificate from cert-manager,
  where Cloudflare's Universal SSL stops at `*.jterrazz.com`.

## Consequences

- Private hosts get publicly trusted certificates without being reachable
  from the internet.
- The Cloudflare API token can write DNS records in the zone; it is an
  Infisical secret, fetched by the deploy.
- Every ACME TXT record is cert-manager's; none belongs in `dns_records`.
