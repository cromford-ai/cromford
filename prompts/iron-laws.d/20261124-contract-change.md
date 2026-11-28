stages: plan review lead-review

CONTRACT CHANGES (rule, BH-9929). Do not clone a table or add a one-to-one side table to get around the additive-only gate. File a contract-change ticket.
- Prefer a lookup table or a validated text column over a CHECK list for a set of values that grows.
