# Resurrecting a Hetzner target

This repo used to be dual-mode: the same `site.yml` configured either a Hetzner
cax21 VPS (`jterrazz/production`) or the OrbStack VM (`jterrazz/local`). The
Hetzner half was removed — unused since the May 2026 swap to OrbStack, and it
cost a `deployment_target` branch in every role plus an inventory nobody ran.

**Pulumi itself is gone too.** One VM and two never-changing DNS records did not
pay for a language, a lockfile, a CI job, a state backend and a token: today
`scripts/deploy.sh` runs the single `orbctl create` (`vm_up` / `vm_destroy`) and
the records are hand-made facts written down in
[RUNBOOK.md](RUNBOOK.md#dns-records-set-once-survive-everything). The last commit
that still contained a `pulumi/` directory is **`487f370`**, so every file named
below is readable with `git show 487f370:pulumi/src/dns.ts` and friends — the
tree is in history, not in the working copy.

So a resurrection starts with a choice: restore `pulumi/` whole from `487f370`
and re-add the target removed below, or skip Pulumi entirely and drive the
`hcloud` CLI from `scripts/deploy.sh` the way `vm_up`/`vm_destroy` drive
`orbctl` — one server, one SSH key, one firewall, three commands.

Nothing was deleted destructively. The last tree with both targets is the parent
of the single-target restructure commit, `dfc3c78^` — verify rather than trust
that SHA: `git log --diff-filter=D --name-only -- pulumi/src/targets/hetzner.ts`
finds the removal, `git show <sha>^:<path>` prints any file as it was. What you
would restore:

- `pulumi/src/targets/hetzner.ts` (hcloud Server + SSH key + firewall,
  `image: debian-13` — the genericcloud arm64 image; do **not** take Hetzner's
  default, it is the previous stable), the `MachineOutputs` interface
  (`targets/types.ts`), the `target` dispatch in `src/index.ts`, and the
  `@pulumi/hcloud` + `@pulumi/tls` dependencies.
- A second inventory, `ansible/inventories/hetzner.yml` in today's flat layout
  (it was `inventories/production/hosts.yml`): group `cluster`, host
  `jterrazz-vps`, `ansible_host` + `ansible_ssh_private_key_file` from the
  Pulumi outputs (`sshHost`, `sshPrivateKey --show-secrets`).
- The `deployment_target` var and its `when:` branches (the `/dev/kmsg`
  backfill and the `/var/lib/k8s-data` Mac symlink are OrbStack-only; plain
  `mkdir /var/lib/k8s-data` is the Hetzner path), plus `ansible_host` back in
  the k3s TLS SAN list (on Hetzner it is a real public IP).
- `scripts/deploy.sh`'s positional target, its SSH-key tempfile helper, and the
  `manageDns` guard below — that one is not optional.

Stack init, once `pulumi/` is restored (its `Pulumi.local.yaml` came back
with it; `production` never had a committed one):

```bash
cd pulumi
pulumi stack init jterrazz/production
pulumi config set jterrazz-infrastructure:target hetzner
pulumi config set --secret hcloud:token <hetzner-api-token>
pulumi config set --secret cloudflare:apiToken <cloudflare-dns-edit-token>
pulumi up
```

**DNS**: without Pulumi this is a one-record edit — repoint the `*.internal`
CNAME at the new host's tailnet name in the Cloudflare dashboard
([RUNBOOK.md](RUNBOOK.md#dns-records-set-once-survive-everything)) and there is
nothing to guard. If you DO restore `pulumi/`, restore the `manageDns` guard
with it — only ONE stack may have `jterrazz-infrastructure:manageDns: "true"` at
a time, or whichever ran `pulumi up` last silently owns every private CNAME.
Either way, after a swap run `make redeploy-apps`: every app image lives in the
old cluster's registry and has to be re-pushed.
