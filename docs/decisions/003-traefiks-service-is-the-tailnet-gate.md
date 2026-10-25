# ADR-003: Traefik's Service is the tailnet gate, shaped in its HelmChartConfig

**Status:** Accepted
**Date:** 2026-05-10

Written 2026-10-24 from the comments in
`src/kubernetes/cluster/traefik/helm-chart-config.yaml`,
`src/kubernetes/cluster/{traefik,network-policies}/`, `group_vars` and
`roles/platform` that this record replaces. The tailnet restriction dates
from the close of public 80/443 (6dc3915); the NodePort and timeout rows from
the 2026-10-24 audit and incidents.

Revised 2026-10-25: a private route never matches a request carrying `Cf-Ray`.

## Context

Traefik is k3s' bundled release, installed by helm-controller from a
HelmChart in kube-system; this repo shapes it only through a
HelmChartConfig. Its Service is `type: LoadBalancer`, which k3s' klipper-lb
serves by binding the node's ports 80 and 443: that is how tailnet clients
(the laptop, CI runners, containerd pulling images) reach private hosts on
the node's tailnet address. Public traffic never uses those ports; it comes
through cloudflared to Traefik's ClusterIP.

klipper-lb DNATs in PREROUTING, before UFW's INPUT filter sees the packet,
so `ufw deny 443` does nothing for these ports. And because every public and
private surface terminates at Traefik, its sizing and timeouts are
everyone's.

## Decision

The Service itself restricts its source, and every other knob is chosen in
the HelmChartConfig, applied before Traefik's install job is awaited.

- **`loadBalancerSourceRanges: 100.64.0.0/10` is the gate**, making klipper-lb
  itself reject non-tailnet sources. It sits under `service.spec`, which is
  the only part the chart's template renders; `service` has no
  `additionalProperties: false`, so a flat or renamed key is silently ignored
  and the host ports open to any source. That is why a k3s minor, which can
  move the bundled chart across a major (v38 flat `service.*`, v40/v41
  nested; v40 to v41 only renamed `logs.*`), owes a re-read of these values
  against the new `values.schema.json` in the same change, and a post-deploy
  check that `{.spec.loadBalancerSourceRanges}` is non-empty.
- **`allocateLoadBalancerNodePorts: false`.** A LoadBalancer Service also
  gets NodePorts on every node address by default, and the source ranges
  filter only klipper-lb's hostPorts. A NodePort hit arrives SNATed from
  10.42.0.1, which `private-access` admits, so every private route answered
  the Mac and every other OrbStack machine (audit 2026-10-24: grafana,
  openpanel, the keyless gateway). klipper-lb never used them. Turning
  allocation off frees no port already allocated, and k3s creates the Service
  with them, so the play removes any it finds right after Traefik installs
  (`roles/cluster/tasks/manifests.yml`); the platform contract asserts none
  remain, and the host guard drops the NodePort range regardless.
- **`readTimeout` 10m**, not v3's 60s: an image layer pushed over the
  tailnet (often DERP-relayed from a runner) takes longer, Traefik cut the
  body and answered 499, and buildx reported a failed push (jterrazz-os,
  twice on 2026-10-24). The Cloudflare edge already bounds slow public
  clients.
- **`advertisedPort` 443**: Traefik defaults it to the entrypoint's
  in-container port, 8443, so Alt-Svc would send HTTP/3 clients to a UDP
  port klipper-lb does not publish.
- **Resources set, memory limit, no CPU limit.** The chart ships none, which
  is BestEffort, first evicted under node memory pressure, taking every
  surface with it. The memory limit makes it Burstable and is generous
  because buffers scale with connections; a CPU cap would throttle exactly
  the bursts it exists to absorb.
- **`forwardedHeaders.trustedIPs` lists this node's own networks** (pod and
  service CIDRs, loopback, Tailscale CGNAT, link-local, OrbStack's
  198.19.0.0/16, RFC1918 172.16/12 and 192.168/16), never Cloudflare's edge
  CIDRs: Cloudflare never talks to Traefik directly, its peer is always
  cloudflared in the cluster. A wrong list silently strips the client IP from
  `X-Forwarded-For`.
- **The rate limiter keys on `Cf-Connecting-Ip`** (100 req/s, burst 200,
  attached to the websecure entrypoint): the edge sets it and overwrites any
  client value, so it cannot be spoofed. It replaced an X-Forwarded-For walk
  whose `excludedIPs` had to repeat the trustedIPs list entry for entry.
  Tailnet traffic, MASQUERADEd by klipper-lb, shares one bucket.
- **`private-access` admits 10.42.0.0/16** besides the tailnet and loopback:
  klipper-lb DNATs and MASQUERADEs inside the svclb pod, so a tailnet request
  reaches Traefik from an svclb pod address (the node's own image pulls
  hairpin the same way). What keeps other pods off private hosts is
  `allow-traefik-ingress`, which admits only svclb's pods and cloudflared and
  excepts the pod CIDR.
- **A private route never matches a request that crossed Cloudflare.** The
  tunnel reaches Traefik from cloudflared's pod address, which private-access
  admits, so until 2026-10-25 a private host was kept off the internet only by
  the tunnel's hostname rules in the Cloudflare dashboard (audit finding H2).
  Every route behind private-access now carries
  `&& !HeaderRegexp(`Cf-Ray`, `.+`)` (`charts/common/_ingress.tpl`): the edge
  stamps that header on everything it forwards and a client cannot strip it.
  The platform suite proves it live: each private host answers 404 to a
  request carrying `Cf-Ray`. `allow-svclb-ingress` must allow the node address
  explicitly: miss it and public traffic keeps working while every tailnet
  client, CI included, gets `connection refused` on 443.
- **Apply order.** The HelmChartConfig is applied explicitly and first,
  before waiting on the install job: on a k3s bump the job may need the new
  schema to reconcile at all, and wait-then-apply deadlocked for 8 minutes.
  The wait tolerates NotFound for 30 x 10s because a config change makes
  helm-controller delete and recreate the job asynchronously; 6 tries failed
  a deploy on a Traefik that had upgraded fine (2026-10-24).

## Consequences

- One field, under one key, is the whole tailnet restriction of the host's
  80/443; every k3s minor bump is a review of this file.
- A NodePort on any Service would bypass it, which is why the host guard
  drops the range and the Service allocates none.
- Tailnet clients cannot be rate-limited per client; they are few and
  authenticated by the tailnet.
- tailscaled must not masquerade forwarded traffic
  (`--snat-subnet-routes=false`, see [the host record](006-the-host-has-no-public-inbound-path.md)),
  or klipper-lb sees 10.42.0.1 instead of a tailnet source and drops every
  SYN.
