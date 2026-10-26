# platform-service chart

The half of a platform service that this repo owns. The workload itself comes
from an upstream chart or the app chart; this chart supplies what an upstream
chart cannot: the Traefik route, the hostPath volumes, the synced Secret, the
NetworkPolicy, and the certificates no route issues itself.

One values file per service, `src/kubernetes/services/<svc>/service.yaml`, rendered
by the `<svc>-platform` release in `src/kubernetes/helmfile.yaml.gotmpl`. **That
release name is frozen**: renaming it creates a new release and orphans the
hostPath PV the old one bound.

`values.yaml` is the field-by-field reference and owns every default. This file
is the _why_, and the recipes.

| Object                  | Name                           | Rendered when            |
| ----------------------- | ------------------------------ | ------------------------ |
| `IngressRoute`          | `<name>`                       | `host` is set            |
| `Certificate`           | `<key>`                        | per `certificates.<key>` |
| `InfisicalSecret`       | `<name>-infisical`             | `secrets` is set         |
| `PersistentVolume`      | `<name>-<key>`                 | per `storage.<key>`      |
| `PersistentVolumeClaim` | `<name>-<key>`, or `claimName` | per `storage.<key>`      |
| `NetworkPolicy`         | `<name>`                       | `network` is set         |

All of them come from `src/kubernetes/charts/common`, the library chart this one and
`app` share; that is where the IngressRoute shape (which entrypoint a route sits on), the PV/PVC data-safety constraints and the NetworkPolicy peer vocabulary
actually live.

## `public:`, the route

`public: false` (the default) puts the route on the `websecure` entrypoint,
which only the tailnet reaches, with TLS from Traefik's default TLSStore;
`public: true` puts it on the `tunnel` entrypoint, which only cloudflared
reaches, with no TLS of ours, and external-dns writes its record. Both
entrypoints apply the rate-limit, compress and security-headers chain.

## `storage:`, the hostPath volumes

```yaml
storage:
  data: { size: 3Gi, pathSuffix: postgres, claimName: storage-svc-0 }
  uploads: { size: 5Gi, pathSuffix: uploads }
```

| Key             | Meaning                                                                                  |
| --------------- | ---------------------------------------------------------------------------------------- |
| `size`          | required; the PV capacity and the PVC request                                            |
| `pathSuffix`    | nests the hostPath under `<name>/` (one directory per app)                               |
| `claimName`     | overrides the PVC name only, never the PV or the binding                                 |
| `nodeLocalPath` | an absolute hostPath outside `/var/lib/k8s-data`, in the VM rather than on the Mac share |

Names and paths address live data; read `templates/storage.yaml` and the
library's `_storage.tpl` before changing any of them. `nodeLocalPath` is for
data a service works continuously and does not survive a repave, so point it
only at something reconstructible (`grafana-data` is the one user).

## `secrets:`, the service's credentials

```yaml
secrets:
  path: /studio-infrastructure/otel-collector # Infisical secretsPath
  secretName: otel-collector-secrets # what the CONSUMER reads
  env: prod # Infisical env slug; the default
```

Renders `InfisicalSecret <name>-infisical`, which the operator syncs into
`secretName` in the release's namespace. **`secretName` is required and is a
contract, not a derived string**: the collector's `values.yaml` reads one key
out of it by name, cloudflared's release mounts it as a file, and an
upstream chart may wire `envFrom` to a literal name it chose. Rename it and the
credential simply never arrives, with no error anywhere.

The managed Secret's `creationPolicy` is Infisical's default `Orphan`, so it
outlives the release: `helm uninstall` does not log the service out.

Two optional keys shape the Secret rather than where it comes from:

```yaml
secrets:
  labels:
    grafana_alert: "1"
  template:
    data:
      contact-point-slack.yaml: |
        apiVersion: 1
        {{- with .SLACK_WEBHOOK_URL.Value }}
        ...
        {{- end }}
```

- **`labels`** are stamped on the `InfisicalSecret`, and the operator copies a
  CR's labels onto the Secret it manages. That is how a synced Secret carries a
  label a watcher selects on: Grafana's alerts sidecar reads every Secret
  labelled `grafana_alert: "1"`.
- **`template`** is the operator's own transform, rendered by the operator
  (text/template with sprig), never by Helm. It replaces the default
  key-per-secret copy, so the Secret holds only the keys it names. A key
  missing at the path renders as an empty `.Value` rather than failing the
  sync, which is what lets a template guard on a secret not yet created.

## `certificates:`, the private zones' wildcards

```yaml
certificates:
  wildcard-internal-tls: { dnsNames: ["*.internal.jterrazz.com"] }
```

A route issues no certificate: Traefik's default TLSStore serves every private
route the wildcard of its zone, and a public route's TLS ends at the Cloudflare
edge. This block issues those wildcards, from `traefik-platform`
(`services/traefik/service.yaml`); the map key is both the Certificate and the
Secret the TLSStore names.

## `smoke:`, what the route must answer

The platform contract (`specs/specs/api`) holds no table of hostnames or
status codes. It lists every IngressRoute in the cluster and probes what these
two annotations say:

```yaml
smoke:
  path: /v2/ # default `/`
  expect: "401" # default "200"; comma-separated for several acceptable codes
```

