# Agent brief

One k3s cluster on one machine, deployed by one script. This file routes; the
knowledge is in [docs/](docs/README.md).

## Mental model

`scripts/deploy.sh` creates an OrbStack VM on the Mac, Ansible configures it,
Helmfile deploys onto it. Above the machine there are four layers — host,
cluster, platform services, apps — and three Helm charts, one of them a library
the other two share. Apps are not deployed from here: they render through the
`app` chart this repo publishes, and the cluster is discovered from annotations
rather than from a list.

Two properties explain most of the tree. There is no provisioning state: the
VM's existence is the state. And there is no second target: Hetzner was
removed, so a `target` / `manageDns` / `deployment_target` branch is never the
answer.

## Where to read

| Question                                             | Chapter                                                  |
| ---------------------------------------------------- | --------------------------------------------------------- |
| How does the system fit together? What is the layout? | [docs/01-architecture.md](docs/01-architecture.md)        |
| I am deploying or configuring an app                  | [docs/02-deploy-contract.md](docs/02-deploy-contract.md)  |
| What does CI run, and what does it not check?         | [docs/03-ci.md](docs/03-ci.md)                            |
| Why is this laid out this way? Who owns DNS?          | [docs/04-conventions.md](docs/04-conventions.md)          |
| I am editing a values file, manifest or template      | [docs/05-config-discipline.md](docs/05-config-discipline.md) |
| I am changing a version, a digest or a shared value   | [docs/06-hand-synced-pairs.md](docs/06-hand-synced-pairs.md) |
| Something behaves in a way the tree does not explain  | [docs/07-gotchas.md](docs/07-gotchas.md)                  |
| What runs on the cluster, and where is its detail?    | [docs/08-platform-services.md](docs/08-platform-services.md) |
| Secrets, troubleshooting, repave, restore, add a service | [docs/09-runbook.md](docs/09-runbook.md)               |
| How do I bring a rented target back?                  | [docs/10-hetzner.md](docs/10-hetzner.md)                  |
| The `application.yaml` schema                         | [kubernetes/charts/app/README.md](kubernetes/charts/app/README.md) |
| What the two charts share                             | [kubernetes/charts/common/README.md](kubernetes/charts/common/README.md) |
| One service's versions, data paths and quirks         | `kubernetes/services/<svc>/README.md`                     |

## Before you commit

`make check` runs what CI runs on the tree: shellcheck, python syntax, the
cross-file sync assertions, ansible-lint, helm lint and unittest, actionlint.
A change to a chart template also needs its `version:` bumped — the app chart
is consumed unversioned, and both publish guards skip rather than overwrite.
