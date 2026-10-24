import { execFile } from 'node:child_process';
import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

/** The repository this harness sits in, whose root holds the kubeconfig `make kubeconfig` writes. */
export const REPOSITORY_ROOT = fileURLToPath(new URL('../../../', import.meta.url));

/** What one kubectl run answered: its exit code and both streams, never thrown. */
export type KubectlOutcome = { code: number; stderr: string; stdout: string };

/** A Kubernetes object, read as far as the harness reads one. */
export type KubeObject = {
    metadata: {
        annotations?: Record<string, string>;
        labels?: Record<string, string>;
        name: string;
        namespace?: string;
    };
};

/** A list kubectl prints for `get -o json`. */
export type KubeList<T extends KubeObject = KubeObject> = { items: T[] };

const REACH =
    'Reach the cluster with CLUSTER_KUBECTL="orb -m jterrazz-infrastructure -u root kubectl" (the Mac), ' +
    'KUBECONFIG=<file> (CI, k3d), or `make kubeconfig` (a machine on the tailnet).';

// invariant: in order: CLUSTER_KUBECTL (a whole command line, the Mac's `orb ... kubectl`), then
// $KUBECONFIG (CI's OIDC file, k3d's), then the repository's kubeconfig.yaml, then kubectl's own default.
/** The kubectl command line this machine reaches the API server with. */
export function kubectlCommand(env: NodeJS.ProcessEnv = process.env): string[] {
    const declared = env.CLUSTER_KUBECTL?.trim() ?? '';
    if (declared !== '') {
        return declared.split(/\s+/u);
    }
    const local = `${REPOSITORY_ROOT}kubeconfig.yaml`;
    if ((env.KUBECONFIG ?? '') === '' && existsSync(local)) {
        return ['kubectl', '--kubeconfig', local];
    }

    return ['kubectl'];
}

/** Runs kubectl with these arguments and `input` on its stdin; a non-zero exit is an outcome, not an exception. */
export async function kubectl(args: readonly string[], input = ''): Promise<KubectlOutcome> {
    const [program = 'kubectl', ...prefix] = kubectlCommand();

    return await new Promise((resolve) => {
        const child = execFile(
            program,
            [...prefix, ...args],
            { maxBuffer: 64 * 1024 * 1024 },
            (error, stdout, stderr) => {
                resolve({ code: exitCodeOf(error), stderr, stdout });
            },
        );
        child.stdin?.end(input);
    });
}

/** Runs kubectl with `-o json` and parses what it printed, or throws naming its stderr and how to reach the cluster. */
export async function kubectlJson(args: readonly string[], input = ''): Promise<unknown> {
    const outcome = await kubectl([...args, '-o', 'json'], input);
    if (outcome.code !== 0) {
        throw new Error(
            `kubectl ${args.join(' ')} exited ${String(outcome.code)}: ${outcome.stderr.trim()}\n${REACH}`,
        );
    }

    return JSON.parse(outcome.stdout);
}

/** Every object of a kind kubectl lists for these `get` arguments. */
export async function kubectlList<T extends KubeObject = KubeObject>(
    args: readonly string[],
): Promise<KubeList<T>> {
    const listed = await kubectlJson(['get', ...args]);
    if (!isKubeList<T>(listed)) {
        throw new Error(`kubectl get ${args.join(' ')} printed no list`);
    }

    return listed;
}

/** Whether a parsed JSON value is a list kubectl printed. */
export function isKubeList<T extends KubeObject>(value: unknown): value is KubeList<T> {
    return (
        typeof value === 'object' &&
        value !== null &&
        'items' in value &&
        Array.isArray(value.items)
    );
}

function exitCodeOf(error: null | { code?: null | number | string }): number {
    if (error === null) {
        return 0;
    }

    return typeof error.code === 'number' ? error.code : 1;
}
