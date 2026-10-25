import { describe, expect, test } from 'vitest';

import { kubectlList } from '../../__setup__/kubectl.ts';
import type { KubeObject } from '../../__setup__/kubectl.ts';

type Volume = KubeObject & {
    spec: { persistentVolumeReclaimPolicy: string };
    status: { phase: string };
};

describe('bound', () => {
    test('every PersistentVolume is bound to its claim and retained when it is released', async () => {
        // Given - every PersistentVolume: each is a directory of live data on the node
        const volumes = await kubectlList<Volume>(['persistentvolumes']);

        // Then - Bound, so a workload reads it, and Retain, so deleting a claim never deletes the data
        expect(
            volumes.items
                .filter(
                    ({ spec, status }) =>
                        status.phase !== 'Bound' || spec.persistentVolumeReclaimPolicy !== 'Retain',
                )
                .map(
                    ({ metadata, spec, status }) =>
                        `${metadata.name}: ${status.phase}, ${spec.persistentVolumeReclaimPolicy}`,
                ),
        ).toStrictEqual([]);
    });
});
