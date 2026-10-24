import { describe, expect, test } from 'vitest';

import { kubectlList } from '../../../src/cluster/kubectl.ts';
import type { KubeObject } from '../../../src/cluster/kubectl.ts';

type Service = KubeObject & {
    spec: {
        allocateLoadBalancerNodePorts?: boolean;
        loadBalancerSourceRanges?: string[];
        ports?: { name?: string; nodePort?: number }[];
        type: string;
    };
};

describe('service', () => {
    test('no service of the cluster opens a node port', async () => {
        // Given - every Service, in every namespace
        const services = await kubectlList<Service>(['services', '--all-namespaces']);

        // Then - none holds a nodePort: a NodePort answers on the node's own address and bypasses the tailnet gate (docs/decisions/003-traefiks-service-is-the-tailnet-gate.md)
        expect(
            services.items.flatMap((service) =>
                (service.spec.ports ?? [])
                    .filter((port) => port.nodePort !== undefined)
                    .map(
                        (port) =>
                            `${service.metadata.namespace ?? ''}/${service.metadata.name}:${String(port.nodePort)}`,
                    ),
            ),
        ).toStrictEqual([]);
    });

    test("traefik's load balancer admits the tailnet's addresses alone, and allocates no node port", async () => {
        // Given - Traefik's Service, the front door of every route
        const services = await kubectlList<Service>([
            'services',
            '--namespace',
            'kube-system',
            '--field-selector',
            'metadata.name=traefik',
        ]);

        // Then - a LoadBalancer gated to Tailscale's CGNAT range, with node ports switched off
        expect(
            services.items.map(({ spec }) => ({
                allocateLoadBalancerNodePorts: spec.allocateLoadBalancerNodePorts,
                loadBalancerSourceRanges: spec.loadBalancerSourceRanges,
                type: spec.type,
            })),
        ).toStrictEqual([
            {
                allocateLoadBalancerNodePorts: false,
                loadBalancerSourceRanges: ['100.64.0.0/10'],
                type: 'LoadBalancer',
            },
        ]);
    });
});
