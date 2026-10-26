# common, the library chart

A Helm **library** chart: never installed, renders nothing of its own. It holds
the one implementation of every concern `app` and `platform-service` both have,
so a fix lands once instead of twice.

Both charts declare it as a relative `file://../common` dependency, so
`helm dependency update` resolves it from this tree with no registry and no
network, and `helm package` bundles it into the app chart's `.tgz`, which is
why an app repo still pulls one unversioned chart and needs no new repository.
Nothing is vendored: `charts/` and `Chart.lock` are gitignored.

| Template                                  | Emits                                                                 | `app`                                                                | `platform-service`                                          |
| ----------------------------------------- | --------------------------------------------------------------------- | -------------------------------------------------------------------- | ----------------------------------------------------------- |
| `common.ingressRoute`                     | one Traefik `IngressRoute`, on `tunnel` if `public`, else `websecure` | one per ingress entry, `<app>-<idx>`, `public: true\|false` each     | one, `<name>`, `public:` (default `false`)                  |
| `common.middleware.stripPrefix`           | a `stripPrefix` Middleware                                            | `<app>-<idx>-strip-prefix`                                           | none                                                        |
| `common.middleware.redirect`              | a `redirectRegex` Middleware                                          | `<app>-<idx>-redirect`                                               | none                                                        |
| `common.certificate`                      | a cert-manager `Certificate`                                          | none: routes are served from the default TLSStore                    | one per `certificates.<key>` (the private zones' wildcards) |
| `common.volume`                           | a hostPath `PersistentVolume` + its `PersistentVolumeClaim`           | the single `spec.storage`                                            | one pair per `storage.<key>`                                |
| `common.networkPolicy`                    | one `NetworkPolicy`                                                   | always: `uses`, `serves` and the `spec.network` block               | from the `network:` block                                   |
| `common.infisicalSecret`                  | an `InfisicalSecret`                                                  | when `spec.secrets.env` lists a key, from `/<app>`                   | when `secrets:` is set                                      |
| `common.smokeAnnotations`                 | the `studio.jterrazz.com/smoke-*` annotations on an `IngressRoute`   | derived per ingress entry, `smoke:` overrides it                     | from the `smoke:` block                                     |
| `common.alerts`, `common.alertsConfigMap` | the Grafana alert rule files, as a sidecar-labelled ConfigMap         | `spec.alerts`, from `.infrastructure/alerts/*.yaml`                  | `alerts:`                                                   |
| `common.dashboards`                       | one ConfigMap per dashboard, its identity derived                     | `spec.dashboards`, from `.infrastructure/dashboards/<kind>.json`     | `dashboards:`, owner `studio-infrastructure`                |

Each template's header lists its inputs and the hazard it absorbs. The peer
vocabulary and its traps are documented once, in
[the platform-service README](../platform-service/README.md#network-the-per-service-policy);
the smoke annotations in [the app README](../app/README.md#smoke-names-what-the-probe-should-get-back).

## Two rules for anything added here

**Names are inputs; this chart invents none.** `app` and `platform-service`
name the same kind of object differently, and those names address live data and
live routes. A shared template that derived a name would rename something.

**Labels arrive as a rendered string, not a map.** Each chart's label set has
its own deliberate order (`app.labels` ends with `studio.jterrazz.com/environment:`,
`platform-service.labels` with `app.kubernetes.io/managed-by:`), and `toYaml` would
sort them alphabetically, a diff on every object for no reason. So callers
pass `include "<chart>.labels" .` and this chart `nindent`s it.
