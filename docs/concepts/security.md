# Security

The boundary, gate by gate. Each gate is enforced in one place, explained by
one decision and proved by one check; this page is the map between them. What
to type when a gate misbehaves is [Operate](../guides/operate.md).

## What is protected

The node holds every app's data, the registry every image, and Infisical every
secret the workloads read. Several stores authenticate nothing by design
(VictoriaMetrics, VictoriaLogs, VictoriaTraces, ClickHouse, Redis), and the
model gateway `jterrazz-intelligence` takes no API key. So the network is the
boundary for them, and each layer below assumes the one above it can fail.

## The gates, outside in

| Gate                   | What it enforces                                                                                                   | Where                                                           | Why                                                                                  | Proved by                                                                   |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------- | ------------------------------------------------------------------------------------ | --------------------------------------------------------------------------- |
| No public address      | nothing on the internet can open a connection to the node                                                          | the VM is reachable only from the Mac and the tailnet           | [ADR-006](../decisions/006-the-host-has-no-public-inbound-path.md)                   | `api/boundary/internet.spec.ts`                                             |
| nft guard              | other OrbStack machines reach no node port; the NodePort range is dropped from every source                        | `roles/security`, `nft-guard.service`                           | [ADR-006](../decisions/006-the-host-has-no-public-inbound-path.md)                   | `host/firewall/guard.test.ts`                                               |
| UFW                    | 80, 443 and 6443 from the tailnet range only                                                                       | `roles/security`                                                | [ADR-006](../decisions/006-the-host-has-no-public-inbound-path.md)                   | nothing: the second gate behind the two above                               |
| The tunnel             | public traffic arrives only by an outbound tunnel cloudflared dials                                                | `services/cloudflared/app.yaml`                                 | [ADR-002](../decisions/002-public-traffic-enters-through-a-cloudflare-tunnel.md)     | `api/routes/public.spec.ts`                                                 |
| Traefik's source range | Traefik's LoadBalancer admits `100.64.0.0/10` alone and allocates no NodePort                                      | `cluster/traefik/helm-chart-config.yaml`                        | [ADR-003](../decisions/003-traefiks-service-is-the-tailnet-gate.md)                  | `cluster/traefik/service.test.ts`                                           |
| `private-access`       | a private route answers tailnet sources only                                                                       | the Middleware in `cluster/`, attached by the charts            | [ADR-003](../decisions/003-traefiks-service-is-the-tailnet-gate.md)                  | `api/routes/private.spec.ts`                                                |
| The Cf-Ray rule        | a private route never matches a request that crossed Cloudflare                                                    | `charts/common/templates/_ingress.tpl`                          | [ADR-003](../decisions/003-traefiks-service-is-the-tailnet-gate.md)                  | `api/routes/private.spec.ts`                                                |
| Default-deny ingress   | a pod receives only what a policy admits                                                                           | `cluster/network-policies/<ns>.yaml`, each release's `network:` | [ADR-011](../decisions/011-every-namespace-is-default-deny.md)                       | `cluster/network-policies/`                                                 |
| Pod Security baseline  | no namespace runs privileged pods unless it is labelled so                                                         | the k3s admission config, `cluster/namespaces.yaml`             | [ADR-018](../decisions/018-pod-security-baseline-is-enforced-by-default.md)          | `host/k3s/pod-security.test.ts`                                             |
| `host-access`          | host network, PID, IPC, hostPath and privileged containers in kube-system, or for two named telemetry agents, only | `cluster/host-access/policy.yaml`                               | [ADR-018](../decisions/018-pod-security-baseline-is-enforced-by-default.md)          | `admission/host-access/policy.test.ts`                                      |
| App ownership          | an app repository writes only into namespaces and volumes labelled with its name                                   | `cluster/app-deployers/`                                        | [ADR-017](../decisions/017-app-repositories-deploy-as-their-github-oidc-identity.md) | `admission/ownership/policy.test.ts`, `cluster/rbac/github-actions.test.ts` |
| Secret readers         | exactly an allow-list of service accounts may list Secrets cluster-wide; admission never sees a read               | the operators' ClusterRoles                                     | [ADR-017](../decisions/017-app-repositories-deploy-as-their-github-oidc-identity.md) | `cluster/rbac/secrets.test.ts`                                              |
| Encryption at rest     | every Secret is encrypted in `state.db`                                                                            | `secrets-encryption: true` in the k3s config                    | [ADR-006](../decisions/006-the-host-has-no-public-inbound-path.md)                   | `host/k3s/secrets-encryption.test.ts`                                       |
| sshd                   | keys alone, root included                                                                                          | `roles/security`'s drop-in                                      | [ADR-006](../decisions/006-the-host-has-no-public-inbound-path.md)                   | `host/sshd/config.test.ts`                                                  |

The paths under "Proved by" are in `specs/specs/`; how each runs is
[Test](../guides/test.md#the-suite-file-by-file). The API audit log
(`audit-policy.yaml.j2`, Metadata level, never bodies) records rather than
enforces, so no check proves it beyond `audit.log` growing.

## Three things the gates do not cover

- **Nothing owns a hostname.** An app may declare a route or certificate for
  any name in our zones from inside its own namespace; the ownership policy
  names this residual risk.
- **Egress is narrowed, not closed.** An app reaches DNS and the internet,
  and no in-cluster address it does not declare; a platform namespace's
  baseline allows DNS, plus 443 and 6443 in `platform-secrets` and
  `platform-telemetry`. A compromised pod can still dial out.
- **The Mac is trusted.** It reaches the node as root through OrbStack, and
  the data directory lives on its disk.
