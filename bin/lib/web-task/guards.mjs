// bin/lib/web-task/guards.mjs — the pure guards of the web-task agent
// (BH-7594, slice S1). No browser, no I/O: bin/web-task-agent.mjs calls them
// in its tool layer, and tests/web-task-lane.bh-7594-test.sh drives them on
// plain inputs.
//
//   normDomains(list)        the allow-list, lowercased, trimmed, without a
//                            trailing dot, empties and malformed entries dropped
//   hostAllowed(url, list)   true only for an http/https URL whose host is a
//                            listed entry or a subdomain of one. An IPv4 entry
//                            matches itself only. An empty list allows nothing.
//   isSubmitLike(desc)       true for a control a read-only run must not click.
//                            It is isWriteAction of bin/lib/web-write-step.mjs
//                            (one classifier for the read-only refusal and the
//                            write gate): a submit input, a button that submits
//                            its form, or a control whose name or role reads as
//                            submit, pay, delete, send, save, confirm, update or
//                            apply (and their kin)
//   sanitizeTyped(text)      typed text without CR or LF, so a `type` action can
//                            never press Enter into a form

import { isWriteAction } from "../web-write-step.mjs";

const IPV4 = /^\d{1,3}(\.\d{1,3}){3}$/;
const ENTRY = /^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$/;

export function normDomains(list) {
  const src = Array.isArray(list) ? list : String(list ?? "").split(/[\s,]+/);
  const out = [];
  for (const raw of src) {
    const d = String(raw ?? "").trim().toLowerCase().replace(/\.+$/, "");
    if (d && ENTRY.test(d) && !out.includes(d)) out.push(d);
  }
  return out;
}

export function hostAllowed(url, list) {
  let u;
  try { u = new URL(String(url)); } catch { return false; }
  if (u.protocol !== "http:" && u.protocol !== "https:") return false;
  if (u.username || u.password) return false;
  const host = u.hostname.toLowerCase().replace(/\.+$/, "");
  if (!host) return false;
  for (const d of normDomains(list)) {
    if (host === d) return true;
    if (!IPV4.test(d) && !IPV4.test(host) && host.endsWith("." + d)) return true;
  }
  return false;
}

export function isSubmitLike(desc) {
  return isWriteAction(desc);
}

export function sanitizeTyped(text) {
  return String(text ?? "").replace(/[\r\n]/g, "");
}
