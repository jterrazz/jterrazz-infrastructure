import { describe, expect, test } from 'vitest';

import { kubectlList } from '../../__setup__/kubectl.ts';

// invariant: Kubernetes' own namespaces carry no tier; every other one says who owns it (ADR-023).
const KUBERNETES = /^(?:default|kube-.+)$/u;
const TIER = 'studio.jterrazz.com/tier';
const REPOSITORY = 'studio.jterrazz.com/repository';
const ENVIRONMENT = 'studio.jterrazz.com/environment';
const APP = 'studio.jterrazz.com/app';
const SCOPE = 'studio.jterrazz.com/scope';

// invariant: <app>-<environment>, or <app> for a shared app, as the labels state (ADR-029).
function isNamedByItsLabels(name: string, labels: Record<string, string>): boolean {
    const app = labels[APP] ?? '';
    const environment = labels[ENVIRONMENT] ?? '';
    if (labels[SCOPE] === 'shared') {
        return environment === '' && name === app;
    }

    return app !== '' && environment !== '' && name === `${app}-${environment}`;
}

describe('ownership', () => {
    test('every namespace states its owner, and an app namespace its repository, app and environment', async () => {
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
                return (labels[REPOSITORY] ?? '') !== '' && isNamedByItsLabels(name, labels)
                    ? []
                    : [
                          `${name}: an app namespace carries its repository, and is <app>-<environment>, or <app> when shared`,
                      ];
            }
            return [`${name}: no ${TIER} label`];
        });

        // Then - none: the ownership policy and the suite select on these labels, never on a name
        expect(violations).toStrictEqual([]);
    });
});
