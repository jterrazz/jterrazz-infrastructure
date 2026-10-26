# ADR-023: Names follow the owner, and one name runs through everything

**Status:** Accepted
**Date:** 2026-10-25

Revised 2026-10-25: the gateway variable is `STUDIO_INTELLIGENCE_BASE_URL`.

## Context

Names had drifted: app namespaces were `<env>-<app>` (`prod-signews-api`)
while the same app's volume and data directory were `<app>-<env>`
(`signews-api-prod-data`, `/var/lib/k8s-data/signews-api-prod`); two apps
carried no brand (`os`, `studio-intelligence`) when every other one did; the
gateway's name was `<role>-<product>` where the others are `<brand>-<role>`;
and a namespace was told apart from the platform's by parsing its name.

A namespace is also the unit of security here: Pod Security level,
NetworkPolicies, RBAC, and the app-deployer ownership label (ADR-017). Its
name has to say who owns it.

## Decision

- **Two families, by owner.** `platform-<capability>` is owned by this
  repository and no app identity may write to it; `<app>-<env>` is created and
  owned by the app's repository. Each namespace says so in a label,
  `app.jterrazz.com/tier: platform | app`; an app namespace also carries
  `app.jterrazz.com/environment` and `app.jterrazz.com/repository`. Policies
  and tests select on labels, never on a name pattern.
- **An app is `<brand>-<role>`.** Brands: `jterrazz`, `signews`, `spwn`.
  Roles: `web`, `api`, `console`, and the product word where the role is a
  product (`intelligence`). `os` became `studio-console` (the console of the
  studio-os repository) and `studio-intelligence` became
  `studio-intelligence` (the server the `@jterrazz/intelligence` clients
  call). An app's name is decoupled from its repository's name: the
  ownership label still names the repository.
- **One name runs through everything.** The namespace and the Helm release are
  `<app>-<env>`, the image is `<app>`, the volume `<app>-<env>-data`, the data
  directory `/var/lib/k8s-data/<app>-<env>`, the Infisical folder `/<app>`.
- **A private hostname is the product, without the brand**:
  `<product>.internal.jterrazz.com`, `<product>.staging.jterrazz.com`
  (`grafana`, `registry`, `openpanel`, `signews`, `console`, `intelligence`).
- **Platform namespaces are grouped by domain, never by privilege.** A
  namespace named after its Pod Security level was considered for the node
  agents and rejected: it would split the telemetry stack and name a property
  instead of contents; host access is granted per workload instead (ADR-018).
  The platform namespaces are not merged either: each is its own blast radius
  (the identity that reads every secret, the registry every deploy needs, the
  public analytics ingest).

## Consequences

- The rename cost one short outage per app on 2026-10-25: the old release
  was uninstalled (its PV object goes, its data directory stays), the
  directory moved where the app was renamed, and the next deploy created the
  new namespace and bound the same data.
- The gateway's variable followed too, `STUDIO_INTELLIGENCE_BASE_URL`: the
  app chart injected both names for one version while its one reader,
  signews-api, moved.
- A new app needs no entry here: the rules above decide all its names.
