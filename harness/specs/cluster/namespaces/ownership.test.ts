import { describe, expect, test } from 'vitest';

import { kubectlList } from '../../../src/cluster/kubectl.ts';

// invariant: the namespaces no app owns: Kubernetes' own, and the platform's (kubernetes/cluster/namespaces.yaml).
const UNOWNED = /^(?:default|kube-.+|platform-.+)$/u;

describe('ownership', () => {
    test('every app namespace names the repository that owns it', async () => {
        // Given - every namespace that is neither Kubernetes' nor the platform's
        const namespaces = await kubectlList(['namespaces']);
        const apps = namespaces.items.filter(({ metadata }) => !UNOWNED.test(metadata.name));

        // Then - each carries app.jterrazz.com/repository, which the ownership policy reads before any write lands in it
        expect(
            apps
                .filter(
                    ({ metadata }) =>
                        (metadata.labels?.['app.jterrazz.com/repository'] ?? '') === '',
                )
                .map(({ metadata }) => metadata.name),
        ).toStrictEqual([]);
    });
});
