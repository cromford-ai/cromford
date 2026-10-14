#!/bin/bash
# shellcheck shell=bash
# bin/lib/flags.sh — BH-4153: the public entry for the box's flags. Sourced,
# never run. The verbs live in bin/lib/jobs/flags.sh (a bin/jobs-client.sh
# module, so every fixture that copies the client has them); this file only
# makes sure the client is loaded.
#
#   flag_has   [--scope S] [--cached] <name>        rc 0 on, 1 off, 2 unknown (read error, no cache)
#   flag_set   [--scope S] [--hold-local|--local-only] <name> [on|off|<value>] [reason]   rc 0 written, 1 not
#   flag_clear [--scope S] [--local-only] <name> [reason]                                rc 0 cleared, 1 not
#   flag_list  [--scope S] [--cached] <prefix>      active names, one a line; rc 0, or 2 unknown
#
# paused-*, automerge-disabled[-*], lanedown-* and dispatch-mode-* are harness_flags rows read
# DB-first with a last-good cache; every other name keeps the flags/ file.
# shellcheck source=bin/jobs-client.sh
command -v flag_has >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/../jobs-client.sh"
