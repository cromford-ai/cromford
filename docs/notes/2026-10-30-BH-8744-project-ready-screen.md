# BH-8744: the Project Ready screen

Doc: ONBOARDING, VERIFICATION-MAP

## What changed

- `bin/lib/hub-probes/ready-facts.sh` defines `hp_probe_ready_facts`. The
  `ready-facts` screen probe now answers three booleans, rc 0, instead of
  `not-implemented`.
- New route `GET /api/onboarding/ready/<project>`
  (`worker/jobs/src/routes/onboarding-ready.js`): one D1 batch of 3 reads,
  then the probe row and one history read in parallel (6 statements).
- New knobs `onboarding.ready_bucket_s` (300) and `onboarding.ready_stale_s`
  (3600), seeded by `worker/jobs/schema.d/202611020040-bh-8744-onboarding-ready-knobs.sql`.
- `/projects/<project>/ready` shows nine cards (`console-ui/src/lib/ready-cards.js`).
  The AI account card opens `AiAccountChoiceSheet`. The Project page has a
  READY link.

## Why

The Ready screen was a heading-only seam (BH-7997). This fills it (#8000) and
wires the AI account card to the sheet (#8666, item 2 of #7968).

## Decisions

- The route is a path segment, not `?project=`: `api.onboardReady` on main
  calls `/api/onboarding/ready/<project>`.
- The history read reaches back twice `onboarding.ready_stale_s`. A row
  finishes after its bucket starts, so a reach of one stale window could never
  hold a stale row.
- `hub_probe_requests` gains at most 12 rows per project per hour while the
  screen is open. That table has no retention rule on main yet.
