# SEED REGISTRY panel on /hub (BH-2521, slice BH-2677)

Doc: CONSOLE

## What changed

- **`console-ui/src/lib/registry-seed.js` (new, pure).** `planView` accepts a
  plan only when `insert`, `update` and `prune` are arrays and `plan_fp` is 64
  lowercase hex. Anything else throws `bad response`. `planRows` turns the plan
  into KEY / ACTION / FROM / TO rows. The worker sends only a key for an insert
  or a prune, so FROM and TO show "—" for those. `applyOutcome` maps the apply
  answer: a 409 `fleet_gate` names each box and its reason and says a retired
  box is excluded with `harness-ctl.sh seed-registry --exclude-box <box>`,
  run from the hub. A 409 `plan_moved` says the plan changed. A 200 with an
  `id` names the changed and pruned counts. A 200 without an `id` is a failure.
  `runsView` shows a `started` run younger than 10 minutes as "in progress".
  An older one, or one with no parseable `started_at`, shows "outcome unknown",
  never "applied".
- **`console-ui/src/screens/hub/SeedRegistry.js`** fills in the contract stub.
  `SeedRegistryPanel` keeps its name and takes no props, and `Hub.js` already
  mounts it. It has a counts line, REFRESH, APPLY and the plan table, then
  RECENT APPLIES (WHEN / ACTOR / STATUS / CHANGED / PRUNED). Both tables are
  `SortableTable`. It loads the plan and the runs once on mount and again on
  REFRESH. It does not poll.
- **APPLY** is disabled until a plan loads, when the plan has nothing to
  apply, and while an apply is in flight. It asks in the in-app `useConfirm`
  dialog. Only CONFIRM sends the POST, once, with the loaded `plan_fp`. After
  any answer it shows the outcome and reloads the plan and the runs. CANCEL
  sends nothing.
- **A `lane.<id>.<env>` key** links to `/settings/<id>`. A `lib.` key stays
  text because no lib settings route exists.
- **`tests/hub-seed-chat-contract.bh-2521-test.sh`** used to call
  `SeedRegistryPanel({})` and expect `null`, which pinned the stub. The panel
  imports preact and calls hooks now, so the suite checks it is a zero-prop
  function, and only where `console-ui/node_modules` is installed (the shell
  suite job does not install it). The `ChatBindingsPanel` stub check still
  runs everywhere.

## Before the worker slice deploys

The plan GET has no `plan_fp` until BH-2521's worker slice (#2676) deploys.
Until then the section shows "could not load — bad response" with RETRY, not
"Nothing to apply". APPLY stays disabled. If the runs route is not there yet,
RECENT APPLIES shows its own load error.

## Run detail

Clicking a run's WHEN cell expands that run: its `error` (a failed apply's
reason), the `changed_keys` and `pruned_keys` behind the counts (a lane key
links to `/settings/<id>`), `plan_fp` and `finished_at`. A key list the worker
did not send shows as unknown, not as "none".

## Not in this slice

On a `plan_moved` answer the panel reloads the plan GET. It does not render the
`plan` carried in the 409 body.
