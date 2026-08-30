# platform-service chart

The half of a platform service that this repo owns. The workload itself comes
from an upstream chart (or a hand-written manifest); this chart supplies what
that chart cannot: the Traefik route, the certificate, the hostPath volumes and
the NetworkPolicy.

One values file per service, `kubernetes/services/<svc>/service.yaml`, rendered
by the `<svc>-platform` release in `kubernetes/helmfile.yaml.gotmpl`. **That
release name is frozen** — renaming it creates a new release and orphans the
hostPath PV the old one bound.

`values.yaml` is the field-by-field reference and owns every default. This file
is the *why*, and the recipes.

| Object | Name | Rendered when |
| --- | --- | --- |
| `IngressRoute` | `<name>` | `host` is set |
| `Certificate` | `<name>-tls` | `host` is set |
| `Certificate` | `<key>` | per `certificates.<key>` |
| `InfisicalSecret` | `<name>-infisical` | `secrets` is set |
| `PersistentVolume` | `<name>-<key>` | per `storage.<key>` |
| `PersistentVolumeClaim` | `<name>-<key>`, or `claimName` | per `storage.<key>` |
| `NetworkPolicy` | `<name>` | `network` is set |

All of them come from `kubernetes/charts/common`, the library chart this one and
`app` share — that is where the IngressRoute shape, the never-chain-ipAllowLists
rule, the PV/PVC data-safety constraints and the NetworkPolicy peer vocabulary
actually live.

## `secrets:` — the service's credentials

```yaml
secrets:
  path: /jterrazz-infrastructure/librechat   # Infisical secretsPath
  secretName: librechat-credentials-env      # what the CONSUMER reads
  env: prod                                  # Infisical env slug; the default
```

Renders `InfisicalSecret <name>-infisical`, which the operator syncs into
`secretName` in the release's namespace. **`secretName` is required and is a
contract, not a derived string**: the LibreChat chart wires `envFrom` to that
literal name, the collector's `values.yaml` reads one key out of it by name, and
cloudflared's Deployment names it in a `secretKeyRef`. Rename it and the
credential simply never arrives — with no error anywhere.

The managed Secret's `creationPolicy` is Infisical's default `Orphan`, so it
outlives the release: `helm uninstall` does not log the service out.

Declaring this here is what replaced the hand-applied InfisicalSecrets in
`ansible/roles/platform/tasks/bootstrap.yml` — the operator provides the CRD
(`needs: platform-secrets/infisical`), and the release that mounts the Secret
orders itself after this one.

## `certificates:` — a hostname several releases answer on

```yaml
certificates:
  openpanel-tls:            { dnsNames: [openpanel.internal.jterrazz.com] }
  openpanel-analytics-tls:  { dnsNames: [analytics.jterrazz.com] }
```

The service's own `host` needs nothing here — it already gets `<name>-tls`.
This block is for a service split across several **app-chart** releases, whose
routes therefore live on those releases: two of them answering on one hostname
cannot each own its certificate without issuing a second one for the same name.
So the service owns the certificate and the routes name it with
`ingress[].tlsSecret`. OpenPanel (`op-api` + `op-dashboard` on one host) is the
sole user.

The map key is **both** the Certificate and the TLS Secret name, because both
address a live secret Traefik reads by name.

## `smoke:` — what the route must answer

`scripts/smoke.sh` holds no table of hostnames or status codes. It lists every
IngressRoute in the cluster and probes what these two annotations say:

```yaml
smoke:
  path: /v2/       # default `/`
  expect: "401"    # default "200"; comma-separated for several acceptable codes
```

The default (`/` -> 200) is the weakest useful claim, so most services need no
block at all. Override it where the service genuinely answers something else to
an unauthenticated caller — Grafana bounces to `/login` (302), the registry
challenges for a token (401) — and keep the list as narrow as the service
allows. `000` and any 5xx must never be in it; a probe that accepts them is a
probe that cannot fail.

The annotation contract itself, including the two things only the app chart and
hand-written manifests emit (`location`, `method`), is
`kubernetes/charts/common/templates/_smoke.tpl`.

## `network:` — the per-service policy

NetworkPolicies **union**, so a namespace's rules are split by ownership rather
than by file convenience:

| Rule | Lives in |
| --- | --- |
| default-deny, allow-same-namespace, namespace-wide DNS/egress | `kubernetes/cluster/network-policies/<ns>.yaml` |
| anything that names ONE workload with a `-platform` release | that service's `network:` |
| anything that names a workload with no release of its own (otel-collector, librechat-mongodb, the openpanel stack, the registry Deployment, cloudflared) | still `cluster/network-policies/<ns>.yaml` |

```yaml
network:
  # REQUIRED, and not derivable: these pods are rendered by the UPSTREAM chart,
  # so the labels are that chart's. Read them off `kubectl get pod --show-labels`.
  podSelector:
    app.kubernetes.io/name: grafana
    app.kubernetes.io/instance: grafana
  ingress:
    - from: traefik
      ports: [3000]
  egress:
    - to: namespace:prod-gateway-intelligence
      ports: [8317, 80]
    - to: internet
      ports: [443]
```

One policy is rendered, named after the service, carrying both directions.
`policyTypes` follows the directions actually declared — a service that lists
only `ingress:` leaves egress to the namespace baseline rather than silently
denying it.

### Peers

| `from:` / `to:` | Selects |
| --- | --- |
| `traefik` | the `kube-system` namespace, where k3s runs Traefik |
| `namespace:<ns>` | one namespace, by its `kubernetes.io/metadata.name` |
| `any-namespace` | every namespace — what DNS egress needs |
| `pods:<key>=<value>` | pods carrying a label, in **this** namespace |
| `any-namespace-pods:<key>=<value>` | pods carrying a label, in any namespace |
| `internet` | `0.0.0.0/0` **except** RFC1918 |
| `anywhere` | `0.0.0.0/0`, no exception |

`internet` and `anywhere` are deliberately distinct and one is not a tidier
spelling of the other. On this cluster the apiserver is RFC1918 twice over —
pods dial the `kubernetes` ClusterIP `10.43.0.1:443`, which iptables DNATs to
the node's own `192.168.x.x:6443` — so anything that must reach it, or must
scrape a target set no static list can enumerate, needs `anywhere`.

### The two traps

**Ports are POD ports, never Service ports.** A policy is evaluated *after*
kube-proxy's DNAT, so the destination it sees is the containerPort. Grafana's
Service is `80 -> 3000`; a rule naming 80 applies to nothing, and the traffic is
dropped by the namespace default-deny with nothing logged anywhere.

**`pods:` is not `any-namespace-pods:`.** The first is a bare `podSelector`,
which NetworkPolicy reads as "in this policy's own namespace"; the second adds
an empty `namespaceSelector` and admits a pod of that name from anywhere in the
cluster. For an unauthenticated database that difference is the whole control.

**hostNetwork clients are not pods.** cloudflared and the apiserver arrive as
the node address, so only an `ipBlock` peer matches them — a namespace- or
pod-selector rule silently excludes them.

A bare port number is TCP (the Kubernetes default, left unwritten so the
rendered object matches what the API server stores). `53/UDP` spells a protocol
out.

## Working on the chart

```bash
helm dependency update kubernetes/charts/platform-service   # resolves ../common
helm template ci-test kubernetes/charts/platform-service \
  -f kubernetes/charts/platform-service/ci/test-values.yaml
make lint
```

`ci/test-values.yaml` is the validation contract: every template here is gated
behind a value, so default values render nothing and a branch the fixture does
not reach is a branch CI does not check.
