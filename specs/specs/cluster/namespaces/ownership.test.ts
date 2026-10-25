import { describe, expect, test } from 'vitest';

import { kubectlList } from '../../__setup__/kubectl.ts';

// invariant: Kubernetes' own namespaces carry no tier; every other one says who owns it (ADR-023).
const KUBERNETES = /^(?:default|kube-.+)$/u;
const TIER = 'app.jterrazz.com/tier';
const REPOSITORY = 'app.jterrazz.com/repository';
const ENVIRONMENT = 'app.jterrazz.com/environment';

describe('ownership', () => {
    test('every namespace states its owner, and an app namespace its repository and environment', async () => {
        // Given - every namespace Kubernetes did not create itself
        const listed = await kubectlList(['namespaces']);
        const namespaces = listed.items.filter(({ metadata }) => !KUBERNETES.test(metadata.name));

        // When - each is read for what its labels claim
        const violations = namespaces.flatMap(({ metadata: { labels = {}, name } }) => {
            const tier = labels[TIER];
            if (tier === 'platform') {
                return name.startsWith('platform-') && labels[REPOSITORY] === undefined
                    ? []
                    : [`${name}: a platform namespace is platform-* and owned by no repository`];
            }
            if (tier === 'app') {
                const environment = labels[ENVIRONMENT] ?? '';
                return (labels[REPOSITORY] ?? '') !== '' &&
                    environment !== '' &&
                    name.endsWith(`-${environment}`)
                    ? []
                    : [
                          `${name}: an app namespace carries its repository and environment, and ends with -<environment>`,
                      ];
            }
            return [`${name}: no ${TIER} label`];
        });

        // Then - none: the ownership policy and the suite select on these labels, never on a name
        expect(violations).toStrictEqual([]);
    });
});
