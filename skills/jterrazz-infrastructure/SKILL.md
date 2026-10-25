---
name: jterrazz-infrastructure
description: "Infrastructure and deployment for jterrazz projects: k3s, Helm, Traefik, CI/CD deploy. Use when deploying apps, configuring Kubernetes, adding domains, or troubleshooting infra."
---

# @jterrazz Infrastructure

One k3s cluster on one machine: an OrbStack VM (`jterrazz-infrastructure`,
Debian 13 trixie, arm64) on the dev Mac, in the `jterrazz-infrastructure`
repository. `src/scripts/deploy.sh` creates it, Ansible configures it, and
Helmfile deploys every platform release declared in
`src/kubernetes/helmfile.yaml.gotmpl`. Public traffic enters through a
Cloudflare tunnel; private hosts are tailnet-only. Apps live in their own
repositories and deploy themselves, as their GitHub OIDC identity, through the
`app` chart published there.

## Where things are documented

| Need                                              | Read                                  |
| ------------------------------------------------- | ------------------------------------- |
| The map of the manual                             | `docs/README.md`                      |
| How it fits together, and how things are named    | `docs/concepts/architecture.md`       |
| What keeps a request out, and what proves it      | `docs/concepts/security.md`           |
| Deploying an app: what the contract is            | `docs/reference/deploy-contract.md`   |
| The `application.yaml` schema                     | `src/kubernetes/charts/app/README.md` |
| Editing a values file, manifest, template or role | `docs/guides/develop.md`              |
| Secrets, troubleshooting, repave, restore         | `docs/guides/operate.md`              |
| What proves a change, and what a deploy proves    | `docs/guides/test.md`                 |
| Why a choice was made                             | `docs/decisions/`                     |

## Commands

```bash
make deploy           # create the VM if absent, then Ansible site.yml
make deploy-platform  # Ansible platform.yml only, everything above k3s
make diff             # what a platform deploy would change
make smoke            # the platform contract from the Mac
make redeploy-apps    # rebuild every app (ARGS=--dry-run lists the repositories)
make check            # the checks CI runs (alias: make lint)

orb -m jterrazz-infrastructure -u root kubectl get pod -A   # cluster access from the Mac
./src/scripts/helmfile.sh diff -l name=grafana              # one release
```

## Never

- **Never unpin `debian:trixie`** in `src/scripts/deploy.sh`: a bare `debian`
  is bookworm, and every role is Debian-13-native.
- **Never edit a chart template without bumping `version:`** in its
  `Chart.yaml`: the app chart is pulled unversioned and never overwritten, so
  a forgotten bump ships nothing.
- **Never reintroduce a second deployment target** (`target`, `manageDns`,
  `deployment_target`).
- **Never `kubectl create ns`**: platform namespaces are declared in
  `src/kubernetes/charts/cluster/values.yaml`, and an app's are created by its
  deploy as `<app>-<env>`.
- **Never name an app after anything but its owner**: `<brand>-<role>`
  (`jterrazz-console`, `signews-api`), one name for its release, image,
  volume, data directory and Infisical folder (ADR-023).
- **Never commit a secret**: Infisical holds them; `.env` holds only the
  identity that reads it.
- **Never rename a `<svc>-platform` release, a PV, or a `pathSuffix`**: they
  address live data.
- **Never add a hostname table to the platform contract**: each route's
  `smoke.jterrazz.com/*` annotations are its check, set in the values file or
  `application.yaml` that owns the route.