The default (`/` -> 200) is the weakest useful claim, so most services need no
block at all. Override it where the service genuinely answers something else to
an unauthenticated caller (Grafana bounces to `/login` with a 302, the registry
challenges for a token with a 401), and keep the list as narrow as the service
allows. `000` and any 5xx must never be in it; a probe that accepts them is a
probe that cannot fail.

The annotation contract itself, including the two things only the app chart
emits (`location`, `method`), is
`src/kubernetes/charts/common/templates/_smoke.tpl`.

## `network:`, the per-service policy

NetworkPolicies **union**, so a namespace's rules are split by ownership rather
than by file convenience:

| Rule                                                                                | Lives in                                                             |
| ----------------------------------------------------------------------------------- | -------------------------------------------------------------------- |
| default-deny, allow-same-namespace, namespace-wide DNS/egress                       | `src/kubernetes/charts/cluster/values.yaml`                          |
| anything that names ONE workload with a `-platform` release                         | that service's `network:`                                            |
| anything that names ONE workload rendered by the **app** chart                      | that workload's `spec.network` (`isolated:`, `exposeTo:`, `egress:`) |
| anything that names an upstream workload with no `-platform` release (cert-manager) | `charts/cluster/templates/network-policies/`                         |

`podSelector` is required and never derived: the pods are the upstream chart's,
so read their labels off `kubectl get pod --show-labels`.

```yaml
network:
  podSelector:
    app.kubernetes.io/name: grafana
    app.kubernetes.io/instance: grafana
  ingress:
    - from: traefik
      ports: [3000]
  egress:
    - to: namespace:studio-intelligence
      ports: [8317, 80]
    - to: internet
      ports: [443]
```

One policy is rendered, named after the service, carrying both directions.
`policyTypes` follows the directions actually declared: a service that lists
only `ingress:` leaves egress to the namespace baseline rather than silently
denying it.

### Peers

| `from:` / `to:`                    | Selects                                             |
| ---------------------------------- | --------------------------------------------------- |
| `traefik`                          | the `kube-system` namespace, where k3s runs Traefik |
| `namespace:<ns>`                   | one namespace, by its `kubernetes.io/metadata.name` |
| `any-namespace`                    | every namespace, which is what DNS egress needs     |
| `pods:<key>=<value>`               | pods carrying a label, in **this** namespace        |
| `namespace-label:<key>=<v>[,<v>]`  | every namespace whose label is one of the values    |
| `internet`                         | `0.0.0.0/0` **except** RFC1918                      |
| `anywhere`                         | `0.0.0.0/0`, no exception                           |

`internet` and `anywhere` are deliberately distinct and one is not a tidier
spelling of the other. On this cluster the apiserver is RFC1918 twice over:
pods dial the `kubernetes` ClusterIP `10.43.0.1:443`, which iptables DNATs to
the node's own `192.168.x.x:6443`, so anything that must reach it, or must
scrape a target set no static list can enumerate, needs `anywhere`.

### The traps

**Ports are POD ports, never Service ports.** A policy is evaluated _after_
kube-proxy's DNAT, so the destination it sees is the containerPort. Grafana's
Service is `80 -> 3000`; a rule naming 80 applies to nothing, and the traffic is
dropped by the namespace default-deny with nothing logged anywhere.

**A peer outside the namespace is named by a namespace label, never a pod
label.** `pods:` is a bare `podSelector`, which NetworkPolicy reads as "in
this policy's own namespace"; a pod label matched across namespaces would admit
any workload that stamps it. `namespace-label:` matches labels only a
namespace's owner sets: the collector admits
`namespace-label:studio.jterrazz.com/tier=app`, every app namespace
([ADR-029](../../../../docs/decisions/029-an-app-is-declared-strictly-reads-its-own-secrets-and-is-reached-by-consent.md)).

**hostNetwork clients are not pods.** The apiserver and node-exporter arrive
as the node address, so only an `ipBlock` peer matches them; a namespace- or
pod-selector rule silently excludes them.

A bare port number is TCP (the Kubernetes default, left unwritten so the
rendered object matches what the API server stores). `53/UDP` spells a protocol
out.

## `dashboards:` and `alerts:`, the platform's own

`dashboards` maps a kind to dashboard JSON; each entry renders
`ConfigMap dashboard-<kind>`, labelled `grafana_dashboard: "1"` and filed in
Grafana's `studio-infrastructure` folder, its identity derived by the same
`common.dashboards` an app's goes through (uid `infrastructure-<kind>`,
[ADR-027](../../../../docs/decisions/027-a-dashboard-answers-one-audience-and-its-identity-is-derived.md)). `alerts` maps a name to an alert
provisioning document; all of them render one `ConfigMap <name>-alerts`,
labelled `grafana_alert: "1"` and checked by the same `common.alerts` an app's
rules are. Only `grafana-platform` sets them, and its helmfile entry fills them
from `.infrastructure/dashboards/*.json` and `.infrastructure/alerts/*.yaml`
at the repository root, the layout every app ships in, so adding one is adding
a file and deleting the file deletes it.

## Working on the chart

```bash
helm dependency update src/kubernetes/charts/platform-service   # resolves ../common
helm template ci-test src/kubernetes/charts/platform-service \
  -f src/kubernetes/charts/platform-service/ci/test-values.yaml
make check
```

`ci/test-values.yaml` is the validation contract: every template here is gated
behind a value, so default values render nothing and a branch the fixture does
not reach is a branch CI does not check.
