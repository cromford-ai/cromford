// The one list of box_commands types in the worker (BH-5750). The route
// imports it; the console keeps its own copy (the Pages build cannot import
// from worker/), and test/box-command-types-drift.bh-5750.test.js holds this
// list, the console's BOX_COMMAND_TYPES and the box_commands_v2 CHECK in
// schema.sql as equal sets.

export const FLY = new Set(["fly_machine_stop", "fly_machine_destroy"]);

// Orgo box controls, run on the hub by bin/box-ops.sh through
// `box-ops.sh <verb>` and bin/box-launch.sh.
export const ORGO = new Set([
  "orgo_restart", "orgo_stop", "orgo_resize_quote", "orgo_resize", "orgo_retire",
  "orgo_launch_quote", "orgo_launch",
]);

// Fly pool controls, run on the hub: bin/pool-cap.sh --set and bin/fly-onboard.sh.
export const FLY_POOL = new Set(["fly_pool_cap", "fly_onboard"]);

export const TYPES = [
  "backup_now", "fly_machine_stop", "fly_machine_destroy", "harness_sync", "cli_update",
  ...ORGO, ...FLY_POOL,
];

// A costing type names the quote type whose finished row prices it.
export const QUOTE_OF = { orgo_resize: "orgo_resize_quote", orgo_launch: "orgo_launch_quote" };

// Only an owner (env.BOX_OPS_OWNERS) may request these.
export const OWNER_ONLY = new Set([...ORGO, ...FLY_POOL]);
