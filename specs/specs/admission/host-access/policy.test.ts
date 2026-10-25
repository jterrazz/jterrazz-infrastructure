import { describe, expect, test } from 'vitest';

import { kubectl } from '../../__setup__/kubectl.ts';

// invariant: every case is a server-side dry run in platform-telemetry, whose Pod Security level is
// privileged: what refuses there is the host-access policy alone, and nothing is written.
type Probe = { container?: object; serviceAccount: string; spec?: object };

const pod = ({ container = {}, serviceAccount, spec = {} }: Probe): object => ({
    apiVersion: 'v1',
    kind: 'Pod',
    metadata: { name: 'host-access-probe', namespace: 'platform-telemetry' },
    spec: {
        containers: [{ image: 'busybox:1.38', name: 'probe', ...container }],
        serviceAccountName: serviceAccount,
        ...spec,
    },
});

async function outcomeOf(probe: Probe): Promise<string> {
    const outcome = await kubectl(
        ['create', '-f', '-', '--dry-run=server'],
        JSON.stringify(pod(probe)),
    );
    if (outcome.code === 0) {
        return 'admitted';
    }
    const denied = /denied request: (?<reason>.+)$/mu.exec(outcome.stderr)?.groups?.reason;

    return denied === undefined ? `refused: ${outcome.stderr.trim()}` : `denied: ${denied}`;
}

const DENIED =
    'denied: pod host-access-probe asks for host access, which only node-exporter and otel-collector in platform-telemetry may have';

const CASES: [string, Probe, string][] = [
    [
        'grafana takes the host network',
        { serviceAccount: 'grafana', spec: { hostNetwork: true } },
        DENIED,
    ],
    [
        'any other pod mounts the node root',
        {
            serviceAccount: 'default',
            spec: { volumes: [{ hostPath: { path: '/' }, name: 'root' }] },
        },
        DENIED,
    ],
    [
        'any other pod runs privileged',
        { container: { securityContext: { privileged: true } }, serviceAccount: 'default' },
        DENIED,
    ],
    [
        'the log collector reads the node logs',
        {
            serviceAccount: 'otel-collector',
            spec: { volumes: [{ hostPath: { path: '/var/log' }, name: 'logs' }] },
        },
        'admitted',
    ],
    [
        'node-exporter takes the host network',
        { serviceAccount: 'node-exporter', spec: { hostNetwork: true } },
        'admitted',
    ],
    ['an ordinary pod is untouched', { serviceAccount: 'default' }, 'admitted'],
];

describe('policy', () => {
    test.each(CASES)('%s', async (_title, probe, expected) => {
        // Given - a pod in the privileged telemetry namespace, asking for what the case names

        // When - the API server admits or refuses it
        const outcome = await outcomeOf(probe);

        // Then - only the two named node agents may touch the node
        expect(outcome).toBe(expected);
    });
});
