# Testing

What proves a change here, and what nothing proves. There is no test suite in
the ordinary sense: the evidence is of two kinds — tree-side checks, which read
files and render templates with no cluster anywhere, and one black-box probe of
the deployed state. The workflows that carry both are [06-ci.md](06-ci.md).

## The tree-side checks

`make check` (alias `make lint`) is the local form of the `validate.yaml` jobs.
Each check answers for one thing:

| Check                                                            | Proves                                                                                          |
| ---------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| `shellcheck scripts/*.sh scripts/lib/*.sh`                       | the shell is not quietly wrong — quoting, unset vars, the classic word-split                    |
| `ast.parse` on `infisical-vars.py` and `assert-sync.py`          | both python scripts parse (and leave no `__pycache__/` behind, which `py_compile` would)        |
| `python3 scripts/assert-sync.py`                                 | every fact this repo writes down twice still agrees — the roster is [07-hand-synced-pairs.md](07-hand-synced-pairs.md) |
| `ansible-lint -c ansible/.ansible-lint ansible/`                 | the whole Ansible tree, roles and templates and inventories, not just `playbooks/`               |
| `ansible-playbook --syntax-check` on both playbooks              | each playbook parses against the inventory that actually runs it                                |
| `helm lint` on `common` alone, then `app` and `platform-service` against their `ci/test-values.yaml` | the charts render, and render something — see [the fixtures](#the-fixtures-are-the-validation-contract) |
| `helm unittest --strict app platform-service`                    | what the templates COMPUTED, not merely that the YAML is well-formed                            |
| `actionlint`                                                     | the workflow files themselves                                                                    |
| `make docs`                                                      | this corpus still opens on the estate's spine — the map bijective, the chapters contiguous, the four fixed names in place |

`--strict` on helm-unittest matters: it rejects an unknown key in a test file,
so a typo'd assertion name is an error rather than an assertion that silently
never runs.

Three of these are soft skips locally — `actionlint`, the helm-unittest plugin
and `make docs`, which needs node — because CI runs all three unconditionally,
so a laptop without them is not a gap in the gate. `make docs` runs the manual
gate of `@jterrazz/typescript`, pinned in the `Makefile`; the rule ids and the
sentence each one prints belong to that engine and are not copied here.
Everything else hard-fails, which is what stops
`make check` from printing all green on a machine where it checked nothing.

### What only CI runs

Four checks have no local half, because each needs a tool `make check` does not
insist on:

- **kubeconform**, over `kubernetes/cluster`, over each chart rendered with its
  fixture, and over every raw manifest under `kubernetes/services` — found by
  the one structural property that separates a manifest from a values file, a
  top-level `apiVersion:` key, which is the same test
  `roles/platform/tasks/raw-manifests.yml` applies. It is deliberately not
  paired with `-ignore-missing-schemas`: a CRD kind with no schema anywhere
  fails loudly rather than skipping validation of that object.
- **`helmfile template`** over `kubernetes/helmfile.yaml.gotmpl`, the only
  declaration of every platform release. It catches a bad chart version, a
  values file that moved, a `needs:` pointing at a release that no longer
  exists — each of which would otherwise surface mid-deploy, after some releases
  have already been upgraded.
- **gitleaks**, `--no-git` over the checked-out files. History is never scanned,
  on purpose: this repository predates any secret hygiene and its history holds
  credentials that have since been rotated, so scanning it would fail every run
  forever. The gate is there to stop a NEW secret from landing.
- **helm-unittest**, run unconditionally rather than as the local soft skip.

### helm-unittest asserts the computation

kubeconform proves each rendered object is schema-valid. It cannot see whether
the template computed the right value: a NODE_OPTIONS heap cap derived from the
wrong number, a dockerconfigjson whose escaping broke, an `access:` value that
silently picked the wrong ipAllowList are all perfectly valid YAML. That is the
gap helm-unittest fills.

The plugin embeds its own rendering library, so its output does not depend on
the helm CLI beside it — which is what keeps the committed `__snapshot__` files
reproducible between a laptop and a runner, and why the version in
`validate.yaml` and the one in the `Makefile` are a pair that must not drift.

## The fixtures are the validation contract

Both charts render near-zero objects with default values, so CI only exercises
what `ci/test-values.yaml` reaches: a template branch no fixture reaches is a
branch CI does not check. `charts/common` has no fixture at all — a library
chart renders nothing on its own — so every branch it holds, each NetworkPolicy
peer form and each middleware, is reached only through those two files.

Nothing can assert this. There is no equality between a fixture and a template
to check, so a new branch that went unfixtured looks exactly like a green run.
Adding a branch means adding the values that reach it, in the same change.

## What a deploy proves

A green `ansible-playbook` run is not the claim "the site loads". A platform
apply can succeed and still leave a service unreachable — a broken IngressRoute,
a middleware that no longer resolves, a pod that comes back CrashLooping after
`--wait` returned. `scripts/smoke.sh` is the check that closes that gap, and
`smoke.yaml` is the only workflow that reads the deployed state rather than the
tree.

It probes the front door: public hostnames through the Cloudflare tunnel,
private hostnames over the tailnet, and TLS expiry from the wire. The question
LIST is not in this repo — every IngressRoute carries its own contract as
`smoke.jterrazz.com/{path,expect,method,location,probe}` annotations, which the
charts stamp from facts the service already declares
(`kubernetes/charts/common/templates/_smoke.tpl`). A surface an app added
yesterday is probed today with no edit here.

Three things it refuses to read as fine:

- **Zero discovered routes is an error**, never "nothing to check" — that is a
  broken cluster or a broken query.
- **A route with no annotation is probed with the `GET / -> 200` fallback and
  named in the output**, because an unannotated route means an app has not
  redeployed onto the current chart, not that the surface is uninteresting.
- **A certificate within 15 days of expiry fails.** cert-manager renews at 30
  days remaining, so 15 means renewal has been failing for two weeks.

`smoke.yaml` runs after every SUCCESSFUL `deploy-platform.yaml` (a failed one
would only report the same failure a second time, dressed as an independent
signal), on a Monday 07:17 UTC schedule, and on demand. The schedule is the only
uptime monitor this repo has: nothing else notices a certificate that quietly
stopped renewing, or an app that died days after its last deploy.

Locally, `make smoke` probes `--public --certs` only — the private half needs
this machine on the tailnet — and `./scripts/smoke.sh --list` prints what it
discovered without probing anything.

## What nothing proves

- **No check here talks to a cluster except smoke.** `make diff` previews what a
  platform apply would change, but it is read-only and it needs a working
  kubeconfig; it is a habit before a deploy, not a gate.
- **A template branch no fixture reaches** — [above](#the-fixtures-are-the-validation-contract).
- **A stale vendored CRD schema still validates.** `kubernetes/schemas/` overrides
  the public catalog for the one CRD whose catalog copy lags the operator we
  run; bumping the `infisical` release without re-extracting it means CI
  validates against a CRD the cluster no longer has, and the break lands at
  `kubectl apply`. That pair has no checker — see
  [07-hand-synced-pairs.md](07-hand-synced-pairs.md).
- **`private_hostnames` against the live routes** is only ever checked at smoke
  time, both ways. Until a smoke run, a name CoreDNS answers for and nothing
  serves looks the same as a healthy list.
