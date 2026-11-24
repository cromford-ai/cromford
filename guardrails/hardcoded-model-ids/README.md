# Guardrail: hardcoded model ids

**Iron law:** agents never hardcode model strings. Model selection is
database-driven and resolved at runtime per agent, with the code constant kept
only inside the resolver as a documented fallback. A model upgrade is a DB
update, not a deploy.

**What it catches:** a `claude-*` / `gpt-*` / `gemini-*` / `grok-*` /
`deepseek-*` literal anywhere in application or agent code.

**Tool:** semgrep. `rule.yml` is a complete config.

```bash
semgrep --config rule.yml --lang ts --error <path>
```

**Applicability:** any repo with TypeScript/JavaScript LLM call sites — every OS
in the fleet. **Adopt only once the repo has a resolver**; turning this on before
`resolveModel()` exists gives a red CI and nowhere to move the literal to. If
the repo has no resolver, the adoption ticket ports the project-4 one
(`src/lib/agents/model-selector.ts`) in the same PR.

**Known false positives — it matches inside COMMENTS.** `pattern-regex` sees a
`// fallback was "claude-opus-4-8"` line exactly like a live one. This is
deliberate rather than unfixed: a commented-out model id is a literal someone
uncomments, and the fix (move it to the resolver, reference it by key) is the
same either way. But it *is* noise on a repo that documents its model history
inline, and the honest answer there is the escape hatch or a narrower
`paths.exclude`, not pretending the check is precise.

The exclusions cover tests, seed scripts, migrations, and the
resolver/model-catalog files themselves — the four places a live literal is
legitimate.

**Escape hatch:** `skip-guardrail` label + `GUARDRAIL_JUSTIFICATION` (see
`../README.md`).
On a Mergify batch draft the hatch reads each source PR and exempts only the
files a hatched source PR changed; the step needs the `GUARDRAIL_HEAD_REF`,
`GUARDRAIL_PR_AUTHOR`, `GUARDRAIL_DRAFT_BODY` and `GH_TOKEN` env lines (see
`../README.md`, "On a Mergify batch draft"), and the semgrep form
that scans `.` with `$(guardrail_semgrep_excludes)`).
