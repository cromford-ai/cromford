# Guardrail: metered vendor calls outside the choke point

**Iron law:** any call to a per-unit-billed external API must have a persisted
"have we already paid for this?" check that runs **before** the call, keyed on a
stable fingerprint of the input, with three outcomes — `ok` / `empty` / `failed`
— where `empty` is billed and terminal.

**What it catches:** a metered vendor's hostname appearing anywhere outside the
project's metered-client path.

**Tool:** semgrep. `rule.yml` is a complete config.

```bash
semgrep scan --config rule.yml --error <path>
```

**What it does NOT prove.** This is a *placement* check, not a correctness
check: it proves the call went through the choke point, not that the choke point
guards correctly. The seven-point review checklist in
`~/.claude/rules/metered-api-dedup.md` still applies to the wrapper itself, and
so does its detection recipe (requests ÷ distinct inputs from the vendor's own
usage API). A green run here means "one place to review", which is the whole
point — project-4 had seventeen.

**Applicability:** any repo that calls a billed vendor. **Adopt only once the
repo has a metered client to point at**; otherwise the check has nowhere to send
the call and every lane trips it. The adoption ticket creates the wrapper first.
Tune `paths.exclude` and the hostname list to the project's actual vendors in
the same PR — an unmaintained hostname list is a check that quietly stops
catching new vendors.

**Escape hatch:** `skip-guardrail` label + `GUARDRAIL_JUSTIFICATION` (see
`../README.md`). Use it sparingly here: this is the class where the bill is the
only symptom.
On a Mergify batch draft the hatch reads each source PR and exempts only the
files a hatched source PR changed; the step needs the `GUARDRAIL_HEAD_REF`,
`GUARDRAIL_PR_AUTHOR`, `GUARDRAIL_DRAFT_BODY` and `GH_TOKEN` env lines (see
`../README.md`, "On a Mergify batch draft"), and the semgrep form
that scans `.` with `$(guardrail_semgrep_excludes)`).
