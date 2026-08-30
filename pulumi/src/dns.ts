import * as pulumi from "@pulumi/pulumi";
import * as cloudflare from "@pulumi/cloudflare";

/**
 * Cloudflare-side DNS for the cluster's private services. Apex CNAMEs for
 * PUBLIC hostnames are deliberately absent: cloudflared's Public-Hostname
 * feature auto-creates those, and declaring them here would fight it.
 *
 * Auth is `CLOUDFLARE_API_TOKEN` (env) or `cloudflare:apiToken` config;
 * DNS:Edit on the managed zones suffices.
 *
 * NO `aliases:` are written on the `DnsRecord` resources below. The provider
 * SDK injects one itself, so keeping the Pulumi resource NAMES unchanged
 * (`private-grafana`, ...) is all that is needed for the URNs to carry over —
 * adding our own would be a redundant duplicate.
 *
 * `name` may be the SHORT name — the provider stores the zone name in private
 * state and suppresses the FQDN diff.
 */

// Hardcoded rather than looked up, to save an API round-trip on every
// `pulumi up`. Zone IDs are stable; a moved zone 404s at apply time.
const JTERRAZZ_ZONE_ID = "ca5eefcd2d8b1d8895fc255f26141d46";

// Tailnet suffix; the only variable part is the cluster hostname, passed in
// from createMachine() in src/targets/orbstack.ts.
const TAILNET_DOMAIN = "tail77a797.ts.net";

// The tunnel's CNAME target. Public, not a secret — it IS the CNAME content.
const TUNNEL_HOSTNAME = "8f4157bb-f883-424b-8ccd-8332867cf1b2.cfargotunnel.com";

export function createPrivateDnsRecords(tailscaleHostname: pulumi.Output<string>): void {
    const fqdn = tailscaleHostname.apply((h) => `${h}.${TAILNET_DOMAIN}`);

    // THE ONE EXCEPTION, and it is a wart, kept because retiring it carelessly
    // takes live traffic down.
    //
    // Every other public hostname gets its CNAME from the tunnel's Public
    // Hostname feature, in the Zero Trust dashboard, which creates the record
    // itself. This one has its ROUTE there but its RECORD here — so deleting
    // it does not fall back to anything: `analytics.jterrazz.com` would stop
    // resolving, and it carries the event ingest that jterrazz.com actually
    // uses (a few hundred events a week, verified in ClickHouse).
    //
    // TO RETIRE IT, in this order: add `analytics.jterrazz.com` as a Public
    // Hostname in the Zero Trust dashboard (it will adopt/replace this record),
    // confirm `dig analytics.jterrazz.com` still answers and that a POST to
    // /api/track still returns 401, THEN delete this block and `pulumi up`.
    // Doing it the other way around is a DNS outage of unknown length.
    new cloudflare.DnsRecord("public-analytics", {
        zoneId: JTERRAZZ_ZONE_ID,
        name: "analytics",
        type: "CNAME",
        content: TUNNEL_HOSTNAME,
        // Must be proxied — cfargotunnel.com only resolves at the edge.
        proxied: true,
        ttl: 1,
        comment: "Managed by Pulumi (pulumi/src/dns.ts) — public ingest via the Cloudflare tunnel",
    });

    // THE ONLY OTHER DNS RECORD THIS REPO OWNS.
    //
    // Every private surface is `<svc>.internal.jterrazz.com` and is covered by
    // this one wildcard, so adding or removing a private service needs no DNS
    // change anywhere — not here, not in group_vars, not in the Cloudflare UI.
    // That is the whole point: a per-service record here would make Pulumi (a
    // machine provisioner) the owner of a service-level fact, which is how the
    // previous shape ended up with the same hostname list maintained in two
    // files and a CI assertion to stop them drifting.
    //
    // Public hostnames are NOT here: the tunnel's Public Hostname feature
    // creates their CNAMEs itself, in the Zero Trust dashboard. One owner per
    // kind — machine here, services there.
    //
    // external-dns would be the k8s-native way to own per-service records, and
    // it is deliberately absent: with this wildcard there are zero per-service
    // records to reconcile, so it would have nothing to do.
    //
    // Explicit records always beat a wildcard in DNS, so pre-existing names on
    // this zone (www → Vercel, blog, mail) are unaffected.
    //
    // One label deep, on purpose: a wildcard TLS cert for
    // *.internal.jterrazz.com covers `svc.internal` but not `a.b.internal`.
    //
    // DNS-only: proxied wildcards need a paid plan, and Tailscale-routed
    // traffic must skip the Cloudflare edge anyway.
    new cloudflare.DnsRecord("private-wildcard-internal", {
        zoneId: JTERRAZZ_ZONE_ID,
        name: "*.internal",
        type: "CNAME",
        content: fqdn,
        proxied: false,
        ttl: 1,
        comment: "Managed by Pulumi — wildcard for *.internal.jterrazz.com → tailnet",
    });
}
