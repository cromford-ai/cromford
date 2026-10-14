# pr-self-check ends a body section at a same-or-higher heading (BH-6191)

Doc: LEAD-REVIEW

`_psc_section` in `bin/lib/pr-self-check.sh` ended a section at the next heading of any level.
A plan with `### C0` and `### C1` under `## Files to touch` read as one empty section.
The `plan-files` row refused #6092 two times on 2026-10-12 for that reason.
Now a section ends only at a heading of the same level or a higher level. A deeper heading stays in the section.
`closes-not-met` also reads a `- [ ]` item under a `###` heading inside an acceptance section now.
