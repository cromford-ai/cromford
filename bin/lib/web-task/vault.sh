#!/bin/bash
# bin/lib/web-task/vault.sh — a seam of the web-task lane (BH-7594, slice S1).
#
# A later slice fills it: read a site credential from the vault for a sign-in.
#   wt_vault_get <project> <site>        -> the credential (never echoed to a log)
#
# S1 runs read-only on sites that need no sign-in, so every function here is a
# stub: it prints "not available" and returns 69 (EX_UNAVAILABLE). bin/web-task.sh
# sources this file, so the slice that fills it changes no caller wiring.
# Defines functions only; nothing runs on source.
# shellcheck shell=bash

wt_vault_get() { echo "not available"; return 69; }
