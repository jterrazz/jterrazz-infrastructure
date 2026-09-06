# Gotchas

Repo-specific behaviour the tree does not show, each one paid for at least
once.

## The VM

- **`orb create debian` gives you bookworm.** Debian is the one distro where
  OrbStack's bare image name resolves to the previous stable, so `vm_up` in
  `scripts/deploy.sh` spells out `debian:trixie`. Never drop the tag — every
  Ansible role is Debian-13-native (deb822 repositories, socket-activated
  sshd, systemd-resolved as a separate package).
- **`orbctl create -u root` is broken** since OrbStack 2.2.0: its setup runs
  `usermod --uid 501 root`, which fails against PID 1. The VM is created with
  the default macOS-named user; Ansible connects as `root@<vm>@orb`.
- **Other OrbStack machines read this VM's filesystem as root.**
  `/mnt/machines` makes file modes irrelevant, so `0600` on the kubeconfig is
  defence in depth, not a fix. The controls that work are the nftables guard in
  `roles/security` and creating dev machines with `--isolated`.
- **`make deploy-platform` from the Mac dies at fact-gathering — OPEN, 2026-09-06.**
  `ansible.legacy.setup` over the `orb` connection returns an empty
  `module_stdout` and the play fails with `Module result deserialization
  failed: No start of json char found`. The same playbook is green from
  `deploy-platform.yaml` (which reaches the VM over SSH on the tailnet), so the
  suspect is the local `orb` connection, not the play. Not fixed, not
  worked around: the workflow is the way in until it is.
- **`chmod` cannot protect `/var/lib/k8s-data`.** Pods write through virtiofs
  as uids 70/101/472/999/1000; dropping world-execute breaks Postgres,
  ClickHouse, Mongo, Grafana and signews-api at once. Encrypt what leaves the
  tree (`make backup`) instead of tightening the tree.

## DNS on the VM

**OrbStack DHCP hands out a bogus resolver** (`0.250.250.200`) that silently
drops queries, and it takes two fixes, not one. `upstream.conf` sets the global
resolver; `UseDNS=false` removes the per-link one. The `resolved` role writes
both: `/etc/systemd/resolved.conf.d/upstream.conf` (`DNS=1.1.1.1 9.9.9.9`) and
a systemd-networkd drop-in at
`/etc/systemd/network/eth0.network.d/10-no-dhcp-dns.conf`.

Do not diagnose this by looking for a missing `upstream.conf`. That was the old
note here and it is wrong: `upstream.conf` was present the whole time the bogus
resolver was still in use, because a global `DNS=` cannot displace a
DHCP-supplied link server. The real check is the uplink file, which is the one
kubelet pins and therefore the one CoreDNS forwards to:

```bash
orb -m jterrazz-infrastructure -u root cat /run/systemd/resolve/resolv.conf
# want exactly: nameserver 1.1.1.1 / nameserver 9.9.9.9 — no third line
orb -m jterrazz-infrastructure -u root resolvectl status eth0
# want: "DNS Servers:" absent under Link N (eth0)
```

`/etc/resolv.conf` is useless for this: it is symlinked to `stub-resolv.conf`
and always shows a single `nameserver 127.0.0.53`. `networkctl status eth0 |
grep 'Network File'` names the file the drop-in must sit beside — the role
derives it rather than hardcoding `eth0.network`.

**kubelet's resolv-conf is pinned** to `/run/systemd/resolve/resolv.conf` in
`roles/k3s/templates/config.yaml.j2`. Point it at `/etc/resolv.conf` and
CoreDNS (which uses `dnsPolicy: Default`) forwards into its own 127.0.0.53 stub
and the loop plugin fatals on startup.

## Networking

- **cloudflared must run `hostNetwork: true`** on this target. The CNI bridge
  mangles outbound TCP/7844 to the Cloudflare edge and the tunnel handshake gets
  RSTed, while plain `curl` from the same pod IP works fine. `--protocol http2`
  is set for the same class of reason: OrbStack's NAT eats outbound UDP/443.
- **buildkit needs `network=host` in CI.** `jterrazz-actions/actions/docker-build`
  sets it so buildkit sees the runner's Tailscale resolver; without it
  `docker push registry.internal.jterrazz.com/…` NXDOMAINs on the public CNAME
  chain.
- **Tailscale identity collision.** A VM destroyed without `tailscale logout`
  leaves its device behind; the replacement joins as `<hostname>-2` and MagicDNS
  stops resolving the canonical name, which breaks every private hostname. The
  fix is in [09-runbook.md](09-runbook.md).
- **A kube-system NetworkPolicy must allow klipper-lb explicitly.** The svclb
  pods receive the node's own address after DNAT, so `allow-same-namespace`
  never covers them. Miss it and public traffic keeps working (cloudflared dials
  Traefik's ClusterIP) while every tailnet client, CI included, gets
  `connection refused` on 443.
- **Never chain `private-access` and `cluster-internal-access`.** Traefik ANDs
  chained ipAllowLists, so chaining allows strictly less, not more. The second
  is a strict superset of the first; a route picks one.

## Kubernetes objects

- **cert-manager loses its API connection after any k3s churn** — restart
  cert-manager, its webhook and cainjector together. This is the single most
  common cause of a stuck Certificate.
- **Helm adoption of existing objects** needs the annotations
  `meta.helm.sh/release-name` and `meta.helm.sh/release-namespace` plus the
  label `app.kubernetes.io/managed-by=Helm`, or the install fails on conflict.
- **Immutable fields mean delete-and-recreate**: Deployment selectors, PV
  `hostPath.type`, PVC `spec.selector`. Changing a `pathSuffix` or a PV name in
  a `service.yaml` moves live data — the current paths are byte-identical to
  what the pre-chart manifests produced, on purpose. The Helm release names
  `<x>-platform` are frozen for the same class of reason: the chart behind them
  is `platform-service`, but a renamed release is a new release, and the old one
  keeps the hostPath PV it bound.
- **Use fully-qualified CRD names** with kubectl: `certificate.cert-manager.io`,
  `ingressroute.traefik.io`.
- **Remove finalizers before deleting an `Application` object** when tearing
  down a controller that manages resources through it, or the cascade takes the
  managed resources with it. Learned dismantling ArgoCD, which is long gone from
  this tree — the lesson is kept because nothing here can teach it again.

## The fsync tax

**Every guest `fsync` costs about 135KB of Mac SSD writes, whatever it
commits.** OrbStack honours a guest `fsync()` with a real durable barrier,
macOS `F_FULLFSYNC`, which forces an APFS journal commit. macOS' own `fsync()`
does not: it only pushes to the drive cache. Measured, 2000 × 4KB files
created, fsynced and deleted: 7MB natively, 7MB from the VM with no fsync,
271MB from the VM with fsync, 281MB natively with `F_FULLFSYNC`. So the tax is
per-fsync, not per-byte and not virtiofs bandwidth — sequential writes run 1:1 —
and moving data into the VM's own disk image makes it worse (598MB), because
the guest filesystem's journal adds its own barriers on top.

This is why the storage-side tuning in this tree is all about issuing fewer
fsyncs, never about writing fewer bytes: `inmemoryDataFlushInterval` on the
three Victoria stores, `--appendfsync no` on OpenPanel's Redis. A store that
writes 15MB/day can cost tens of GB/day of SSD if it fsyncs on a 5s timer.
Upstream tracks the symptom in orbstack/orbstack#1332, open and undiagnosed;
there is no OrbStack setting for it, so the workload is the only lever.
