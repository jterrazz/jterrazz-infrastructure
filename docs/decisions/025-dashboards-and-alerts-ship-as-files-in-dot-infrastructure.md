# ADR-025: Dashboards and alerts ship as files in `.infrastructure/`

**Status:** Accepted
**Date:** 2026-10-25

Revised 2026-10-25: a file is named by its kind and the chart derives each
dashboard's identity ([ADR-027](027-a-dashboard-answers-one-audience-and-its-identity-is-derived.md)).

## Context

Apps shipped dashboards as `.infrastructure/dashboards/*.json`, but alerts
inline in `application.yaml`, because the deploy read only the dashboards
directory. The platform kept its dashboards under `services/grafana/` and had
no alert at all: no rule on disk, crash loops, certificates or backups. Every
app rule set `execErrState: OK`, so a broken query stayed green, and the
datasource uids were `prometheus`, `loki` and `tempo` for VictoriaMetrics,
VictoriaLogs and VictoriaTraces: signews-api's log panels were written in
LogQL against the `loki` uid, and every one failed to parse.

## Decision

- **One layout, everywhere.** A repository's dashboards are
  `.infrastructure/dashboards/<name>.json` and its alert rule groups
  `.infrastructure/alerts/<name>.yaml` (Grafana alert provisioning documents).
  App CI's `deploy-app` turns each file into a `spec.dashboards` or
  `spec.alerts` entry; this repository's root `.infrastructure/` holds the
  platform's, which `grafana-platform` renders through the platform
  chart's `dashboards` and `alerts`.
- **One validation.** `common.alerts` checks every rule of both charts: an
  `apiVersion: 1` document, named groups, a unique uid of at most 40
  characters, and never `execErrState: OK`. A bad file fails the render rather
  than Grafana's reload of every rule.
- **Datasources are named after their store**: `victoria-metrics`,
  `victoria-logs`, `victoria-traces`.
- **The platform's rules** watch the VM's and the Mac's disks, node memory,
  restarting containers, unavailable Deployments, scrape targets that stopped
  answering, certificate expiry and the backup's age (a timestamp the backup
  writes to node-exporter's textfile collector). They reach Slack.

## Consequences

- Adding a dashboard or a rule is adding a file; deleting the file deletes it,
  except a rule, which Grafana keeps until a `deleteRules` file removes it
  (app chart README).
- The play stages `src/kubernetes` and `.infrastructure` with the repository's
  own layout, so the helmfile's relative paths hold on the node.
