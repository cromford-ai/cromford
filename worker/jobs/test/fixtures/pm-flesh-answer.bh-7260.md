I read the idea and the evidence rows.

## Problem
Alerts rise and nobody owns the triage. The team reads the same alert twice.

## Evidence
- alerts.7d: 41 alerts in 7 days.

## User and job
The operator opens the alert list each morning. The job is to clear each alert once.

## Options
### Option A: an owner column
Each alert gets one owner.
### Option B: a daily digest
One message a day lists the open alerts.
Recommended: Option A, because it removes the double read.

## Scope cut
No paging. No new alert sources.

## Acceptance criteria
- An alert shows its owner.
- A second reader sees the owner before opening the alert.

## Risks
The owner can be away. A fallback owner is a later step.
PM_FLESH_DONE
