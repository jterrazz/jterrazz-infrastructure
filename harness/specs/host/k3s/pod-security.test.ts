import { describe, expect, test } from 'vitest';

import { onHost } from '../__setup__/shell.ts';

// invariant: `default` carries no pod-security label, so the cluster DEFAULT judges it
// (ansible/roles/k3s/templates/pod-security.yaml.j2); a server-side dry run persists nothing.
const probe = (securityContext: Record<string, unknown>): string =>
    JSON.stringify({
        apiVersion: 'v1',
        kind: 'Pod',
        metadata: { name: 'pod-security-probe', namespace: 'default' },
        spec: { containers: [{ image: 'busybox', name: 'probe', securityContext }] },
    });

const DRY_RUN = ['kubectl', 'create', '--dry-run=server', '-f', '-'];

describe('pod-security', () => {
    test('an unlabelled namespace refuses a privileged pod, by the baseline default', async () => {
        // Given - a privileged pod, offered to the unlabelled `default` namespace
        const outcome = await onHost(DRY_RUN, probe({ privileged: true }));

        // Then - Pod Security refuses it at baseline
        expect({ code: outcome.code, stderr: outcome.stderr.trim() }).toStrictEqual({
            code: 1,
            stderr: 'Error from server (Forbidden): error when creating "STDIN": pods "pod-security-probe" is forbidden: violates PodSecurity "baseline:latest": privileged (container "probe" must not set securityContext.privileged=true)',
        });
    });

    test('an unlabelled namespace admits a pod baseline allows, so the refusal above is Pod Security', async () => {
        // Given - the same pod, unprivileged
        const outcome = await onHost(DRY_RUN, probe({ allowPrivilegeEscalation: false }));

        // Then - admitted, in a dry run that leaves nothing behind
        expect({ code: outcome.code, stdout: outcome.stdout.trim() }).toStrictEqual({
            code: 0,
            stdout: 'pod/pod-security-probe created (server dry run)',
        });
    });
});
