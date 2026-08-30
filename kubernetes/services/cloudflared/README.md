# Cloudflared

Cloudflare Tunnel runtime that brings public traffic into the cluster
without exposing any host port. Cloudflared maintains an outbound QUIC
connection to the Cloudflare edge; traffic for any of our public
hostnames flows back through that tunnel and lands on the cluster-
internal Traefik service.

## How it routes

```
client ──https──► Cloudflare edge ──QUIC tunnel──► this Deployment
                                                       │
                                                       ▼
                                  traefik.kube-system.svc.cluster.local:443
                                                       │
                                                       ▼
                                            IngressRoute → app
```

Per-hostname routing is configured in Cloudflare's Zero Trust UI under
the tunnel's "Public Hostname" tab — adding a hostname there creates the
DNS CNAME automatically. The tunnel forwards everything to Traefik with
`No TLS Verify: ON` (internal traffic, no need to validate the cluster's
self-signed serving cert).

## One-time setup

Done once per tunnel; recorded here for reference and recovery.

### 1. Create the tunnel

Cloudflare → Zero Trust → Networks → Tunnels → Create a tunnel.
Connector type **Cloudflared**, name `jterrazz-infrastructure`. On the next
screen Cloudflare shows a connection token (starts with `eyJ…`).

### 2. Store the token in Infisical

`https://eu.infisical.com` → project `jterrazz` → env `prod` → path
`/jterrazz-infrastructure` → add secret `CLOUDFLARE_TUNNEL_TOKEN` with that
value. Ansible decodes the token at deploy time to derive the tunnel
hostname (`<tunnel-id>.cfargotunnel.com`) used as the DNS target for
public records.

### 3. Public Hostname per hostname

The tunnel routes **per hostname, not by wildcard** — every public hostname
gets its own Public Hostname rule (apex zones AND subdomains). In the tunnel
detail page, "Public Hostname" tab → Add one for each:

- apex zones: `jterrazz.com`, `clawrr.com`, `clawssify.com`, `sig.news`,
  `spwn.sh` (Subdomain: empty)
- subdomains: e.g. `signews.jterrazz.com`, `analytics.jterrazz.com`
  (Subdomain: the label, e.g. `signews` / `analytics`)

For each:

- Service type: HTTPS
- URL: `traefik.kube-system.svc.cluster.local:443`
- Additional application settings → TLS → **No TLS Verify: ON**

Adding the rule auto-creates the CNAME. Exception: `analytics.jterrazz.com`
(OpenPanel ingest) already has a hand-made CNAME (see "DNS records" in
[docs/RUNBOOK.md](../../../docs/RUNBOOK.md)), so there only the routing rule is
added in the dashboard.

## Deploy

Two halves, and only one of them is a manifest. `service.yaml` is
platform-service values for the `cloudflared-platform` release, which carries
the InfisicalSecret that becomes `cloudflared-secrets`; `deployment.yaml` is
**the one raw Deployment left in this repo**, applied by
`roles/platform/tasks/raw-manifests.yml` after that release exists.

It stays raw on purpose: `hostNetwork: true` plus
`dnsPolicy: ClusterFirstWithHostNet` are what make the tunnel work here at all
(the CNI bridge mangles outbound TCP/7844 — see the note in the manifest), and
the app chart expresses neither. It is the exception; anything else new should
be a chart release.

For a targeted apply from the cluster host:

```bash
kubectl apply -f /tmp/k8s-manifests/kubernetes/services/cloudflared/deployment.yaml
```

## Verify

```bash
# Pod healthy?
kubectl get pod -n platform-networking -l app.kubernetes.io/name=cloudflared

# Connected to Cloudflare edge?
kubectl logs -n platform-networking deploy/cloudflared --tail=30 | grep -E 'Registered|edge'

# Token synced from Infisical?
kubectl get secret cloudflared-secrets -n platform-networking \
  -o jsonpath='{.data.CLOUDFLARE_TUNNEL_TOKEN}' | base64 -d | head -c 20; echo

# Live traffic counter
POD_IP=$(kubectl get pod -n platform-networking -l app.kubernetes.io/name=cloudflared -o jsonpath='{.items[0].status.podIP}')
curl -s "http://$POD_IP:2000/metrics" | grep '^cloudflared_tunnel_total_requests '
```

The Cloudflare dashboard shows the tunnel as **HEALTHY** within ~30s of
pod start.

A tunnel accepts up to 4 connectors and Cloudflare load-balances between them,
so a second cluster brought up with the same `CLOUDFLARE_TUNNEL_TOKEN` starts
serving traffic immediately. To stop one from serving without deleting it:

```bash
kubectl scale -n platform-networking deploy/cloudflared --replicas=0
```

## Two settings that are load-bearing here

`hostNetwork: true`. Without it, the CNI bridge on the OrbStack VM mangles
outbound TCP/7844 to the Cloudflare edge and cloudflared's tunnel handshake
gets RSTed — while `curl` from the same pod IP connects fine, so only
cloudflared's specific socket flow fails. hostNetwork bypasses CNI and traffic
goes straight through the host's stack.

`--protocol http2`, to avoid OrbStack's NAT eating outbound UDP/443 (QUIC).
HTTP/2 over TCP traverses the NAT cleanly. Both settings are harmless on a
target that doesn't need them; neither should be removed without testing the
handshake on a fresh VM.
