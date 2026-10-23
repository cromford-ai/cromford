# The console settings screens sit under one side menu (BH-7938, slice C0)

Doc: CONSOLE

## What changed

- The menu is data in `console-ui/src/lib/settings-menu.js`. It holds the
  FLEET rows (AI vendors, GitHub app, Machines and Tailscale, Prompts, Lanes,
  Appearance) and the PROJECT rows (General, Tickets, AI accounts, Builds and
  machines, Deploy and QA, Alerts, Prompts, Pause and remove).
- A row with a tag is a page that is not built yet. It shows its tag and
  opens nothing. Prompts carries `wave 6b`, AI vendors and AI accounts carry
  `wave 4`, Tickets carries `wave 3`, and the pages the later slices of
  BH-7938 build carry `soon`.
- `console-ui/src/screens/settings/Shell.js` renders the menu and the active
  page at `/settings/fleet/:page` and `/settings/p/:project/:page`. Lanes and
  Appearance mount there with no change to `Settings.js` or `Appearance.js`.
- The fleet menu lists every project from `GET /api/dash/projects`. A
  project's page swaps in the project menu with a `← ALL SETTINGS` link.
- `App` (`console-ui/src/app.js`, `resolveRoute`) replaces `/settings` with
  `/settings/fleet/lanes`, `/settings/appearance` with
  `/settings/fleet/appearance` and `/settings/fleet` with
  `/settings/fleet/lanes`. It keeps the query and the hash, so every existing
  `/settings?project=<p>` link still opens that project's lane tab.
- At 768px and below the menu is one chip row that scrolls sideways inside
  itself (`console-ui/src/settings-shell.css`).

## Why

Ticket BH-7938 (wave 5 of the onboarding UI) asks for one settings page per
thing the floor can connect. Most of those pages read data that waves 2, 3 and
4 deliver, and those waves are not on main. This slice ships the shell, the
registry and the redirects. The pages follow in later slices.

## How to add a page

1. Remove the row's `tag` in `SETTINGS_MENU`, or add a new row.
2. Add the row id and its component to `SETTINGS_SCREENS` in `Shell.js`.
