# ADR-029: An app is declared strictly, reads its own secrets, and is reached by consent

**Status:** Accepted
**Date:** 2026-10-27

Revised 2026-10-27: `branch` (`main`, `next`, or an image tag a dispatch pins) is
`deploy`, `push` or `release`; no app pinned an image tag, so that form went.

## Context

App chart 5.x accepted any key an `application.yaml` wrote and ignored the
ones it did not read, so a typo (`replica:`, `stripPrefx:`) deployed without
it. An app chose its Infisical folder (`spec.secrets.path`) although the
ownership policy admits one folder only, and an environment could borrow
another's secrets (`secretsEnv: prod`): signews-api's staging read prod's
keys. The owner's word for it: reading another environment's secrets is a
security smell.

Two apps are not per-environment at all. studio-intelligence, the model
gateway, and studio-alerts, Grafana's Slack relay, serve every environment,
yet each ran as `<app>-prod` and was dialled there by name from staging too.
Access to the gateway was granted by the consumer: naming it in
`platformServices` stamped a `platform-client.jterrazz.com/*` pod label that
the gateway admitted from any namespace, so any pod able to set a label could
reach it. Access to a provider should be granted by the provider.

The labels had three prefixes (`app.jterrazz.com/`, `smoke.jterrazz.com/`,
`platform-client.jterrazz.com/`) beside bare `app` and `environment` pod
labels, and the policy derived an app's name by cutting its environment off
the namespace's name.

## Decision

1. **`values.schema.json` is strict**: draft-07, `additionalProperties: false`
   at every object level, the header `apiVersion: studio.jterrazz.com/v1`,
   `kind: Application`. A key the chart does not read fails the deploy.
2. **A pod drains before it stops**: a native 5s `preStop` sleep, inside the
   default 30s grace period, because Traefik routes to a terminating pod until
   its endpoint is removed.
3. **The secrets folder is derived**: `spec.secrets` is `{ env: [KEY...] }`,
   read from `/<metadata.name>`. An optional `path` overrides it for platform
   releases only, which the admin identity deploys and the policy never judges
   (OpenPanel's four share `/studio-infrastructure/openpanel`); an app's CI
   identity is refused anything but `/<app>`.
4. **An environment names what deploys it**: `environments.<env>.deploy`,
   `push` (every push to main) or `release` (a `v*` tag, with that tag's
   image), read by app CI alone.
5. **No environment reads another's secrets**: `secretsEnv` is gone; an app
   InfisicalSecret's `envSlug` is the release's environment, which the
   ownership policy enforces against the namespace's
   `studio.jterrazz.com/environment` label, or `prod` for a shared app.
6. **One prefix, `studio.jterrazz.com/`, for every key the estate invents**:
   the namespace's `tier`, `environment`, `repository`, `app` and `scope`; the
   PV's and Deployment's `repository`; the smoke contract's
   `smoke-{probe,path,expect,location,method}`. Pods carry
   `app.kubernetes.io/{name,instance,managed-by}` and
   `studio.jterrazz.com/environment`, and are selected by the name and the
   environment. The policy reads the app off the namespace's `app` label, and
   admits an app namespace only when its name is what its labels state and
   its app is the deploying repository's: the repository's own name, or an
   app the policy pairs with it in one explicit allowlist (today
   `studio-os → studio-console`). No repository can label a namespace as
   another's app and so read `/<that app>`.
7. **Each template resolves its spec once** and hands it to the helpers.
8. **The dead re-checks behind the catalog accessor go.**
9. **`scope: shared`** declares an app every environment calls: one release,
   environment `shared`, namespace and volume `<app>`, prod's secrets, the
   dashboards and alert rules a prod release carries, deployed as its root
   `deploy` says. studio-intelligence and studio-alerts are shared.
10. **Access is a consent from both sides**: a consumer `uses` a capability
    (`telemetry`, `intelligence`), which injects its env and opens egress to
    its provider; the provider `serves` named apps, or `all`, admitted by
    their namespaces' `studio.jterrazz.com/app` or `tier` label, which only
    a namespace's owning repository sets. The catalog grants nothing.

## Consequences

- Every Deployment the app chart renders, the platform's (cloudflared, the
  registry, OpenPanel's six) included, changes selector and is deleted and
  recreated once.
- Existing app namespaces and volumes carry only the old
  `app.jterrazz.com/repository` label, which the policy no longer reads, so an
  admin adds the new labels before the first deploy of chart 6.0.0.
- The two shared apps move namespace, and studio-intelligence's volume moves
  from `/var/lib/k8s-data/studio-intelligence-prod` to
  `/var/lib/k8s-data/studio-intelligence`; dashboards and alert rules that
  named `<app>-prod` name `<app>`.
- signews-api's staging needs its own `staging` keys in Infisical.
- An app is named after its repository. A repository whose app is named
  apart (studio-os deploys studio-console) needs an entry in the policy's
  allowlist, and that entry is a grant: it is reviewed like RBAC.
- A typo, a retired key or a cross-environment read is now a failed deploy,
  never a silent one.
