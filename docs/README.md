# The manual

Everything this repository knows about itself: one cluster on one machine, the
charts apps deploy through, and what breaks. Each page owns its subject;
nothing here is written twice.

## Guides

| Page                                             | Holds                                                                          |
| ------------------------------------------------ | ------------------------------------------------------------------------------ |
| [develop](guides/develop.md)                     | How a change is made: what it owes, the config rules, the conventions, DNS     |
| [test](guides/test.md)                           | What proves a change: the tree-side checks, the upgrade test, the platform contract |
| [operate](guides/operate.md)                     | Secrets, troubleshooting, repaving, backups, rotations, adding a service or app |
| [resurrect-hetzner](guides/resurrect-hetzner.md) | How to bring a rented target back from git history                             |

## Concepts

| Page                                     | Holds                                                                        |
| ---------------------------------------- | ---------------------------------------------------------------------------- |
| [architecture](concepts/architecture.md) | The machine, the four layers, the three charts, the traffic paths, the tree |

## Reference

| Page                                                | Holds                                                         |
| --------------------------------------------------- | ------------------------------------------------------------- |
| [deploy-contract](reference/deploy-contract.md)     | What an app repo owes the cluster and what it gets back       |
| [ci](reference/ci.md)                               | The four workflows and what triggers each                     |
| [hand-synced-pairs](reference/hand-synced-pairs.md) | The facts written down twice, each with what catches a drift  |
| [platform-services](reference/platform-services.md) | What runs on the cluster that is not an app                   |

The decisions stand in [decisions/](decisions/), numbered and chronological,
beside their mold `_template.md`. Each chart and each multi-part service keeps
its reference in a README beside its values, under `src/kubernetes/`.
