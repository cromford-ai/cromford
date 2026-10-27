# The Tackler box_health source reads GET /api/box-health (BH-8553)

Doc: PR_UNBLOCK_AGENT_PLAN_2026-10-20

The infra collector (`bin/lib/unblock/collectors/infra.sh`) read `GET /api/boxes/health`. That path came from
the BH-7725 plan. BH-7710 shipped the route as `GET /api/box-health` with a different shape. The jobs worker
has no `/api/boxes/health`, so every hub tick recorded `source-unreadable box_health`, and U8 never saw a box.

## What changed

- `unblock_infra_src box_health` reads `GET /api/box-health`. A new function, `_unblock_infra_box_view`, maps
  each box to the record view `_unblock_infra_boxes` reads. `_unblock_infra_boxes` does not change.
- A box is in the view only when it has a probe row (`ssh.rc`) no older than `UNBLOCK_BOX_PROBE_STALE_S`
  (new knob, default 600 s, range 120..86400). A box with no probe row (the hub, no tailnet IP) or a stale
  probe gives no record.
- `ssh_unreachable_min` is the whole minutes since `ssh.last_ok_at`. `envbundle_fail_1h` is
  `lane_ssh_failures.count` when its window is 1..3600 s, else null. `orgo_hosted` / `orgo_state` follow
  `mcp/tools/box-health.mjs`: 1 live VM gives true and its status, 0 live with `vm_complete` true gives
  false, anything else gives null.
- `last_restart_min_ago` and `build_claim_10m` are null. The route does not carry them. So U8 does not match
  a collected record, and the record goes to U12 as a card. A follow-up can add those two reads.
- The source is unreadable (one `source-unreadable box_health` record) on a transport failure, a non-2xx, an
  empty or non-object body, no `boxes` array, or `partial` with `"ssh"`. A `"vm"` partial makes the Orgo
  fields null. A `"heartbeat"` partial changes nothing.

## Tests

- `tests/unblock-box-health-src.bh-8553-test.sh` (S1-S22).
- `worker/jobs/test/box-health-collector.bh-8553.test.js`: the real worker body through the shipped collector.
- `tests/unblock-infra-rules.bh-7725-test.sh` and `tests/fixtures/unblock/box-project-6-os.json` move to the real
  route and shape (TEST-CHANGE lines in both).
