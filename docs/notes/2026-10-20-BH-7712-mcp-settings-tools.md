# BH-7712: MCP `setting_get` and `setting_set`

The MCP server (`mcp/`) has two settings tools in `mcp/tools/settings.mjs`.
Before this, a session changed a settings row through ssh and
`_jobs_req PUT /api/settings`, and found each key and its knob by hand.

## Auth

Both tools use `/api/coord/*` routes. Those routes accept the console's `dash`
cookie only, so the tools need `HARNESS_CONSOLE_SECRET` (see "Merge-queue
tools" in `docs/MCP.md`). With a token alone the console answers 403.

## Routes

| Tool | Requests |
|---|---|
| `setting_get { key }` | `GET /api/coord/settings/<key>` and `GET /api/coord/lanes/registry`, in parallel |
| `setting_get { prefix }` or `{}` | `GET /api/coord/settings` and `GET /api/coord/lanes/registry`, in parallel |
| `setting_set` | `GET /api/coord/settings/<key>` and `GET /api/coord/lanes/registry` in parallel, then one `PUT /api/coord/settings` |

The knob registry is the one the console has deployed, not a repo file.

## `setting_get { key?, prefix? }`

- With `key`: `{ key, value, note, actor, updated_at, source, knob, as_of }`.
  `source` is the worker's (`settings`, `none` or `unproven`). No row gives
  `value: null` and `source: "none"`; the knob entry still shows its default.
- With `prefix`, or with no argument: `{ prefix, rows, total, truncated, as_of }`.
  Rows are sorted by key and capped at 100. `total` is the match count before
  the cap.
- `knob` is `{ owner, kind, env, type, default, min, max, unit, zero_means,
  note, settable, project_scoped }`, or `null` when the key is not a registry
  knob. A knob key is `lane.<id>.<env>`, `lane.<id>.<project>.<env>`, or the
  same with `lib.`.
- If the registry read fails, the row still returns with `knob: null` and
  `partial: ["/api/coord/lanes/registry"]`. If the row read fails, the tool
  fails with that error.
- Refusals, 0 requests: `key_or_prefix_not_both`; `invalid_arguments: key` or
  `invalid_arguments: prefix` (the key must match `^[a-z0-9_.-]{1,64}$`).

## `setting_set { key, value, note, confirm, force? }`

The checks run in this order. Refusals 1-4 send 0 requests. Refusals 5-8 send
the two GETs and never the PUT.

1. `confirm_required`: `confirm` is not the boolean `true`.
2. `note_required`: no note, or a blank note.
3. `note_must_say_why_and_rollback`: the note is shorter than 20 characters,
   or has no rollback words (roll back, revert, undo, restore, set back).
4. `invalid_arguments: <field>`: a bad key, a note over 512 characters, a value
   that is not a non-empty string (max 4096) or a finite number, a non-boolean
   `force`. `secret_value_refused`: a secret-named key or a secret-shaped value.
5. `registry_unavailable: <error>`, or the row read's error.
6. `unknown_knob: <key>`: the key is not a registry knob and `force` is not
   `true`. With `force: true` the tool writes it with no registry check.
7. `not_settable: <ENV>`: the knob has `settable: false`. `force` does not
   change this.
8. `value_type: <ENV> wants <type>` or `value_out_of_range: <value> (min, max)`.
   `int` wants an integer, `float`/`number` a finite number, `string` a
   non-empty string. `force` does not change this.

Then one `PUT /api/coord/settings` with `{ key, value, note, reason }`. The
value is sent as a trimmed string; `reason` is the note, so the
`config_changes` audit row carries it. The body has no `actor`: the console
proxy stamps the caller's session identity. The PUT is sent once and never
retried.

The answer is `{ key, old, new, knob, forced, as_of }`. `old` is the row the
GET read before the PUT (`null` for no row). `new` is the row the PUT
answered, not the value the caller sent. A PUT refusal returns the console's
`http_<status>: <error>`. A 2xx with no `setting` object returns
`bad_payload: /api/coord/settings (write sent, answer unreadable; read it back
with setting_get)`.

The worker stays the last check on every write. Its own refusals (key regex,
`settable: false`, value length, `lead_*` loosening, the reserved seed actor)
still apply. The console settings page and `bin/harness-ctl.sh` write the same
rows; this tool does not gate them.

## Secrets

A row's value is `null` and the row has `redacted: true` when:

- the worker already redacted it (the `.sig` rows), or
- the last key segment ends in `secret`, `token`, `password`, `passwd`,
  `apikey`, `api_key`, `private_key`, `credential(s)`, `cookie`, `bearer` or
  `sig`, or
- the value starts with `sk-`, `ghp_`, `gho_`, `ghs_`, `ghu_`, `github_pat_`,
  `xoxb-`, `xoxp-`, `xoxa-`, `AKIA` or `Bearer `.

Every answer then goes through `redact` once (the console token, secret and
cookie), and `structuredContent` is parsed back from the redacted text.

## Tests

`mcp/test/settings.bh-7712.test.mjs`, run in CI by
`tests/mcp-settings.bh-7712-test.sh`. A fetch recorder refuses every URL off
a stub, so the suite makes 0 network calls. One case runs the real
`node mcp/server.mjs` against the stub console and checks that neither the
secret nor the cookie surfaces.
