# Releasing

How a change reaches the cluster. This repository ships three things: the
platform, the `app` chart every app deploys through, and the platform's
dashboards and alert rules. What each workflow does is [CI](../reference/ci.md);
what a change owes before it is merged is [Develop](develop.md#before-you-commit).

## The platform

A merge to main deploys itself: `validate.yaml` and `upgrade-test.yaml` run
on the push, and `deploy-platform.yaml` starts only once the upgrade test
passed and that commit's Validate did too. It runs `platform.yml` over the
tailnet, then `smoke.yaml` probes the result from both vantages. A change that
touches neither `src/ansible/` nor `src/kubernetes/` (the manual, a workflow,
the specs alone) merges and deploys nothing.

From the Mac, `make diff` previews a deploy and `make deploy-platform` runs
one. The host layer is never deployed by CI: a change under a host role ships
with `make deploy`.

## The app chart

The deploy publishes `src/kubernetes/charts/app` to
`oci://registry.internal.jterrazz.com/charts/app` when its `version:` is new,
and never overwrites one, so a template change ships only with a bump. Apps
pull the chart unversioned: each takes the new version on its next deploy, and
`make redeploy-apps` rolls the whole fleet onto it at once. A version that
removes or renames a field is a major, and lands only after every app's
`application.yaml` stopped using it.

## Dashboards and alert rules

The platform's live at the repository root, `.infrastructure/dashboards/*.json`
and `.infrastructure/alerts/*.yaml`, the layout every app ships its own in
([ADR-025](../decisions/025-dashboards-and-alerts-ship-as-files-in-dot-infrastructure.md)).
A file added or removed there ships with the next platform deploy. A rule
removed stays in Grafana's database until a `deleteRules` file deletes it
([app chart README](../../src/kubernetes/charts/app/README.md#specalerts)).
