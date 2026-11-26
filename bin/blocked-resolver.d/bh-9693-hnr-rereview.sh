# shellcheck shell=bash
# bin/blocked-resolver.d/bh-9693-hnr-rereview.sh — sources bin/lib/hnr-rereview.sh
# (BH-9693): br_rereview does not reuse another machine lane's BLOCK while the
# PR's re-review budget (MC_HNR_REREVIEW_MAX) has room; it buys the read. The
# call site is in br_rereview, behind `command -v mc_hnr_reuse`.
# shellcheck source=bin/lib/hnr-rereview.sh
if [ -r "${H:-}/bin/lib/hnr-rereview.sh" ]; then . "${H:-}/bin/lib/hnr-rereview.sh"; fi
