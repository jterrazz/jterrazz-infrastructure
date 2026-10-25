import { describe, expect, test } from 'vitest';

import { kubectlList } from '../../__setup__/kubectl.ts';
import type { KubeObject } from '../../__setup__/kubectl.ts';

type Certificate = KubeObject & {
    status: { conditions?: { message?: string; status: string; type: string }[] };
};

describe('ready', () => {
    test('every Certificate is issued and current', async () => {
        // Given - every Certificate cert-manager reconciles, a route's or not
        const certificates = await kubectlList<Certificate>([
            'certificates.cert-manager.io',
            '--all-namespaces',
        ]);

        // When - each is read for its Ready condition
        const failing = certificates.items.flatMap(({ metadata, status }) => {
            const ready = (status.conditions ?? []).find(({ type }) => type === 'Ready');
            return ready?.status === 'True'
                ? []
                : [
                      `${metadata.namespace ?? ''}/${metadata.name}: ${ready?.message ?? 'no Ready condition'}`,
                  ];
        });

        // Then - none: a renewal failing shows here weeks before the 15-day margin a route probe reads
        expect(failing).toStrictEqual([]);
    });
});
