# ADR-026: A public route is published by its IngressRoute

**Status:** Accepted
**Date:** 2026-10-25

## Context

Until 2026-10-25 a public hostname was three things kept in step by hand: a
Public Hostname rule clicked into the tunnel's Zero Trust config, the CNAME
that click created, and the app's IngressRoute. Traefik served public and
private routes on one entrypoint, `websecure`, which both the tailnet and
cloudflared reached from pod addresses, so two guards kept a request that
crossed Cloudflare off a private host: the `private-access` ipAllowList, which
could not tell the two apart, and a `!HeaderRegexp(Cf-Ray)` clause on every
private match. The dashboard also kept rules for hosts long gone (`clawrr.com`,
`clawssify.com`), and nothing in the cluster could say which hostnames were
public.

## Decision

- **Two entrypoints, one per audience.** A public route sits on `tunnel` alone,
  plain HTTP on pod port 8090 behind the ClusterIP Service `traefik-tunnel`; a
  private route on `websecure` alone, with the private zones' wildcards.
  `allow-traefik-ingress` admits cloudflared to 8090 only and the tailnet's
  svclb pods to 8000/8443 only, so a request from the edge has no private
  route to match. `private-access` and the Cf-Ray clause are gone. The choice
  lives in one template, `common.ingressRoute`, keyed on the entry's `public:`.
- **The tunnel has one rule.** Its remote config is a single catch-all to
  `http://traefik-tunnel.kube-system.svc.cluster.local:80`, converged by the
  `cloudflare` role. The hop is plain HTTP: the edge terminates TLS (ADR-001),
  and the `noTLSVerify` HTTPS it replaced authenticated nothing. Traefik trusts
  cloudflared's forwarded headers, so apps still see `X-Forwarded-Proto: https`.
- **external-dns writes each public record.** It watches IngressRoutes carrying
  `external-dns.alpha.kubernetes.io/target: tunnel.jterrazz.com`, which
  `common.ingressRoute` stamps on public routes alone, and writes a proxied
  CNAME from every host to `tunnel.jterrazz.com`, in whichever of our zones
  holds it. `tunnel.jterrazz.com` is the tunnel's one alias, a `dns_records`
  entry derived from the connector token; Cloudflare follows a proxied CNAME
  to it across zones of the account, so no app chart knows the tunnel id.
- **upsert-only, and pinned to 0.21.** external-dns 0.22 and 0.23 generate no
  endpoint from a traefik.io IngressRoute. On its first start under `sync`,
  0.23 therefore deleted every public record it owned, and every public host
  was down for about two minutes until they were recreated by hand. Under
  upsert-only an empty source changes nothing; the price is that a removed
  route leaves its CNAME behind, which resolves to a tunnel that answers 404.
- **Two Cloudflare tokens.** `CLOUDFLARE_DNS01_TOKEN` (DNS:Edit on
  `jterrazz.com`) is cert-manager's alone; `CLOUDFLARE_RECORDS_TOKEN` (DNS:Edit
  on the public zones, Tunnel:Edit) serves the `cloudflare` role and
  external-dns. The single token both used to share is revoked.

## Consequences

- A new public host is an `ingress` entry with `public: true` and nothing else:
  its record appears within seconds of the deploy (proved live with a probe
  route, 2026-10-25). A host in a zone the records token cannot edit fails in
  external-dns's log, not in the app's deploy.
- A route removed leaves an orphan CNAME to delete by hand
  ([Operate](../guides/operate.md)).
- The platform contract checks the split directly: every IngressRoute sits on
  exactly one of `tunnel` and `websecure`, no private-zone host is on `tunnel`,
  no tunnel route has TLS, and a route is published exactly when it is on the
  tunnel (`cluster/traefik/entrypoints.test.ts`).
- Lifting the external-dns pin needs a `--dry-run` against the live routes
  first; `renovate.json` holds it below 1.22 until then.
