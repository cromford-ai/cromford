#!/bin/bash
# bin/lib/web-task/session.sh — a seam of the web-task lane (BH-7594, slice S1).
#
# A later slice fills it: keep a signed-in browser session between runs.
#   wt_session_load <project> <site>     -> a storage-state file path
#   wt_session_save <project> <site> <file>
#
# S1 runs read-only on sites that need no sign-in, so every function here is a
# stub: it prints "not available" and returns 69 (EX_UNAVAILABLE). bin/web-task.sh
# sources this file, so the slice that fills it changes no caller wiring.
# Defines functions only; nothing runs on source.
# shellcheck shell=bash

wt_session_load() { echo "not available"; return 69; }

wt_session_save() { echo "not available"; return 69; }
