# CI

Four workflows: what each one is triggered by and what it does. What the checks
inside them actually prove is [Test](../guides/test.md).

Two read the tree, one deploys to a throwaway cluster, one reads the real cluster.

| Workflow               | Trigger                                                                                          | Does                                                                                                                                                                                             |
| ---------------------- | ------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `validate.yaml`        | PR to main and push to main                                                                    | shellcheck on `scripts/`; `ansible-lint -c ansible/.ansible-lint` + `--syntax-check` on both playbooks; kubeconform over `kubernetes/cluster` and every raw manifest under `kubernetes/services`; both charts rendered against their `ci/test-values.yaml`; `helmfile template` over every declared release. Plus gitleaks, helm-unittest, assertions on the hand-synced pairs, and `make docs` for the manual's layout. |
| `deploy-platform.yaml` | push to main touching `ansible/**`, `kubernetes/{services,cluster,charts}/**`; or manual   | Runs `platform.yml` only, over Tailscale, from a runner joined as `tag:ci`. Never the host layer: those roles restart sshd/tailscaled and would kill the runner's own session.                    |
| `upgrade-test.yaml`    | PR to main and push to main touching `ansible/**` or `kubernetes/**`; or manual (`base` input) | Deploys a k3d cluster with `platform.yml` from the base tree, then upgrades it with this tree; each pass ends on `helm list --failed`. [Test](../guides/test.md#the-upgrade-test-runs-the-deploy-itself) |
| `smoke.yaml`           | after `deploy-platform.yaml` completes; weekly schedule; or manual                                  | Runs `scripts/smoke.sh --public --private --certs` against the live cluster, the only workflow that checks the deployed state rather than the tree. It lists every IngressRoute (kubectl on the node, over the deploy SSH key) and probes what each one's `smoke.jterrazz.com/*` annotations say, so a surface an app added yesterday is checked with no edit here. |

`make check` runs the tree-side checks locally, under the name every app repo
uses (`make lint` is an alias). It is not the whole of `validate.yaml`: what
only CI runs, and why, is [Test](../guides/test.md#what-only-ci-runs).

A merge to main deploys nothing on its own. `deploy-platform.yaml` is filtered
to `ansible/**` and `kubernetes/{services,cluster,charts}/**`, and it is also
the one publisher of the app chart (`roles/platform/tasks/publish-app-chart.yml`);
a change touching neither (this corpus, for instance) merges and stops there.
