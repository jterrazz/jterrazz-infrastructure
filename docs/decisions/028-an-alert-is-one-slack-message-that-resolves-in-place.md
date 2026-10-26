# ADR-028: An alert is one Slack message that resolves in place

**Status:** Proposed
**Date:** 2026-10-25

## Context

Grafana sent alerts to Slack through an incoming webhook with its default
template: a block of text with every label in it, bold written as Markdown's
`**`, which Slack's mrkdwn does not render. A resolved alert arrived as a second
message below the first, so a channel read as a pile of red and green with no
way to tell which incident was still open. Grafana 13 cannot do otherwise: its
Slack integration never edits a message and never replies in a thread, and the
request to make it do so is closed as not planned (grafana/grafana#93047); only
Grafana IRM threads, a product of its own. Grafana also had no `root_url`, so
every link it sent pointed at `http://localhost:3000`.

## Decision

- **A relay owns the Slack side.** `studio-alerts`, an app of its own
  repository, receives Grafana's webhook and talks to the Slack Web API with a
  bot token. It posts one message per incident (an alert's fingerprint and the
  time it started), edits that message as the alert fires again, and turns it
  green when it resolves, with a reply in its thread for the record.
- **The relay keeps no state.** Each message carries Slack message metadata
  naming its incident; the relay finds it again with `conversations.history`
  from the incident's start. A restart loses nothing.
- **A message reads in one glance.** Colour and dot say open or resolved; the
  title is `<app> · <problem>`; one sentence says the impact; fields give the
  environment, since when, and the value against its threshold; buttons open
  the panel (ADR-027's `__dashboardUid__`/`__panelId__`), the runbook and a
  silence. A critical alert's first post mentions `@here`; a warning stays
  quiet.
- **A rule says its impact and its value.** `summary` is one sentence a reader
  acts on; `value` renders the evaluated number with its unit and threshold
  (`{{ humanizePercentage $values.B.Value }} free (alert under 10%)`).
- **Two levels, one channel each.** `critical`: users are affected now, or
  will be within hours without action (a full disk, a Deployment down, the
  gateway answering 503, its Claude login refused) → `#alerts-critical`, the
  first post mentions `@here`. `warning`: degraded or drifting, no impact yet,
  handled during the day (memory, a crash loop, a stale backup, a certificate
  two weeks from expiry) → `#alerts-warning`, never a ping. No `info` level: an
  alert asks for an action, and what needs none is a dashboard or a digest.
- **An alert about the relay cannot go through it.** Grafana's notification
  policy routes anything labelled with the relay's namespace to the plain Slack
  webhook, kept for that alone. Grafana gets `root_url`, so every link is
  absolute.

## Consequences

- The bot token and the channel live in Infisical `/jterrazz-alerts`, the one
  folder the app may read (ADR-017); the webhook URL stays in
  `/jterrazz-infrastructure/grafana` for the fallback route.
- The NetworkPolicy is the relay's only authentication: Grafana's namespace
  alone may reach it.
- Slack failing answers Grafana a 502, and Grafana retries; a relay that is
  down is noticed through the fallback route, not through itself.
- The relay's message format is its repository's to change; this record fixes
  only what each element is for.
