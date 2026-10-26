import { describe, expect, test } from 'vitest';

import { kubectlList } from '../../__setup__/kubectl.ts';
import type { KubeObject } from '../../__setup__/kubectl.ts';

type Requirement = {
    key: string;
    operator: 'DoesNotExist' | 'Exists' | 'In' | 'NotIn';
    values?: string[];
};
type Selector = { matchExpressions?: Requirement[]; matchLabels?: Record<string, string> };
type Peer = { ipBlock?: object; namespaceSelector?: Selector; podSelector?: Selector };
type Policy = KubeObject & {
    spec: { egress?: { to?: Peer[] }[]; ingress?: { from?: Peer[] }[]; podSelector: Selector };
};
type Template = { metadata?: { labels?: Record<string, string> } };
type Workload = KubeObject & {
    spec: { jobTemplate?: { spec: { template: Template } }; template?: Template };
};

// invariant: a pod is read off its controller's template, so a CronJob's count between runs, a crash-looping Deployment's too.
type Pod = { labels: Record<string, string>; namespace: string };

// invariant: an empty selector matches everything by definition, a default deny over no pod included.
const isEmpty = ({ matchExpressions = [], matchLabels = {} }: Selector): boolean =>
    matchExpressions.length === 0 && Object.keys(matchLabels).length === 0;

const OPERATORS: Record<
    Requirement['operator'],
    (value: string | undefined, values: string[]) => boolean
> = {
    DoesNotExist: (value) => value === undefined,
    Exists: (value) => value !== undefined,
    In: (value, values) => value !== undefined && values.includes(value),
    NotIn: (value, values) => value === undefined || !values.includes(value),
};

function matches(selector: Selector, labels: Record<string, string>): boolean {
    return (
        Object.entries(selector.matchLabels ?? {}).every(([key, value]) => labels[key] === value) &&
        (selector.matchExpressions ?? []).every(({ key, operator, values = [] }) =>
            OPERATORS[operator](labels[key], values),
        )
    );
}

async function podsOfTheCluster(): Promise<Pod[]> {
    const kinds = ['deployments', 'statefulsets', 'daemonsets', 'cronjobs'];
    const lists = await Promise.all(
        kinds.map(async (kind) => await kubectlList<Workload>([kind, '--all-namespaces'])),
    );

    return lists.flatMap(({ items }) =>
        items.map(({ metadata, spec }) => ({
            labels: (spec.template ?? spec.jobTemplate?.spec.template)?.metadata?.labels ?? {},
            namespace: metadata.namespace ?? '',
        })),
    );
}

const TIER = 'studio.jterrazz.com/tier';
const APP = 'studio.jterrazz.com/app';
const PLATFORM_NAMESPACE = /^(?:default|kube-.+|platform-.+)$/u;

// hazard: the upgrade test's k3d cluster deploys no app, so a peer naming apps (Grafana's egress to
// studio-alerts, the collector's ingress from every app namespace, a provider's `serves`) cannot
// match there; the live cluster judges it.
function namesAnAbsentApp({ namespaceSelector }: Peer, hasApps: boolean): boolean {
    if (hasApps || namespaceSelector === undefined) {
        return false;
    }
    const name = namespaceSelector.matchLabels?.['kubernetes.io/metadata.name'];

    return (
        (name !== undefined && !PLATFORM_NAMESPACE.test(name)) ||
        (namespaceSelector.matchExpressions ?? []).some(
            ({ key, values = [] }) => key === APP || (key === TIER && values.includes('app')),
        )
    );
}

describe('selectors', () => {
    test('every network policy selects pods that exist, and admits peers that exist', async () => {
        // Given - every NetworkPolicy, the pods every controller creates, and every namespace's labels
        const [policies, pods, namespaces] = await Promise.all([
            kubectlList<Policy>(['networkpolicies', '--all-namespaces']),
            podsOfTheCluster(),
            kubectlList(['namespaces']),
        ]);
        const labelsOf = new Map(
            namespaces.items.map(({ metadata }) => [metadata.name, metadata.labels ?? {}]),
        );
        const hasApps = [...labelsOf.values()].some((labels) => labels[TIER] === 'app');

        // When - each selector is resolved against them; an ipBlock names no pod and is not read
        const violations = policies.items.flatMap(({ metadata, spec }) => {
            const home = metadata.namespace ?? '';
            const where = `${home}/${metadata.name}`;
            const selects = ({ ipBlock, namespaceSelector, podSelector }: Peer): boolean => {
                if (ipBlock !== undefined) {
                    return true;
                }
                if (podSelector === undefined || isEmpty(podSelector)) {
                    return (
                        namespaceSelector === undefined ||
                        [...labelsOf.values()].some((labels) => matches(namespaceSelector, labels))
                    );
                }
                return pods.some(
                    (pod) =>
                        matches(podSelector, pod.labels) &&
                        (namespaceSelector === undefined
                            ? pod.namespace === home
                            : matches(namespaceSelector, labelsOf.get(pod.namespace) ?? {})),
                );
            };
            const peers = [
                ...(spec.ingress ?? []).flatMap(({ from = [] }) =>
                    from.map((peer) => ['from', peer] as const),
                ),
                ...(spec.egress ?? []).flatMap(({ to = [] }) =>
                    to.map((peer) => ['to', peer] as const),
                ),
            ];

            return [
                ...(selects({ podSelector: spec.podSelector }) ? [] : [`${where}: selects no pod`]),
                ...peers
                    .filter(([, peer]) => !selects(peer) && !namesAnAbsentApp(peer, hasApps))
                    .map(
                        ([way, peer]) => `${where}: ${way} ${JSON.stringify(peer)} matches nothing`,
                    ),
            ];
        });

        // Then - none: a selector matching nothing fails silent, as a deny on live traffic (a mislabelled cloudflared peer once 502'd the tunnel)
        expect(violations).toStrictEqual([]);
    });
});
