# CI

Four workflows: what each one is triggered by and what it does. What the checks
inside them actually prove is [Test](../guides/test.md).

Two read the tree, one deploys to a throwaway cluster, one reads the real cluster.

| Workflow               | Trigger                                                                                          | Does                                                                                                                                                                                             |
| ---------------------- | ------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `validate.yaml`        | PR to main and push to main                                                                    | shellcheck on `src/scripts/`; `ansible-lint -c src/ansible/.ansible-lint` + `--syntax-check` on both playbooks; kubeconform over `src/kubernetes/cluster` and every raw manifest under `src/kubernetes/services`; both charts rendered against their `ci/test-values.yaml`; `helmfile template` over every declared release. Plus gitleaks, helm-unittest, assertions on the hand-synced pairs, `make docs` for the manual's layout, and `typescript check` over the harness. |
| `deploy-platform.yaml` | push to main touching `src/ansible/**`, `src/kubernetes/{services,cluster,charts}/**`; or manual   | Runs `platform.yml` only, over Tailscale, from a runner joined as `tag:ci`. Never the host layer: those roles restart sshd/tailscaled and would kill the runner's own session. Then the host specs (`specs/specs/host`) over the same SSH connection. |
| `upgrade-test.yaml`    | PR to main and push to main touching `src/ansible/**`, `src/kubernetes/**` or `specs/**`; or manual (`base` input) | Deploys a k3d cluster with `platform.yml` from the base tree, then upgrades it with this tree; each pass ends on `helm list --failed`. Then `specs/{cluster,admission}` against it, as admin. [Test](../guides/test.md#the-upgrade-test-runs-the-deploy-itself) |
| `smoke.yaml`           | after a successful `deploy-platform.yaml`; weekly schedule; or manual                                  | Runs the platform contract (`specs`) against the live cluster, the only workflow that checks the deployed state rather than the tree, from two jobs: one on the tailnet (every route and certificate, the cluster's invariants, `private_hostnames`), reading the cluster as its own OIDC identity through `platform-reader`; one on the bare internet (public routes, and every private host unreachable), against the IngressRoutes the first job snapshotted. Routes are discovered, so a surface an app added yesterday is checked with no edit here. [Test](../guides/test.md#what-a-deploy-proves) |

`make check` runs the tree-side checks locally, under the name every app repo
uses (`make lint` is an alias). It is not the whole of `validate.yaml`: what
only CI runs, and why, is [Test](../guides/test.md#what-only-ci-runs).

A merge to main deploys nothing on its own. `deploy-platform.yaml` is filtered
to `src/ansible/**` and `src/kubernetes/{services,cluster,charts}/**`, and it is also
the one publisher of the app chart (`roles/platform/tasks/publish-app-chart.yml`);
a change touching neither (this corpus, for instance) merges and stops there.
