# shellcheck shell=bash
# tests/lib/mergify-status-any-filter.sh — the BH-9039 transition filter for the
# "renders byte-identical to the merge base" checks of the Mergify suites.
# Sourced.
#
# BH-9039 adds the conf key `status_check_any=` (cromford.conf carries
# `status_check_any=lead-verdict|harness-verdict`). A renderer from before
# BH-9039 refuses the key (rc 2, "unknown key"), so a suite that renders the
# HEAD conf with the base renderer gets an empty base render. Those suites pin
# their OWN key (solo_label=, flake_fix_label=), not this one;
# tests/verdict-builder-context.bh-9039-test.sh part M owns status_check_any.
#
# SCOPED TO THE BASE. When the base renderer already knows `status_check_any`,
# the conf is copied unchanged: once BH-9039 is on main, every byte check runs
# on the real conf again. Before that, the one `status_check_any=<a>|<b>...`
# line becomes `status_check=<a>`, the shape the conf had before BH-9039, and
# BOTH renderers render that same conf.
#
# mergify_status_any_conf <base-renderer> <conf-in> <conf-out>. Always rc 0.
mergify_status_any_conf() {
  if grep -q 'status_check_any' "$1" 2>/dev/null; then
    cp "$2" "$3"
  else
    sed -E 's/^status_check_any=([^|]*)\|.*$/status_check=\1/' "$2" > "$3"
  fi
  return 0
}
