#!/bin/bash
# shellcheck shell=bash
# bin/lib/hub-probes/repo-create.sh — BH-7997 (BH-7935 wave 2): the placeholder
# for the repo-create screen probe. Sourced by common.sh's hp_run. It defines no
# hp_probe_repo_create yet, so `hp_run repo-create <owner> <name> <template>`
# prints not-implemented and returns 1, and a filed row creates no repo.
# owner BH-7935.4
