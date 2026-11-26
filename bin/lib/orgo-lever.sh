#!/bin/bash
# bin/lib/orgo-lever.sh — the one text for a dead Orgo restart lever (BH-9889).
# Sourced, never run. Defines functions only.
#
# The restart lever is bin/box-ops.sh restart (and the Mission Control restart
# button, which runs it). It needs the Orgo key (ORGO_API_KEY, or an account's
# key_env from catalog/orgo-plans.json). With the key unset every restart is
# refused, and a dark box stays dark. bin/lib/box-ops-orgo.sh calls
# orgo_lever_alert on each refused --apply; the C1 box-watch lane uses the same
# text for its hourly lever check, so an operator sees one row, not two.
#
#   orgo_lever_text <keyenv> <why>   prints the text. <why> `unset` reads
#                                    "<KEYENV> is not set"; any other value is
#                                    printed after the key name. Never a value.
#   orgo_lever_alert <keyenv> <why>  one warn alert, --id orgo-lever-<KEYENV>,
#                                    through $HARNESS/bin/alert-line.sh (no
#                                    root known = no alert). Always
#                                    returns 0; its output is dropped.

orgo_lever_text() {
  local keyenv="${1:-ORGO_API_KEY}" why="${2:-unset}" host state
  host="${HOSTNAME:-$(hostname 2>/dev/null)}"
  if [ "$why" = unset ]; then state="$keyenv is not set"; else state="$keyenv $why"; fi
  printf '%s\n' "[orgo-lever] restart lever dead on ${host:-unknown}: $state. bin/box-ops.sh restart and the Mission Control restart button refuse every box until it is fixed. Put $keyenv in env/global.env on the hub."
}

orgo_lever_alert() {
  local keyenv="${1:-ORGO_API_KEY}" h="${HARNESS:-${H:-}}"
  [ -n "$h" ] && [ -x "$h/bin/alert-line.sh" ] || return 0
  "$h/bin/alert-line.sh" --severity warn --id "orgo-lever-$keyenv" "$(orgo_lever_text "$keyenv" "${2:-unset}")" >/dev/null 2>&1 || true
  return 0
}
