import { afterAll, describe, expect, test } from 'vitest';

import { kubectl } from '../../__setup__/kubectl.ts';

// invariant: two repositories that exist nowhere but here, `a` acting and `b` the neighbour it must not touch;
// every request of `a` is a server-side dry run, so admission judges it and nothing is written.
const A = 'contract-probe-a';
const B = 'contract-probe-b';
const KEY = 'app.jterrazz.com/repository';
const AS_A = [
    `--as=github:jterrazz/${A}`,
    '--as-group=github-actions:jterrazz',
    '--as-group=system:authenticated',
];

const namespace = (name: string, labels: Record<string, string>): object => ({
    apiVersion: 'v1',
    kind: 'Namespace',
    metadata: { labels, name },
});

const volume = (name: string, path: string, owner: string): object => ({
    apiVersion: 'v1',
    kind: 'PersistentVolume',
    metadata: { labels: { [KEY]: owner }, name },
    spec: {
        accessModes: ['ReadWriteOnce'],
        capacity: { storage: '1Mi' },
        hostPath: { path },
        persistentVolumeReclaimPolicy: 'Retain',
    },
});

const binding = (inNamespace: string, role: string, user: string): object => ({
    apiVersion: 'rbac.authorization.k8s.io/v1',
    kind: 'RoleBinding',
    metadata: { name: 'contract-probe', namespace: inNamespace },
    roleRef: { apiGroup: 'rbac.authorization.k8s.io', kind: 'ClusterRole', name: role },
    subjects: [{ apiGroup: 'rbac.authorization.k8s.io', kind: 'User', name: user }],
});

const FIXTURES = [
    namespace(A, { [KEY]: A }),
    namespace(B, { [KEY]: B }),
    volume(`${B}-data`, `/var/lib/k8s-data/${B}`, B),
];

// invariant: a request is the kubectl arguments after the verb's own, and the manifest it sends, if any.
type Request = { args: string[]; manifest?: object };

const create = (manifest: object): Request => ({ args: ['create', '-f', '-'], manifest });

// invariant: admitted, the policy's own sentence when it denies, or the first line of any other refusal (RBAC's).
async function outcomeOf({ args, manifest }: Request): Promise<string> {
    const outcome = await kubectl(
        [...args, '--dry-run=server', ...AS_A],
        manifest === undefined ? '' : JSON.stringify(manifest),
    );
    if (outcome.code === 0) {
        return 'admitted';
    }
    const [refusal = ''] = outcome.stderr.trim().split('\n');
    const denied = /denied request: (?<reason>.+)$/u.exec(refusal)?.groups?.reason;

    return denied === undefined
        ? `refused: ${refusal.replace(/^.*?forbidden: /u, '')}`
        : `denied: ${denied}`;
}

// hazard: a namespace deletes asynchronously: the cleanup waits for it, or the next run would meet its
// fixtures terminating. Applying them is idempotent, so every test states them as its Given.
const FIXTURE_LIST = JSON.stringify({ apiVersion: 'v1', items: FIXTURES, kind: 'List' });

async function applyFixtures(): Promise<void> {
    const applied = await kubectl(['apply', '-f', '-'], FIXTURE_LIST);
    if (applied.code !== 0) {
        throw new Error(`the ownership fixtures did not apply, as admin: ${applied.stderr}`);
    }
}

afterAll(async () => {
    await kubectl(['delete', '--ignore-not-found', '-f', '-'], FIXTURE_LIST);
});

const CASES: [string, Request, string][] = [
    [
        'binds app-namespace-admin to itself in its own namespace',
        create(binding(A, 'app-namespace-admin', `github:jterrazz/${A}`)),
        'admitted',
    ],
    [
        'creates a namespace labelled as itself',
        create(namespace(`${A}-next`, { [KEY]: A })),
        'admitted',
    ],
    [
        'creates its volume at /var/lib/k8s-data/<name>',
        create(volume(`${A}-data`, `/var/lib/k8s-data/${A}`, A)),
        'admitted',
    ],
    [
        "binds itself in another app's namespace",
        create(binding(B, 'app-namespace-admin', `github:jterrazz/${A}`)),
        `denied: namespace ${B} is not owned by ${A}`,
    ],
    [
        'binds cluster-admin in its own namespace',
        create(binding(A, 'cluster-admin', `github:jterrazz/${A}`)),
        `refused: user "github:jterrazz/${A}" (groups=["github-actions:jterrazz" "system:authenticated"]) is attempting to grant RBAC permissions not currently held:`,
    ],
    [
        'binds app-namespace-admin to another subject',
        create(binding(A, 'app-namespace-admin', `github:jterrazz/${B}`)),
        'denied: an app RoleBinding binds app-namespace-admin to its own identity only',
    ],
    [
        'writes into a platform namespace',
        create(binding('platform-telemetry', 'app-namespace-admin', `github:jterrazz/${A}`)),
        `denied: namespace platform-telemetry is not owned by ${A}`,
    ],
    [
        'creates a namespace labelled as another repository',
        create(namespace(`${A}-stolen`, { [KEY]: B })),
        `denied: namespaces ${A}-stolen must carry ${KEY}=${A}`,
    ],
    [
        'creates its namespace with a privileged Pod Security label',
        create(
            namespace(`${A}-privileged`, {
                [KEY]: A,
                'pod-security.kubernetes.io/enforce': 'privileged',
            }),
        ),
        'denied: a namespace created by an app may not opt out of Pod Security',
    ],
    [
        "relabels another app's namespace as its own",
        { args: ['label', 'namespace', B, `${KEY}=${A}`, '--overwrite'] },
        `denied: namespaces ${B} must carry ${KEY}=${A}`,
    ],
    [
        'creates a volume at the root of the node',
        create(volume(`${A}-data`, '/', A)),
        'denied: an app volume is a hostPath at /var/lib/k8s-data/<name minus -data>',
    ],
    [
        "creates a volume at another app's directory",
        create(volume(`${A}-data`, `/var/lib/k8s-data/${B}`, A)),
        'denied: an app volume is a hostPath at /var/lib/k8s-data/<name minus -data>',
    ],
    [
        "deletes another app's volume",
        { args: ['delete', 'persistentvolume', `${B}-data`] },
        `denied: persistentvolumes ${B}-data must carry ${KEY}=${A}`,
    ],
];

describe('policy', () => {
    test.each(CASES)('an app repository that %s', async (_, request, expected) => {
        // Given - the two repositories' namespaces and b's volume, then a request of `a` under its GitHub OIDC identity
        await applyFixtures();
        const outcome = await outcomeOf(request);

        // Then - what the app-deployer-ownership policy and RBAC answer
        expect(outcome).toBe(expected);
    });
});
