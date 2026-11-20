// Single-flight per isolate, with PLAIN VALUES only (BH-9850).
//
// Sentry CROMFORD-HARNESS-26: "This promise was created by a request that has
// since ended". ensureTable, ensureColumns (lib/core.js) and settingsRows
// (lib/settings-cache.js) kept a PENDING Promise in module state and gave it
// to every later request. In workerd a promise belongs to the request that
// made it: when one of the two requests ends first, the runtime drops the
// continuation and reports that error, and when the creator is cancelled its
// promise never settles, so every request that joined it hangs.
//
// So a slot here holds only plain values: { seq, running, startedAt, done },
// and done is { seq, ok, value } or { seq, ok: false, error }. A request that
// finds a run in flight does NOT await it. It polls the slot on its own timer
// (a setTimeout this request makes) at most ceil(waitMs / pollMs) times, and
// takes the result when done.seq >= the seq it joined at. When the polls run
// out first (the creator was cancelled, or is slow), it runs its own work.
// A poll COUNT bounds the wait, not Date.now(), so a frozen clock cannot make
// it endless. waitMs 0 means no join: every caller runs its own work.
//
// final: a successful run is kept, and later callers return its value at once
// (the ensureTable / ensureColumns memo). A failed run is never final: the
// next caller that finds no run in flight runs again.
//
// This file imports nothing, so lib/settings-cache.js can import it.

export const D1_FLIGHT_WAIT_MS = 3000; // fallback for settings row d1_flight.wait_ms
export const D1_FLIGHT_POLL_MS = 20; // fallback for settings row d1_flight.poll_ms
const WAIT_KEY = "d1_flight.wait_ms";
const POLL_KEY = "d1_flight.poll_ms";

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function knobInt(v, lo, hi) {
  if (typeof v !== "string" || !/^\d+$/.test(v)) return null;
  const n = Number(v);
  return n >= lo && n <= hi ? n : null;
}

// { waitMs, pollMs } from the settings snapshot in memory. `peek` is
// lib/settings-cache.js peekSetting, passed in so this file imports nothing.
// It never queries D1, because these bound a wait on an overloaded D1 (the
// same rule as retryKnobs in lib/d1-retry.js). A value that is not an integer
// or is out of range (wait 0..7000, poll 5..500) is ignored, never clamped.
export function flightKnobs(peek, db) {
  return {
    waitMs: knobInt(peek(db, WAIT_KEY), 0, 7000) ?? D1_FLIGHT_WAIT_MS,
    pollMs: knobInt(peek(db, POLL_KEY), 5, 500) ?? D1_FLIGHT_POLL_MS,
  };
}

function slotOf(slots, key) {
  let slot = slots.get(key);
  if (!slot) { slot = { seq: 0, running: false, startedAt: 0, done: null }; slots.set(key, slot); }
  return slot;
}

function settled(done) {
  if (done.ok) return done.value;
  throw done.error;
}

// Run `run` once for `key` in `slots` (a Map), or take the result of the run
// already in flight. Resolves or rejects like run() itself.
export async function isolateFlight(slots, key, run, { waitMs = D1_FLIGHT_WAIT_MS, pollMs = D1_FLIGHT_POLL_MS, final = false } = {}) {
  const slot = slotOf(slots, key);
  if (final && slot.done && slot.done.ok) return slot.done.value;
  if (slot.running && waitMs > 0) {
    const joined = slot.seq;
    const polls = Math.ceil(waitMs / Math.max(1, pollMs));
    for (let i = 0; i < polls; i++) {
      await sleep(pollMs);
      if (slot.done && slot.done.seq >= joined) return settled(slot.done);
    }
  }
  const mine = ++slot.seq;
  slot.running = true;
  slot.startedAt = Date.now();
  const record = (done) => { if (!slot.done || slot.done.seq <= mine) slot.done = done; };
  try {
    const value = await run();
    record({ seq: mine, ok: true, value });
    return value;
  } catch (error) {
    record({ seq: mine, ok: false, error });
    throw error;
  } finally {
    if (slot.seq === mine) slot.running = false;
  }
}

// Drop the run in flight for `key`: the next caller starts a fresh run.
// Callers that joined the old run still get its result.
export function detachFlight(slots, key) {
  const slot = slots.get(key);
  if (!slot) return;
  slot.seq += 1;
  slot.running = false;
}
