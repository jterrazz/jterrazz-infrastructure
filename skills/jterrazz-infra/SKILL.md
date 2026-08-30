---
name: jterrazz-infra
description: Infrastructure and deployment for jterrazz projects — k3s, Helm, Traefik, CI/CD deploy. Use when deploying apps, configuring Kubernetes, adding domains, or troubleshooting infra.
---

# @jterrazz Infrastructure

One k3s cluster on one machine: an OrbStack VM (`jterrazz-infrastructure`,
Debian 13 trixie, arm64) on the dev Mac. Pulumi provisions it, Ansible
configures it, Helmfile deploys onto it — every platform release declared
once in `kubernetes/helmfile.yaml.gotmpl`. Public traffic enters through a Cloudflare
tunnel; private services are tailnet-only. Apps live in their own repos and
deploy themselves through the shared `app` chart published here. Hetzner is a
recipe in `docs/hetzner.md`, not a live mode.

## Where things are documented

| Need                                          | Read                                   |
| --------------------------------------------- | --------------------------------------- |
| How it fits together, layout, CI              | `README.md`                             |
| Secrets, troubleshooting, repave, restore     | `docs/RUNBOOK.md`                       |
| Non-inferable gotchas + hand-synced pairs     | `CLAUDE.md`                             |
| `application.yaml` schema (deploying an app)  | `kubernetes/charts/app/README.md`       |
| Per-service detail (cloudflared, librechat, openpanel) | `kubernetes/services/<svc>/README.md` |
| Every other service                           | its release block in `kubernetes/helmfile.yaml.gotmpl` + comments in its `helm.yaml` / `platform.yaml` |
| Bringing the Hetzner target back              | `docs/hetzner.md`                       |

## Commands

```bash
make deploy           # pulumi up + ansible site.yml
make deploy-platform  # ansible platform.yml only (everything above k3s)
make diff             # what a deploy would change
make redeploy-apps    # trigger every app's CI to rebuild + redeploy
make destroy          # delete the VM (Mac-side data stays)
make check            # the checks CI runs (alias: make lint)
make check-tools      # required toolchain present?
make kubeconfig       # regenerate ./kubeconfig.yaml from the VM

orb -m jterrazz-infrastructure -u root kubectl get pod -A   # cluster access
kubectl rollout restart -n platform-networking \
  deploy/cert-manager deploy/cert-manager-webhook deploy/cert-manager-cainjector

# One slice of the platform layer (tags: cluster-manifests, coredns, helm,
# bootstrap, raw-manifests, releases, chart-publish)
cd ansible && ansible-playbook playbooks/platform.yml \
  -i inventories/laptop.yml -e "@<extra-vars>" --tags raw-manifests

# One Helm release, rather than a tag — every release is declared in
# kubernetes/helmfile.yaml.gotmpl and helmfile selects by label or name.
./scripts/helmfile.sh diff -l name=grafana
```

## Never

- **Never unpin trixie** in `pulumi/src/targets/orbstack.ts` — `orb create
  debian` defaults to bookworm, and every Ansible role is Debian-13-native.
- **Never chain the two ipAllowList middlewares** (`private-access`,
  `cluster-internal-access`). Traefik ANDs them, so chaining allows strictly
  less, not more. Pick one per route.
- **Never pin a chart below the version its data was migrated by.** On-disk
  formats are one-way doors (mongod's featureCompatibilityVersion, Postgres
  majors, BoltDB).
- **Never edit a chart template without bumping `version:`** in its
  `Chart.yaml`. The app chart is consumed *unversioned* by every app, and both
  publish guards skip rather than overwrite — so a forgotten bump ships
  nothing, silently.
- **Never reintroduce a second deployment target** (`target`, `manageDns`,
  `deployment_target`). Single target is the point of the current shape.
- **Never `kubectl create ns`** — namespaces are declared in
  `kubernetes/cluster/namespaces.yaml`.
- **Never commit secrets** — Infisical holds them; `.env` holds only the
  machine-identity credentials that bootstrap it.
- **Never delete a PVC without checking `/var/lib/k8s-data`** first. PVs are
  `Retain`, and a stale `claimRef` blocks rebinding.
- **Never skip Cloudflare Full (Strict)** SSL mode on a new zone.
