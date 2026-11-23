#!/bin/bash
# bin/lib/ci-batch-red-causes.sh — one cause per red merge-queue batch (BH-9410).
# Sourced by bin/ci-batch-red-report.sh (the `--causes` table and the
# `causes=` field of the tick line), never executed.
#
# cbr_classify <runs_dir> <cut_epoch> prints one TSV row per readable red batch
# record (`concl red`, not `unread`) created at or after cut_epoch, oldest first:
#   run_id  created  culprit  cause  suites
# culprit is `<pr>@<head12>` (comma list) or `-`; suites is the failing suites,
# `job:<name>` rows included, comma list, or `-`.
#
# It reads local files only: no gh call, no network, no model call. A missing
# dir or file is "no evidence", never an error.
#   $runs_dir/<run_id>                       batch records (the report's step 4)
#   $HARNESS/state/merge-conductor/eject-cause/<owner>_<repo>_<pr>
#                                            the conductor's ec_record lines
#   $HARNESS/builds/pool-<proj>-*/gate.txt, $HARNESS/builds/<proj>-*/gate.txt
#     and <build>/selection-gate/selection.txt  the builder selection gate
#   $HARNESS/state/selection-gate/baseline/<sha>/<suite, / as _>, .primed
#   $HARNESS/state/selection-gate/prime.tsv  main red evidence
#   $CBR_RANDOM_DIR/*.tsv                    known random-dependent tests
#     (catalog/ci-batch-red-random.d/; the caller sets the dir; empty or
#     missing = no rows). Rows: match TAB test_file TAB settings_row TAB
#     since_iso TAB until_iso|- TAB ref. `#` lines and lines with fewer than 5
#     fields are skipped. A row whose since or until is not a date is dropped
#     with one stderr line.
# Every gate.txt is read once per call, not once per batch.
#
# Callers set: HARNESS (or H; empty = rc 1, no default root), CBR_REPO (owner/repo), CBR_EJECT_WINDOW_S and
# CBR_MAINRED_WINDOW_S (the report reads them from the lane knobs
# CI_BATCH_RED_EJECT_WINDOW_S and CI_BATCH_RED_MAINRED_WINDOW_S; 7200 here is
# only the fallback when a caller sets nothing).
#
# THE RULE. The first cause that holds is the batch's cause:
#   1 main-red             a failing suite was red on main in
#                          [created - MAINRED window, created]: a baseline file
#                          `red` whose sha dir (or its .primed) has an mtime in
#                          the window, a prime.tsv `red` row of such a sha, or a
#                          gate.txt (mtime in the window) whose baseline-red:
#                          lists the suite.
#   2 seeded-random        (BH-9410, comment 6780574176) the batch has a
#                          failing entry, and EVERY failing entry (suite or
#                          job:<name>) equals the match of a catalog row with
#                          since <= created < until (until `-` = open). An
#                          exact string match: never a prefix or a substring.
#                          Before flake, because a known sampler fault also
#                          passes on a re-run; it needs every entry, so a real
#                          broken suite next to it never hides behind it.
#   3 flake                the batch's tree is the tree of a green record.
#   4 unchanged-requeue    a culprit's eject line is `again`, or the same
#                          (pr, head) has an eject line before the batch.
#   5 first-run            a culprit head has no gate.txt, or its newest gate.txt
#                          rc is could-not-run, no-selection or off, or its
#                          selection.txt omits a failing suite. With no culprit:
#                          a readable legacy `gate` line omits a failing suite.
#   6 gate-green-batch-red a culprit head's newest gate.txt is rc 0, or rc 1
#                          whose red: omits a failing suite, and that suite is
#                          in its selection.txt when one exists. With no
#                          culprit: a legacy `gate` line lists a failing suite.
#   7 unknown              none of the above.
# A culprit is a member PR with an eject line of cause batch-red or checks at
# an epoch in [created, created + EJECT window]. Rules 3-5 need at least one
# failing suite (not a `job:<name>` row): a batch that failed only on a job has
# only the batch-level causes (main-red cannot hold, so seeded-random or flake)
# or unknown.
#
# rc 0 with rows (or none: no runs dir, no red record); rc 1 when there is no
# harness root or no temp dir, which a caller reads as "unreadable".
#
# CBR_CAUSES is the fixed cause order every reader prints.
CBR_CAUSES="main-red seeded-random first-run gate-green-batch-red flake unchanged-requeue unknown"

