import * as command from "@pulumi/command";
import * as pulumi from "@pulumi/pulumi";
import * as os from "os";
import * as path from "path";

/**
 * The one machine this stack manages: the OrbStack VM that runs k3s and the
 * platform stack. It is `orbctl` wrapped in a `local.Command` — Pulumi has no
 * first-party OrbStack provider.
 *
 * MACHINE_NAME is the cluster's identity in three places at once: the
 * `orbctl list` name, the Ansible `inventory_hostname`, and the Tailscale
 * hostname every private CNAME in dns.ts resolves to. It and the image below
 * stay hardcoded: as stack config, a stack that omitted a key booted a VM under
 * the wrong identity and broke every private hostname.
 */
const MACHINE_NAME = "jterrazz-infrastructure";

export function createMachine(): { tailscaleHostname: pulumi.Output<string> } {
    const config = new pulumi.Config("orbstack");
    const dataPathOnMac =
        config.get("dataPath") || path.join(os.homedir(), ".jterrazz-infrastructure", "data");

    // `mkdir -p` first and in the same command: the Ansible base role symlinks
    // /var/lib/k8s-data at this dir, and if it does not exist before the VM
    // boots the symlink dangles and every hostPath mount fails at the first pod
    // schedule. The dir living on the Mac is also what makes the data survive
    // `pulumi destroy && pulumi up` — the VM goes, the dir stays.
    //
    // NO `--isolated`, for two independent reasons. It is not a missing
    // capability — an isolated machine has the full capability set (`CapEff:
    // 000001ffffffffff`) — the mount fails because isolated machines run in an
    // unprivileged user namespace, and the kernel refuses `noswap` there:
    //   "tmpfs: Turning off swap in unprivileged tmpfs mounts unsupported"
    // — which is exactly the mount kubelet needs for projected service-account
    // tokens (k8s >= 1.31), so k3s's API never comes up.
    // Second reason, sufficient on its own: non-isolated mode is what
    // auto-mounts the Mac at /mnt/mac that the symlink above resolves through.
    // NO `-u root`: broken since OrbStack 2.2.0 (its setup runs
    // `usermod --uid 501 root`, which fails against PID 1). The VM keeps the
    // default macOS-named user; Ansible connects as `root@<vm>@orb`.
    // `debian:trixie` spelled out: Debian is the one distro whose bare image
    // name resolves to the PREVIOUS stable, and every Ansible role here is
    // Debian-13-native.
    const create =
        pulumi.interpolate`mkdir -p '${dataPathOnMac}' && orbctl create -a arm64 debian:trixie ${MACHINE_NAME}`;

    new command.local.Command(MACHINE_NAME, {
        create,
        // A missing VM is success: after a manual delete, delete-before-replace
        // runs this against a VM that is already gone.
        delete: `orbctl delete --force ${MACHINE_NAME} || true`,
        // The whole create line, so ANY change to it replaces the VM: OrbStack
        // cannot change image, arch or mounts in place, and `create` on its own
        // is not replace-on-change — a diff there would re-run create against
        // the live VM as an "update" and fail on the existing name.
        //
        // Deliberately NOT a probe of whether the VM still exists. Any function
        // of presence alone flip-flops (absent before the create that fixes it,
        // present after) and repaves on every second up; making it converge
        // needs a marker file on the Mac side, i.e. a hidden file in the data
        // directory whose deletion silently destroys the cluster. A VM deleted
        // outside Pulumi is not a supported path — recover with
        // `pulumi state delete <urn>` then `pulumi up`.
        triggers: [create],
    }, {
        // REQUIRED. VM names are unique within OrbStack, so Pulumi's default
        // create-before-delete replacement can never succeed: it would create
        // the new VM while the old one still holds the name. Safe because the
        // data lives on the Mac side.
        deleteBeforeReplace: true,
    });

    return { tailscaleHostname: pulumi.output(MACHINE_NAME) };
}
