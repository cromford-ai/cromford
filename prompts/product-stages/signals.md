# Stage: SIGNALS (Phase 1 — weekly evidence harvest)

Mine this client's recent reality for EVIDENCE — no ideation, no solutions. Every signal is something a specific person said, asked for, struggled with, or that the data shows piling up. Write ONE file: `$SIGNALS_OUT` (path in RUNTIME CONTEXT). Read-only everywhere else.

Sources, in order of evidence strength:
1. **Board threads** — list boards → tickets → read recent/changed threads fully (requests, complaints, "wouldn't it be nice", rejected-scope leftovers, recurring themes across tickets).
2. **Meeting transcripts / escalations / notes** — where the project context gives DB access, sample the most recent ones (summaries + action items first, drill into promising transcripts).
3. **Operational exhaust** — where DB access exists: queues that grow, statuses that stall, features with zero usage, error-ish patterns.
4. **Security smells** (source: `security`) — anything in threads/transcripts/data suggesting exposure: shared logins, "just email me the file", access nobody revoked, client data in the wrong channel, complaints about who can see what, vendor breaches mentioned. These feed the DERISK sweep downstream — capture them even when nobody framed them as a security issue.
5. **Product data** (source: `data`) — if RUNTIME CONTEXT has `DATA_SIGNALS`, read that JSON file. It holds counted, read-only evidence rows `{id, source, metric, value, window, link, status}`. Each data signal you write from it carries `"evidence_id": "<id from $DATA_SIGNALS>"`, and its `evidence` gives the metric, the value and the window. Cite only rows with `status` `"ok"`. A row with status `error` or `not-configured` is never cited and never shown as a zero. If `DATA_SIGNALS` is absent, write no `data` signals from this source.

Tag every signal to the org using the Company Map (`$MAP` in RUNTIME CONTEXT): department key (must be one of the frontmatter keys), role, process. If a signal doesn't cleanly fit, use the closest department and say so in `theme`.

## Output — `$SIGNALS_OUT`
```json
{"signals":[{
  "id": "sig-1",
  "source": "board|transcript|escalation|note|data",
  "evidence": "VERBATIM quote or precise data pointer (ticket key, recording title+date, table+count)",
  "department": "<map dept key>",
  "role": "<role from the map>",
  "process": "<process name>",
  "theme": "one-line what this signal is about",
  "strength": 7,
  "date": "YYYY-MM-DD or approx",
  "evidence_id": "alerts.7d (data signals only)"
}]}
```

## Rules
- 10-30 signals. Verbatim beats paraphrase; a signal with no quotable evidence and no data pointer doesn't go in the file.
- `strength` 1-10: 9-10 = explicit ask/complaint from a named person; 6-8 = clear pattern in transcripts/data; ≤5 = weak inference.
- Recency-weighted: prefer the last ~30 days; older signals only if they recur.
- No data claim without an evidence_id from $DATA_SIGNALS.
- Never fabricate quotes. Never include client PII beyond names/roles that appear in the source systems.

Final line of your reply: `SIGNALS_DONE n=<count>` or `SIGNALS_FAILED <reason>`.
