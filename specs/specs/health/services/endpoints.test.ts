import { describe, expect, test } from 'vitest';

import { kubectlList } from '../../__setup__/kubectl.ts';
import type { KubeObject } from '../../__setup__/kubectl.ts';

type Service = KubeObject & { spec: { selector?: Record<string, string> } };
type Slice = KubeObject & { endpoints?: { conditions?: { ready?: boolean } }[] };

const SERVICE_NAME = 'kubernetes.io/service-name';

describe('endpoints', () => {
    test('every Service that selects pods has a ready one behind it', async () => {
        // Given - every Service with a selector, and every EndpointSlice the control plane derived from them
        const [services, slices] = await Promise.all([
            kubectlList<Service>(['services', '--all-namespaces']),
            kubectlList<Slice>(['endpointslices', '--all-namespaces']),
        ]);
        const served = new Set(
            slices.items
                .filter(({ endpoints = [] }) =>
                    endpoints.some(({ conditions }) => conditions?.ready === true),
                )
                .map(
                    ({ metadata }) =>
                        `${metadata.namespace ?? ''}/${metadata.labels?.[SERVICE_NAME] ?? ''}`,
                ),
        );

        // When - each Service is looked up among the served ones
        const empty = services.items
            .filter(({ spec }) => spec.selector !== undefined)
            .map(({ metadata }) => `${metadata.namespace ?? ''}/${metadata.name}`)
            .filter((service) => !served.has(service));

        // Then - none: a selector drifted from its pods' labels, or pods never ready, answer nothing to a backend no route probes
        expect(empty).toStrictEqual([]);
    });
});
