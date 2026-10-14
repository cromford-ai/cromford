# BH-4846: custom themes on /settings/appearance

Doc: worker/jobs/README.md

What changed:

- A custom console theme is a settings row `ui.theme.custom.<slug>` (slug
  `[a-z0-9-]{1,40}`) whose value is a theme document
  `{v:1, name, base, tokens, shape}`. `console-ui/src/theme/custom.js`
  `validateThemeDoc` is the gate: known colour keys only, colours that parse,
  fonts from the self-hosted set, radii 0-24px, every other shape key a value a
  built-in has, and every `TEXT_PAIRS` pair at 4.5:1 or better.
- The coord proxy runs that validator on every `PUT settings` to the prefix and
  answers 400 with its errors before forwarding. It admits one new write,
  `DELETE settings/ui.theme.custom.<slug>`, with the actor stamped in the query.
- The worker's `PUT /api/settings` gives the prefix the 4096-char document cap
  and refuses a value that is not a JSON object. `DELETE /api/settings/<key>` is
  new and accepts only that prefix; the row delete and its `setting`
  config_changes row go in one batch. A missing row is 200 `deleted:false`.
- Resolution (`console-ui/src/theme/resolve.js`) takes the valid custom ids as
  well as the built-ins. A viewer pick or fleet default naming a deleted custom
  theme falls through to the next step, Mill at the end. The `ui.theme.default`
  row is not rewritten when its theme is deleted.
- New localStorage key `ui.theme.cache`: the resolved custom theme object, so
  the boot script can paint it before any fetch. `syncFleetDefault` re-reads the
  rows on every load and repaints or clears it.
- SET AS FLEET DEFAULT shows only for a verified Access identity
  (`whoami.access === 'on'`). It is a UI gate: the worker's PUT is unchanged.
