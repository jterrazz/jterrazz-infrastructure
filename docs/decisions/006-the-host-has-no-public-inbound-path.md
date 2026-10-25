# ADR-006: The host has no public inbound path, and OrbStack peers are walled off

**Status:** Accepted
**Date:** 2026-07-26

Written 2026-10-24 from the comments in `src/ansible/roles/{security,tailscale}`
and the k3s templates (commit 2885ec2, extended by the 2026-10-24 audit) that
this record replaces.

Revised 2026-10-25: the guard no longer names port 2000, which nothing on the
host binds since cloudflared left the host network.
Revised 2026-10-25: the guard is the node's one firewall, a default deny on the
tailnet and the bridge; UFW is gone, OpenSSH's own algorithms are kept.

## Context

Nothing on the host faces the internet: public traffic arrives through the
Cloudflare tunnel, everything else over Tailscale or OrbStack's SSH proxy.
The neighbours are the threat. OrbStack puts every machine on one bridge
(192.168.139.0/24) and mounts every other machine's rootfs at
`/mnt/machines/<name>/`, readable as root, so file modes are no boundary: a
plain `orb create` machine could read the datastore and the kubeconfig. And
UFW was not the gate it looked like: k3s inserts iptables rules ahead of
UFW's INPUT filter, so `ufw default deny incoming` did not stop a peer from
reaching node-exporter:9100, cloudflared:2000 or kubelet:10250; all three
answered a neighbouring machine.

## Decision

- **One firewall, an nftables guard** (`table inet jterrazz_guard`, input
  hook at priority -10, ahead of k3s' own rules): loopback and established
  traffic pass; the NodePort range is dropped from every source, because a
  NodePort answers on the node address and bypasses the tailnet gate (audit
  2026-10-24); pods reach the node over cni0; the tailnet reaches 22, 80, 443
  and 6443 and nothing else, so neither the kubelet nor node-exporter answers
  it; and on the OrbStack bridge only the hypervisor host (how `orb`, Ansible
  and every Mac tool reach the VM) and DHCP's replies pass. UFW, which held a
  weaker copy of the same rules behind k3s' iptables chains, is gone. The
  first gate for 80/443 is Traefik's `loadBalancerSourceRanges`.
- **Secrets encrypted at rest** (`secrets-encryption: true`): without it every
  Secret sits in plaintext in `state.db`, readable through `/mnt/machines`.
  Enabling encrypts only new writes, so the role runs
  `k3s secrets-encrypt reencrypt --force` once. Verify by value (decode a
  real Secret, grep `state.db` for it), never by counting `password`, which
  CRD schemas and ConfigMaps dominate.
- **An API audit log** at Metadata level (never bodies, which would put
  Secret contents in a plaintext file), with `None` rules for the
  control plane's own reads, leases and health endpoints, which are no
  evidence and would fill the datastore's volume; rotated 30 days, 3 backups,
  64MB.
- **The kubeconfig is written 0600**, as defence in depth; the guard is what
  closes the cross-machine read.
- **sshd is hardened by a drop-in** with `Include` forced to the top of
  `sshd_config` (the first occurrence of a keyword wins, so an Include at the
  bottom is inert) and two-stage validation: the candidate file before it
  moves, then `sshd -t` on the effective config, with a rescue that removes
  the drop-in rather than restart into a lockout. The CI deploy key's public
  half is installed here (rotation:
  [Operate](../guides/operate.md#rotating-credentials)).
- **Tailscale is joined by one script**, `tailscale-autoauth.sh`, run by a
  unit at every boot (a node-key expiry leaves tailscaled "Logged out" after
  a reboot, and a logged-out node NXDOMAINs the registry, so every pod
  ImagePullBackOffs and Cloudflare 503s) and by the play. It is the only
  spelling of `tailscale up`: `--accept-dns=true` is load-bearing (MagicDNS
  resolves the `*.ts.net` targets), and `--snat-subnet-routes=false`
  overrides a default that tailscaled 1.102 started applying to every
  forwarded packet, which made klipper-lb see 10.42.0.1 instead of a tailnet
  source and drop every SYN (seen 2026-09-19).
- **fail2ban and auditd are absent on purpose**: fail2ban would guard a public
  SSH port that does not exist, and auditd needs `CAP_AUDIT_*`, which the
  hypervisor withholds.

## Consequences

- Dev machines beside the cluster should be created with `--isolated`;
  `--isolate-network` does not block peers, despite the docs, which is why
  the guard exists. The node itself cannot be `--isolated` (kubelet's
  `noswap` tmpfs is refused and k3s restart-loops).
- Tailnet reachability must be tested from a peer, never from the node,
  whose own traffic takes the OUTPUT path
  ([Operate](../guides/operate.md#test-the-tailnet-path-from-a-peer)).
- Comments inside the rendered host files (nftables, k3s config) are file
  content: editing them re-renders the file and fires its handler.
