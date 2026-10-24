# The manual

Everything this repository knows about itself: one cluster on one machine, the
charts apps deploy through, and what breaks. Each page owns its subject;
nothing here is written twice. The pages are cut by what a reader came to do.

## Guides

| Page                                         | Holds                                                                                   |
| -------------------------------------------- | --------------------------------------------------------------------------------------- |
| [develop](guides/develop.md)                 | How a change is made: the gate, the five config rules, the conventions, DNS owners      |
| [test](guides/test.md)                       | What proves a change: the tree-side checks, the chart fixtures, the platform contract         |
| [operate](guides/operate.md)                 | Secrets, troubleshooting, repaving, backups, restores, adding a service or app          |
| [resurrect-hetzner](guides/resurrect-hetzner.md) | How to bring a rented target back, from git history                                 |

## Concepts

| Page                                      | Holds                                                                    |
| ----------------------------------------- | ------------------------------------------------------------------------ |
| [architecture](concepts/architecture.md)  | The machine, the four layers, the three charts, the traffic paths, the tree |

## Reference

| Page                                                  | Holds                                                                       |
| ----------------------------------------------------- | --------------------------------------------------------------------------- |
| [deploy-contract](reference/deploy-contract.md)       | What an app repo owes the cluster and what it gets back                     |
| [ci](reference/ci.md)                                 | The four workflows, what triggers each, and what a merge does not do        |
| [hand-synced-pairs](reference/hand-synced-pairs.md)   | The facts written down twice, each with its checker or an admission it has none |
| [platform-services](reference/platform-services.md)   | What runs on the cluster that is not an app                                 |

The decisions this repository took alone stand in [decisions/](decisions/),
numbered and chronological, with the mold `_template.md` beside them.

Reference documentation for the charts lives beside them, in
`kubernetes/charts/<chart>/README.md`; a multi-part platform service keeps its
own README beside its values files.
