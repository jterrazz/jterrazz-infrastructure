# cloudflared

The public ingress: an outbound tunnel from the Cloudflare edge to Traefik's
`tunnel` entrypoint, with no port open on the host. Why it runs on pod networking, over
QUIC, with a token file is
[ADR-002](../../../../docs/decisions/002-public-traffic-enters-through-a-cloudflare-tunnel.md).

```text
client ─► Cloudflare edge ─► tunnel (QUIC) ─► cloudflared ─► traefik-tunnel.kube-system:80 ─► IngressRoute
```

`service.yaml` is the `cloudflared-platform` release, which syncs the tunnel
token into `cloudflared-secrets`; `app.yaml` is the `cloudflared` app-chart
release that mounts it.

## Setting up a tunnel

1. In Zero Trust, Networks, Tunnels, create a **Cloudflared** tunnel named
   `studio-infrastructure` and copy its token (`eyJ...`).
2. Store it as `CLOUDFLARE_TUNNEL_TOKEN` in Infisical, project `studio-infrastructure`,
   env `prod`, path `/studio-infrastructure`.
3. Nothing else: the platform deploy sets the tunnel's one catch-all rule and
   its `tunnel.jterrazz.com` alias, and external-dns writes each public host's
   record ([ADR-026](../../../../docs/decisions/026-a-public-route-is-published-by-its-ingressroute.md)).
   Add no Public Hostname in the dashboard: the deploy overwrites the rules.

A tunnel load-balances up to four connectors, so a second cluster with the same
token serves at once; `kubectl scale -n platform-networking deploy/cloudflared
--replicas=0` takes one out.

## Verify

```bash
kubectl logs -n platform-networking deploy/cloudflared --tail=30 | grep -E 'Registered|edge'
POD_IP=$(kubectl get pod -n platform-networking -l app=cloudflared \
  -o jsonpath='{.items[0].status.podIP}')
curl -s "http://$POD_IP:2000/metrics" | grep '^cloudflared_tunnel_total_requests '
```

Rotating the token is
[Operate](../../../../docs/guides/operate.md#rotating-credentials).
