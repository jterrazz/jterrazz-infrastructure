import { describe, expect, test } from 'vitest';

import { kubectlList } from '../../__setup__/kubectl.ts';
import type { KubeObject } from '../../__setup__/kubectl.ts';

type Scaled = KubeObject & { spec: { replicas?: number }; status: { readyReplicas?: number } };
type DaemonSet = KubeObject & { status: { desiredNumberScheduled: number; numberReady: number } };
type CronJob = KubeObject & {
    spec: { suspend?: boolean };
    status: { active?: object[]; lastScheduleTime?: string; lastSuccessfulTime?: string };
};

const where = ({ metadata }: KubeObject): string => `${metadata.namespace ?? ''}/${metadata.name}`;

describe('ready', () => {
    test('every Deployment, StatefulSet and DaemonSet runs as many ready pods as it asks for', async () => {
        // Given - every controller that keeps pods running
        const [deployments, statefulSets, daemonSets] = await Promise.all([
            kubectlList<Scaled>(['deployments', '--all-namespaces']),
            kubectlList<Scaled>(['statefulsets', '--all-namespaces']),
            kubectlList<DaemonSet>(['daemonsets', '--all-namespaces']),
        ]);

        // When - each is read for its ready count against its desired one; a rollout keeps the old pods ready
        const short = [
            ...[...deployments.items, ...statefulSets.items]
                .filter(({ spec, status }) => (status.readyReplicas ?? 0) < (spec.replicas ?? 1))
                .map(
                    (workload) =>
                        `${where(workload)}: ${String(workload.status.readyReplicas ?? 0)}/${String(workload.spec.replicas ?? 1)} ready`,
                ),
            ...daemonSets.items
                .filter(({ status }) => status.numberReady < status.desiredNumberScheduled)
                .map(
                    (set) =>
                        `${where(set)}: ${String(set.status.numberReady)}/${String(set.status.desiredNumberScheduled)} ready`,
                ),
        ];

        // Then - none: a crash-looping pod behind no route is invisible to every route probe
        expect(short).toStrictEqual([]);
    });

    test("every CronJob's last scheduled run succeeded, unless it is still running", async () => {
        // Given - every CronJob that has run at least once
        const cronJobs = await kubectlList<CronJob>(['cronjobs', '--all-namespaces']);

        // When - its last schedule is compared with its last success
        const failed = cronJobs.items
            .filter(
                ({ spec, status }) =>
                    spec.suspend !== true && status.lastScheduleTime !== undefined,
            )
            .filter(({ status }) => (status.active ?? []).length === 0)
            .filter(
                ({ status }) => (status.lastSuccessfulTime ?? '') < (status.lastScheduleTime ?? ''),
            )
            .map(
                (job) =>
                    `${where(job)}: scheduled ${job.status.lastScheduleTime ?? ''}, last success ${job.status.lastSuccessfulTime ?? 'never'}`,
            );

        // Then - none: a failed job leaves no other trace
        expect(failed).toStrictEqual([]);
    });
});
