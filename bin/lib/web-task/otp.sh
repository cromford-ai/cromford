#!/bin/bash
# bin/lib/web-task/otp.sh — a seam of the web-task lane (BH-7594, slice S1).
#
# A later slice fills it: wait for a one-time code (mail or SMS) during a sign-in.
#   wt_otp_wait <project> <site> <timeout-s>  -> the code
#
# S1 runs read-only on sites that need no sign-in, so every function here is a
# stub: it prints "not available" and returns 69 (EX_UNAVAILABLE). bin/web-task.sh
# sources this file, so the slice that fills it changes no caller wiring.
# Defines functions only; nothing runs on source.
# shellcheck shell=bash

wt_otp_wait() { echo "not available"; return 69; }
