# The deploy contract

What an app repo owes this repo, and what it gets back. The chart is owned
here; the workflows that execute the contract are
[jterrazz/jterrazz-actions](https://github.com/jterrazz/jterrazz-actions).

## What an app repo owes

- **One manifest**, `.infrastructure/application.yaml` — an `Application` the
  app chart renders: port, resources, ingress, storage, secrets, per
  environment. The schema, its merge semantics, `platformServices` and storage
  are [kubernetes/charts/app/README.md](../kubernetes/charts/app/README.md).
- **`tag:` on every environment.** Without it the workflow takes a legacy
  branch that deploys "staging" and leaves prod silently stale.
- **One universal CI interface** — `make build`, `make lint`, `make test`,
  whatever the toolchain.
- **Two GitHub secrets**, `INFISICAL_CLIENT_ID` and `INFISICAL_CLIENT_SECRET`,
  set on the repo before its first deploy — see
  [09-runbook.md](09-runbook.md#github-secrets-every-app-repo).

## What the app repo gets

- **A first deploy that needs no change here.** Namespace and certificate are
  created by the deploy itself; this repo does not know an app exists until its
  Certificate shows up.
- **The chart, pulled unversioned** from
  `oci://registry.internal.jterrazz.com/charts/app`. An app never pins a chart
  version, which is why a template edit must bump `version:` in
  `charts/app/Chart.yaml` — see [06-hand-synced-pairs.md](06-hand-synced-pairs.md).
- **Discovery instead of registration.** Smoke probes and redeploys read the
  live cluster: `scripts/smoke.sh` probes what each IngressRoute's
  `smoke.jterrazz.com/*` annotations say, and `scripts/trigger-app-deploys.sh`
  reads `app.jterrazz.com/repository` off every app Deployment. No list of
  hostnames, status codes or repos lives here.

## Consequences worth knowing

Renaming an app creates a new Helm release, and the old one keeps running:
`helm uninstall <env>-<old> -n <env>-<old> && kubectl delete ns <env>-<old>`.

Node and Next.js packaging traps (pnpm `--ignore-scripts`, `output:
'standalone'`, `mkdir -p public`) are the shared workflows' business, in
`jterrazz-actions`.
