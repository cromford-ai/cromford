# shellcheck shell=bash
# bin/merge-conductor.d/bh-9693-hnr-rereview.sh — sources bin/lib/hnr-rereview.sh
# (BH-9693): another lane's BLOCK on a moved head buys the conductor's own
# head-bound read before a `head-not-reapproved` park, capped per PR by
# MC_HNR_REREVIEW_MAX. The call sites are in headbound_review
# (bin/lib/mc/classify.sh), behind `command -v mc_hnr_decide`.
# shellcheck source=bin/lib/hnr-rereview.sh
if [ -r "${H:-}/bin/lib/hnr-rereview.sh" ]; then . "${H:-}/bin/lib/hnr-rereview.sh"; fi
