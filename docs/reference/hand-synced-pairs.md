# Hand-synced pairs

Facts this repo has to write down twice. Nothing enforces them at runtime and
each has drifted at least once: change one side, change the other.

The table is the discipline, not just its content, and the goal is an empty
one. A fact with two homes drifts, so the first answer is always to give it
one: every tool version now lives in one file that CI reads (`group_vars`,
`ansible/requirements.txt`, the Makefile), the secret list in `infisical_secrets`,
the busybox digest is moved in one Renovate PR, and the rate limiter keys on
`Cf-Connecting-Ip` instead of re-listing Traefik's trusted hops. What is left
below cannot have one home, so every row names what catches a drift, or admits
nothing does.

| A                                                     | B                                                        | Checked by | Why they must match                                                    |
| ----------------------------------------------------- | -------------------------------------------------------- | ---------- | ---------------------------------------------------------------------- |
| `private_hostnames` + `private_hostnames_via_traefik` (`group_vars/all.yml`) | the tailnet-only IngressRoutes in the live cluster | `scripts/smoke.sh`, at run time, both ways | Not a file pair: the live routes are side B, so the check cannot go stale the way a second table does. A name here that nothing serves is CoreDNS answering for a dead surface; a tailnet-only route missing from here resolves through the public CNAME chain instead. |
| the `infisical` release's `version:` (`kubernetes/helmfile.yaml.gotmpl`) | `kubernetes/schemas/secrets.infisical.com/infisicalsecret_v1alpha1.json` | nothing; a stale schema still validates | The vendored schema overrides a datreeio catalog copy that differs in exactly one way: the catalog sets `additionalProperties: false` at every object level, while the operator's own CRD does not (the API server prunes unknown fields rather than refusing the object). Bump the chart, re-extract the CRD (the regeneration command is in `kubernetes/schemas/README.md`). Skip it and CI validates against a CRD the cluster no longer has, so the break lands at `kubectl apply`. |
| `security_ci_deploy_pubkey` (`roles/security/defaults/main.yml`) | GitHub secret `CI_DEPLOY_SSH_PRIVATE`              | nothing; B lives outside the repo | Split keypair. Rotating needs both plus a `make deploy` to roll the pubkey onto the VM. |
| `k3s_oidc_audience` (group_vars)                      | `audience:` default of `jterrazz-actions/actions/docker-deploy` | nothing; a mismatch fails every app deploy at its first `kubectl` | The apiserver accepts a GitHub OIDC token for exactly one audience. Change both, host layer first (`make deploy`), or every app deploy is refused as unauthenticated. |
| `version:` in `charts/app/Chart.yaml`                 | the published OCI chart                                   | nothing at PR time; B lives in the registry | The chart is pulled unversioned by every app. Two publish guards exist (`scripts/publish-app-chart.sh` via `publish-chart.yaml`, and `roles/platform/tasks/publish-app-chart.yml`) and both skip rather than overwrite, so forgetting the bump publishes nothing, silently. |
| a service's `network:` block (`services/<x>/service.yaml`) | its namespace file (`cluster/network-policies/<ns>.yaml`) | nothing; policies union, so neither side can detect the other | One split, applied by hand: the namespace baseline (default-deny, allow-same-namespace, namespace-wide DNS/egress) stays in `cluster/`; anything naming one workload moves into that service's `network:`. Declare a rule in both and you get harmless duplication; declare it in neither and the packet is dropped by the default-deny with nothing logged anywhere. |
| `ci/test-values.yaml` fixtures                        | the chart templates                                       | nothing; no equality to assert | Both charts render near-zero objects with default values, so CI only exercises the fixtures (`helm lint` / `template` / `unittest`); it cannot tell that a new template branch went unfixtured. `charts/common` has no fixture at all (a library chart renders nothing on its own), so every branch it holds (each NetworkPolicy peer form, each middleware) is reached only through these two files. |
