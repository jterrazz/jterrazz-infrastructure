import { describe, expect, test } from 'vitest';

import { kubectlList } from '../../__setup__/kubectl.ts';
import type { KubeObject } from '../../__setup__/kubectl.ts';

type InfisicalSecret = KubeObject & {
    status?: { conditions?: { message?: string; status: string; type: string }[] };
};

const SYNCED = 'secrets.infisical.com/ReadyToSyncSecrets';

describe('synced', () => {
    test('every InfisicalSecret syncs from its folder', async () => {
        // Given - every InfisicalSecret the operator reconciles
        const secrets = await kubectlList<InfisicalSecret>([
            'infisicalsecrets.secrets.infisical.com',
            '--all-namespaces',
        ]);

        // When - each is read for the condition the operator sets once a sync succeeds
        const stuck = secrets.items.flatMap(({ metadata, status }) => {
            const synced = (status?.conditions ?? []).find(({ type }) => type === SYNCED);
            return synced?.status === 'True'
                ? []
                : [
                      `${metadata.namespace ?? ''}/${metadata.name}: ${synced?.message ?? 'never synced'}`,
                  ];
        });

        // Then - none: a folder missing from an environment fails here, not at the next pod restart
        expect(stuck).toStrictEqual([]);
    });
});
