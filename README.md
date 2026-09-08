# @jterrazz/infrastructure

One cluster on one machine: single-node k3s on an OrbStack VM on the dev Mac.
Public traffic enters through an outbound Cloudflare tunnel, private traffic
over the tailnet, and nothing listens on a public address. Apps live in their
own repositories and deploy themselves through the `app` chart published from
here.

## Quick start

```bash
make deploy           # create the VM if absent + ansible site.yml — the whole machine
make deploy-platform  # ansible platform.yml only — everything above k3s
make diff             # what a deploy would change, without changing it (helmfile diff)
make redeploy-apps    # trigger every app's CI to rebuild + redeploy
make destroy          # delete the VM (the Mac-side data directory stays)
make check            # the checks CI runs, locally (alias: make lint)
make check-tools      # ansible / kubectl / orbctl / helm / helmfile / shellcheck / ansible-lint / python3 present?
make kubeconfig       # regenerate ./kubeconfig.yaml from the VM (needs the tailnet)
```

`scripts/deploy.sh` is the entry point behind all of them. It sources the
tokens in `.env`, pulls the Ansible-bound secrets from Infisical through
`scripts/infisical-vars.py` into a 0600 tempfile, and runs the playbook. A
missing secret hard-fails the run; there are no fallback defaults.

## Documentation

[docs/README.md](docs/README.md) is the map of the corpus. Start at
[docs/01-architecture.md](docs/01-architecture.md) to understand the system,
[docs/05-deploy-contract.md](docs/05-deploy-contract.md) to deploy an app, and
[docs/04-operating.md](docs/04-operating.md) when something is broken.
