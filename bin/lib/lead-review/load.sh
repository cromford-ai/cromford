#!/bin/bash
# shellcheck shell=bash
# bin/lib/lead-review/load.sh — loads the lead-review modules through the module map.
# No "# module:" header: this is the bootstrap, not a module. It lives in
# lead-review/ beside a symlink to ../module-map.sh, so a scratch copy of
# lead-review/ carries the loader too. Order: lead-review/MODULES, or the
# module headers when MODULES is absent.
# shellcheck source=bin/lib/module-map.sh
. "${BASH_SOURCE[0]%/*}/module-map.sh" || return 1
mm_load "${BASH_SOURCE[0]%/*}"
