# BH-7978: the fleet Machines page (BH-7939.4, slice C0)

Doc: CONSOLE

What changed:
- Settings → FLEET → "Machines and Tailscale" is now a link. It opens
  `/settings/fleet/machines` (`console-ui/src/screens/settings/fleet/Machines.js`).
- The page has a Fly org field. SAVE writes the settings row `fly.org` through the
  existing `PUT /api/coord/settings`.
- The page shows "added" or "not added" for the Fly API token and the fleet
  Tailscale key. It reads only the rows `fly.token_present` and
  `tailscale.key_present`. A flag is set only when the value, trimmed, is `1`.
- The Provision a box button is disabled. With no Fly token it shows "Add your
  Fly API token first" and a link to the token row on the page.
- The gate copy and link are in `console-ui/src/lib/fly-settings.js`
  (`flyGate`, `FLY_GATE_TEXT`, `FLY_TOKEN_HREF`) for reuse.

Not in this slice (C1): `console-ui/src/api-fly.js`, Onboard step 1 Advanced,
the ProjectReady cards, the two token inputs (envelope targets `fly` and
`tailscale`), and an enabled Provision a box. C1 needs #7985, #7935, #7976,
#7975 and #7949 merged.
