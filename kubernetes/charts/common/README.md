# common — the library chart

A Helm **library** chart: never installed, renders nothing of its own. It holds
the one implementation of every concern `app` and `platform-service` both have,
so a fix lands once instead of twice.

Both charts declare it as a relative `file://../common` dependency, so
`helm dependency update` resolves it from this tree with no registry and no
network — and `helm package` bundles it into the app chart's `.tgz`, which is
why an app repo still pulls one unversioned chart and needs no new repository.
Nothing is vendored: `charts/` and `Chart.lock` are gitignored.

| Template | Emits | `app` | `platform-service` |
| --- | --- | --- | --- |
| `common.accessMiddleware` | the ipAllowList middleware name, or `""` | `public: true\|false` per ingress entry | `access: private\|cluster-internal\|public` |
| `common.ingressRoute` | one Traefik `IngressRoute` | one per ingress entry, `<app>-<idx>` | one, `<name>` |
| `common.middleware.stripPrefix` | a `stripPrefix` Middleware | `<app>-<idx>-strip-prefix` | — |
| `common.middleware.redirect` | a `redirectRegex` Middleware | `<app>-<idx>-redirect` | — |
| `common.certificate` | a cert-manager `Certificate` | one per unique host | one, with the aliases as SANs |
| `common.volume` | a hostPath `PersistentVolume` + its `PersistentVolumeClaim` | the single `spec.storage` | one pair per `storage.<key>` |
| `common.networkPolicy` | one `NetworkPolicy` | always, from the platformServices catalogue | from the `network:` block |
| `common.infisicalSecret` | an `InfisicalSecret` | when `spec.secrets.path` is set | — |
| `common.smokeAnnotations` | the `smoke.jterrazz.com/*` annotations on an `IngressRoute` | derived per ingress entry, `smoke:` overrides it | from the `smoke:` block |

Each template's own header is the reference for its inputs and for the traps it
exists to absorb — the NetworkPolicy peer vocabulary in `_network-policy.tpl`,
the data-safety rules in `_storage.tpl`, the never-chain-ipAllowLists rule in
`_ingress.tpl`, the smoke annotation contract in `_smoke.tpl`.

## Two rules for anything added here

**Names are inputs; this chart invents none.** `app` and `platform-service`
name the same kind of object differently, and those names address live data and
live routes. A shared template that derived a name would rename something.

**Labels arrive as a rendered string, not a map.** Each chart's label set has
its own deliberate order (`app.labels` leads with `app:`,
`platform-service.labels` with `app.kubernetes.io/name:`), and `toYaml` would
sort them alphabetically — a diff on every object for no reason. So callers
pass `include "<chart>.labels" .` and this chart `nindent`s it.