cbr_classify() {
  local runs="$1" cut="$2" h="${HARNESS:-${H:-}}" t proj slug ew mw pr f g d
  # No harness root: refuse (rc 1), never a default root (D43).
  [ -n "$h" ] || return 1
  ew="${CBR_EJECT_WINDOW_S:-7200}"; mw="${CBR_MAINRED_WINDOW_S:-7200}"
  case "$ew" in ''|*[!0-9]*) ew=7200 ;; esac
  case "$mw" in ''|*[!0-9]*) mw=7200 ;; esac
  case "$cut" in ''|*[!0-9]*) cut=0 ;; esac
  [ -d "$runs" ] || return 0
  t=$(mktemp -d "${TMPDIR:-/tmp}/cbr.XXXXXX") || return 1
  local repo="${CBR_REPO:-}"
  proj="${repo##*/}"; slug="${repo//\//_}"
  # 1. records: R rows (red, readable, in the window) and G rows (green trees)
  local -a recs=()
  for f in "$runs"/[0-9]*; do
    case "$f" in *.strikes|*.tmp) continue ;; esac
    [ -f "$f" ] && recs+=("$f")
  done
  if [ "${#recs[@]}" -gt 0 ]; then
    awk -v cut="$cut" '
      FNR == 1 {
        use = 0; split($0, h, " ")
        if (h[1] != "run" || h[5] != "created" || h[7] != "concl" || h[9] != "tree" || h[11] != "prs") next
        if (h[8] == "green") { if (h[10] != "-") print "G\t" h[10]; next }
        if (h[8] != "red" || h[13] == "unread" || h[6] + 0 < cut) next
        use = 1; r = h[2]; C[r] = h[6] + 0; TR[r] = h[10]; P[r] = h[12]; S[r] = ""; L[r] = ""; ord[++n] = r; next
      }
      !use { next }
      { split($0, x, "\t") }
      x[1] == "fail" && index("," S[r] ",", "," x[2] ",") == 0 { S[r] = S[r] (S[r] == "" ? "" : ",") x[2]; next }
      x[1] == "gate" { L[r] = L[r] (L[r] == "" ? "" : ";") x[2] "=" x[3] "=" x[4]; next }
      END { for (i = 1; i <= n; i++) { r = ord[i]
              printf "R\t%s\t%d\t%s\t%s\t%s\t%s\n", r, C[r], TR[r], P[r], (S[r] == "" ? "-" : S[r]), (L[r] == "" ? "-" : L[r]) } }
    ' "${recs[@]}" > "$t/in" 2>/dev/null
  else
    : > "$t/in"
  fi
  if ! grep -q '^R' "$t/in"; then rm -rf "$t"; return 0; fi
  # 2. eject lines of every member PR of those batches
  for pr in $(awk -F'\t' '$1 == "R" && $5 != "-" { n = split($5, p, ","); for (i = 1; i <= n; i++) print p[i] }' "$t/in" | LC_ALL=C sort -un); do
    f="$h/state/merge-conductor/eject-cause/${slug}_$pr"
    [ -r "$f" ] && awk -F'\t' -v p="$pr" 'NF >= 4 && $1 ~ /^[0-9]+$/ { print "E\t" p "\t" $1 "\t" $2 "\t" $3 "\t" $4 }' "$f" >> "$t/in" 2>/dev/null
  done
  # 3. gate.txt files (one read each) and their selection lists
  local -a gates=()
  for g in "$h/builds/pool-$proj-"*/gate.txt "$h/builds/$proj-"*/gate.txt; do [ -f "$g" ] && gates+=("$g"); done
  if [ "${#gates[@]}" -gt 0 ]; then
    stat -c '%Y %n' "${gates[@]}" 2>/dev/null | awk '{ m = $1; sub(/^[0-9]+ /, ""); print "M\t" $0 "\t" m }' > "$t/gm"
    awk '
      FNR == 1 && FILENAME != mf { if (NR != FNR) flush(); fn = FILENAME; hd = ""; rc = ""; red = "-"; br = "-" }
      FILENAME == mf { split($0, x, "\t"); MT[x[2]] = x[3]; next }
      /^head: / { hd = substr($0, 7) } /^rc: / { rc = substr($0, 5) }
      /^red: / { red = substr($0, 6) } /^baseline-red: / { br = substr($0, 15) }
      function flush(  sp, d) {
        if (fn == "" || hd == "") return
        d = fn; sub(/\/gate\.txt$/, "", d); sp = d "/selection-gate/selection.txt"
        printf "T\t%s\t%d\t%s\t%s\t%s\t%s\n", hd, MT[fn] + 0, rc, (red == "" ? "-" : red), (br == "" ? "-" : br), sp
        fn = ""
      }
      END { flush() }
    ' mf="$t/gm" "$t/gm" "${gates[@]}" >> "$t/in" 2>/dev/null
    for g in "${gates[@]}"; do
      d="${g%/gate.txt}/selection-gate/selection.txt"
      [ -r "$d" ] && awk -v sp="$d" 'NF { print "S\t" sp "\t" $1 }' "$d" >> "$t/in" 2>/dev/null
      [ -r "$d" ] && printf 'X\t%s\n' "$d" >> "$t/in"
    done
  fi
  # 4. main red evidence: baseline sha dirs and their red files, prime.tsv
  local bd="$h/state/selection-gate/baseline"
  if [ -d "$bd" ]; then
    for d in "$bd"/*/; do
      d="${d%/}"; [ -d "$d" ] || continue
      printf 'B\t%s\t%s\n' "${d##*/}" "$(stat -c %Y "$d" 2>/dev/null || echo 0)" >> "$t/in"
      [ -e "$d/.primed" ] && printf 'B\t%s\t%s\n' "${d##*/}" "$(stat -c %Y "$d/.primed" 2>/dev/null || echo 0)" >> "$t/in"
      for f in "$d"/*; do
        [ -f "$f" ] || continue
        [ "$(head -c 4 "$f" 2>/dev/null)" = red ] && printf 'F\t%s\t%s\n' "${d##*/}" "${f##*/}" >> "$t/in"
      done
    done
  fi
  [ -r "$h/state/selection-gate/prime.tsv" ] \
    && awk -F'\t' 'NF == 3 && $3 == "red" { print "P\t" $1 "\t" $2 }' "$h/state/selection-gate/prime.tsv" >> "$t/in" 2>/dev/null
  # 5. the known random-dependent tests: Q rows, dates as epochs, once per call
  local rd="${CBR_RANDOM_DIR:-}" m tf sr si ui ln se ue
  if [ -n "$rd" ] && [ -d "$rd" ]; then
    for f in "$rd"/*.tsv; do
      [ -r "$f" ] || continue
      ln=0
      while IFS=$'\t' read -r m tf sr si ui _ || [ -n "$m" ]; do
        ln=$((ln + 1))
        case "$m" in ''|'#'*) continue ;; esac
        [ -n "$ui" ] || continue
        # An empty date is bad too: GNU date -d "" answers today's 00:00Z.
        se=""; [ -n "$si" ] && se=$(date -u -d "$si" +%s 2>/dev/null)
        [ -n "$se" ] || { echo "ci-batch-red-causes: $f:$ln: bad date '$si' — row dropped" >&2; continue; }
        ue=0
        if [ "$ui" != - ]; then
          ue=""; [ -n "$ui" ] && ue=$(date -u -d "$ui" +%s 2>/dev/null)
          [ -n "$ue" ] || { echo "ci-batch-red-causes: $f:$ln: bad date '$ui' — row dropped" >&2; continue; }
        fi
        printf 'Q\t%s\t%s\t%s\n' "$m" "$se" "$ue" >> "$t/in"
      done < "$f"
    done
  fi
  # 6. the rule, one pass over everything read
  awk -F'\t' -v ew="$ew" -v mw="$mw" '
    function same(a, b) { return length(a) >= 7 && length(b) >= 7 && (index(a, b) == 1 || index(b, a) == 1) }
    function has(csv, v) { return index("," csv ",", "," v ",") > 0 }
    function us(s,   u) { u = s; gsub("/", "_", u); return u }
    $1 == "R" { nr++; RID[nr] = $2; RC_[nr] = $3; RTAB[nr] = $4; RP[nr] = $5; RSU[nr] = $6; RL[nr] = $7; next }
    $1 == "G" { GT[$2] = 1; next }
    $1 == "E" { ne++; EP[ne] = $2; EE[ne] = $3 + 0; EH[ne] = $4; EO[ne] = $5; EC[ne] = $6; next }
    $1 == "T" { nt++; TH[nt] = $2; TM[nt] = $3 + 0; TRC[nt] = $4; TRED[nt] = $5; TBR[nt] = $6; TSP[nt] = $7; next }
    $1 == "S" { SEL[$2, $3] = 1; next }
    $1 == "X" { SX[$2] = 1; next }
    $1 == "B" { nb++; BS[nb] = $2; BM[nb] = $3 + 0; next }
    $1 == "F" { BF[$2, $3] = 1; next }
    $1 == "P" { PR_[$2, $3] = 1; next }
    $1 == "Q" { nq++; QM[nq] = $2; QS[nq] = $3 + 0; QU[nq] = $4 + 0; next }
    # a catalog row names entry e at batch time c (exact match, [since, until))
    function known(e, c,   i) { for (i = 1; i <= nq; i++) if (QM[i] == e && QS[i] <= c && (QU[i] == 0 || c < QU[i])) return 1; return 0 }
    function mainred(s, c,   i, lo) {
      lo = c - mw
      for (i = 1; i <= nb; i++) if (BM[i] >= lo && BM[i] <= c && (((BS[i], us(s)) in BF) || ((BS[i], s) in PR_))) return 1
      for (i = 1; i <= nt; i++) if (TM[i] >= lo && TM[i] <= c && has(TBR[i], s)) return 1
      return 0
    }
    # newest gate.txt index for head h, 0 when none
    function gate(hd,   i, b) { b = 0; for (i = 1; i <= nt; i++) if (same(TH[i], hd) && (b == 0 || TM[i] > TM[b])) b = i; return b }
    END {
      for (k = 1; k <= nr; k++) {
        c = RC_[k] + 0; ns = split(RSU[k] == "-" ? "" : RSU[k], fs, ","); nreal = 0
        for (i = 1; i <= ns; i++) if (fs[i] !~ /^job:/) real[++nreal] = fs[i]
        # culprits: member PRs ejected for batch-red or checks in [c, c + ew]
        nc = 0; cul = ""; delete CPR; delete CHD; delete CJ
        np = split(RP[k] == "-" ? "" : RP[k], pp, ",")
        for (j = 1; j <= ne; j++) {
          if (EE[j] < c || EE[j] > c + ew || (EC[j] != "batch-red" && EC[j] != "checks")) continue
          mem = 0; for (i = 1; i <= np; i++) if (pp[i] == EP[j]) mem = 1
          if (!mem) continue
          dup = 0; for (i = 1; i <= nc; i++) if (CPR[i] == EP[j] && same(CHD[i], EH[j])) dup = 1
          if (dup) continue
          nc++; CPR[nc] = EP[j]; CHD[nc] = EH[j]; CJ[nc] = j
          cul = cul (cul == "" ? "" : ",") EP[j] "@" substr(EH[j], 1, 12)
        }
        cause = "unknown"
        # 1 main-red
        for (i = 1; i <= nreal; i++) if (mainred(real[i], c)) { cause = "main-red"; break }
        # 2 seeded-random: every failing entry is a known random-dependent test
        if (cause == "unknown" && ns > 0) {
          kn = 1; for (i = 1; i <= ns; i++) if (!known(fs[i], c)) { kn = 0; break }
          if (kn) cause = "seeded-random"
        }
        # 3 flake
        if (cause == "unknown" && RTAB[k] != "-" && (RTAB[k] in GT)) cause = "flake"
        if (cause == "unknown" && nreal > 0) {
          # 4 unchanged-requeue
          for (i = 1; i <= nc && cause == "unknown"; i++) {
            if (EO[CJ[i]] == "again") { cause = "unchanged-requeue"; break }
            for (j = 1; j <= ne; j++) if (EP[j] == CPR[i] && same(EH[j], CHD[i]) && EE[j] < c) { cause = "unchanged-requeue"; break }
          }
        }
        if (cause == "unknown" && nreal > 0) {
          fr = 0; gg = 0
          if (nc > 0) {
            for (i = 1; i <= nc; i++) {
              b = gate(CHD[i])
              if (b == 0 || TRC[b] == "could-not-run" || TRC[b] == "no-selection" || TRC[b] == "off") { fr = 1; continue }
              hs = (TSP[b] in SX)
              for (m = 1; m <= nreal; m++) {
                s = real[m]
                if (hs && !((TSP[b], s) in SEL)) { fr = 1; continue }
                if (TRC[b] == "0" || (TRC[b] == "1" && !has(TRED[b], s))) gg = 1
              }
            }
          } else {
            nl = split(RL[k] == "-" ? "" : RL[k], ll, ";")
            for (i = 1; i <= nl; i++) {
              split(ll[i], gx, "=")
              if (gx[2] == "?") continue
              for (m = 1; m <= nreal; m++) { if (has(gx[3], real[m])) gg = 1; else fr = 1 }
            }
          }
          if (fr) cause = "first-run"; else if (gg) cause = "gate-green-batch-red"
        }
        printf "%s\t%d\t%s\t%s\t%s\n", RID[k], c, (cul == "" ? "-" : cul), cause, RSU[k]
      }
    }' "$t/in" | LC_ALL=C sort -t "$(printf '\t')" -k2,2n -k1,1n
  rm -rf "$t"
  return 0
}

# cbr_counts — the cbr_classify rows on stdin as the tick line field value:
#   main-red:<n>,seeded-random:<n>,first-run:<n>,gate-green-batch-red:<n>,flake:<n>,unchanged-requeue:<n>,unknown:<n>
cbr_counts() {
  awk -F'\t' -v order="$CBR_CAUSES" '
    NF >= 4 { n[$4]++ }
    END { k = split(order, o, " "); for (i = 1; i <= k; i++) printf "%s%s:%d", (i > 1 ? "," : ""), o[i], n[o[i]] + 0; print "" }'
}
