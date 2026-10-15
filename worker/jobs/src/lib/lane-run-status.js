// The API status of a lane_runs row (BH-6817). D1 keeps `done` + rc for every
// reported run, because the CHECK constraint of schema.d/0020 allows only
// queued/claimed/done/died. The report route and the by-prefix read answer
// `failed` for a `done` row whose rc is not 0, with a reason.

const COMMAND_MISSING_RC = new Set([126, 127]);

// `failed` for a done row with rc != 0, else the D1 status.
export function runStatus(row) {
  if (row.status === "done" && row.rc !== null && row.rc !== undefined && Number(row.rc) !== 0) return "failed";
  return row.status;
}

// `command-missing` for rc 126/127, `exit-nonzero` for any other non-zero rc,
// else null.
export function failReason(rc) {
  if (rc === null || rc === undefined) return null;
  const n = Number(rc);
  if (n === 0) return null;
  return COMMAND_MISSING_RC.has(n) ? "command-missing" : "exit-nonzero";
}
