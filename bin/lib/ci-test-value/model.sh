#!/bin/bash
# bin/lib/ci-test-value/model.sh — ctv_model_pass <occurrences.tsv>: the model
# pass over the rows the rules left undecided (BH-6618.3). Sourced by
# bin/lib/ci-test-value.sh, never executed; nothing runs on source.
# ctv_classify_all calls it unless CTV_NO_MODEL=1 (--no-model).
#
# Only rows with class `unknown` and rule `U1.undecided` are read, and only
# their columns 11 (class), 12 (rule) and 15 (why) change. Each one gets a
# label from ONE stage, ci-test-value, through bin/agent-call.sh. The model
# is model_routes stage.ci-test-value (lane_role_model). No route, no harness
# root or no readable prompt is no call: the rows stay U1.undecided.
#
#   CTV_MODEL_BATCH=20                       rows per call
#   CTV_MODEL_MAX_CALLS=20                   calls per pass; the rest stay
#                                            U1.undecided, why `model call cap N`
#   AGENT_CALL_BUDGET_USD_CI_TEST_VALUE=0.50 agent-call's cap per call
# A bad knob is one stderr line and rc 1, with no call.
#
# DEDUP BEFORE SPEND. fp = sha256(run_id|attempt|job_id|unit|sha256(excerpt)).
# The ledger is <out>/cache/model/<fp>.attempt and <fp>.json, append-only per
# fp; the driver's flock on <out>/.lock serializes the pass.
#   - <fp>.json is terminal: the row takes it, no call.
#   - <fp>.attempt alone is a billed call that crashed: the row becomes
#     unknown M1.unparseable `no answer recorded`, never asked again.
#   - .attempt is written for every row of a batch BEFORE the call. A failed
#     write is no call (why `cache write failed`).
#   - agent-call rc 74..79 billed nothing: the .attempt files go, no .json, the
#     rows stay U1.undecided with why `model refused rc=N`.
#   - Any other non-zero rc is billed: unknown M1.unparseable `model failed rc=N`.
#   - rc 0: an answer line counts only when its fp is in the batch and its
#     label is a class. A batch row with no such line is unknown M1.unparseable
#     `empty or invalid answer`. A kept line is <label> M1.model <why>.
# A row whose excerpt file cannot be found is not asked (why `no excerpt`).

_CTV_MODEL_LABELS=" real-pr real-main test-defect infra flake order unknown "

_ctv_sha() { sha256sum | cut -c1-64; }

# _ctv_model_excerpt <out> <job_id> <unit> -> the excerpt path the driver
#   wrote, numbered the way read_job numbers it: the unit's line in the job
#   log's failed-unit list. A job:<name> unit is the only unit of its job (1).
_ctv_model_excerpt() {
  local out="$1" jid="$2" unit="$3" n="" log
  if [[ "$unit" == job:* ]]; then
    n=1
  else
    log="$out/cache/log/$jid.txt"
    [ -r "$log" ] && declare -F ctv_parse_job_log >/dev/null || return 1
    n=$(ctv_parse_job_log < "$log" | LC_ALL=C awk -F'\t' '$2 != "0" && !seen[$1]++' \
      | LC_ALL=C awk -F'\t' -v u="$unit" '{ gsub(/[\t\r\037]/, " ", $1) } $1 == u { print NR; exit }')
  fi
  [ -n "$n" ] && [ -r "$out/cache/excerpt/$jid-$n.txt" ] || return 1
  printf '%s\n' "$out/cache/excerpt/$jid-$n.txt"
}

# _ctv_model_put <file> <label> <rule> <why>: one terminal answer, tmp + mv.
_ctv_model_put() {
  jq -n -c --arg l "$2" --arg r "$3" --arg w "$4" '{label: $l, rule: $r, why: $w}' > "$1.tmp.$$" \
    && mv -f "$1.tmp.$$" "$1" || { rm -f "$1.tmp.$$"; return 1; }
}

ctv_model_pass() { # ctv_model_pass <occurrences.tsv>
  local occ="${1:-}" batch max usd out cache root repo model prompt
  local ln run att jid ev isb unit urc fp ex label rule why line i k pf raw rc tmp wfail
  local undecided=0 cached=0 asked=0 calls=0 labelled=0 unparseable=0 refused=0 noroute=0
  local -a ask=() part=() written=() w
  local -A res=() row_fp=() meta=() exf=() got=() kept=()
  [ -n "$occ" ] && [ -r "$occ" ] || return 0
  LC_ALL=C awk -F'\t' '!/^#/ && $11 == "unknown" && $12 == "U1.undecided" { f = 1; exit } END { exit !f }' "$occ" || return 0

  batch="${CTV_MODEL_BATCH:-20}" max="${CTV_MODEL_MAX_CALLS:-20}" usd="${AGENT_CALL_BUDGET_USD_CI_TEST_VALUE:-0.50}"
  [[ "$batch" =~ ^[1-9][0-9]*$ ]] || { echo "ctv: CTV_MODEL_BATCH must be a whole number >= 1: $batch" >&2; return 1; }
  [[ "$max" =~ ^[1-9][0-9]*$ ]] || { echo "ctv: CTV_MODEL_MAX_CALLS must be a whole number >= 1: $max" >&2; return 1; }
  if ! [[ "$usd" =~ ^[0-9]+(\.[0-9]+)?$ ]] || [[ "$usd" =~ ^[0.]+$ ]]; then
    echo "ctv: AGENT_CALL_BUDGET_USD_CI_TEST_VALUE must be a USD amount above 0: $usd" >&2; return 1
  fi
  out=$(dirname "$occ"); cache="$out/cache/model"
  mkdir -p "$cache" 2>/dev/null || { echo "ctv: cannot make $cache" >&2; return 1; }

  # Each undecided row: its fp, then the ledger.
  while IFS=$'\x1f' read -r ln run att jid ev isb unit urc; do
    undecided=$((undecided + 1))
    if ! ex=$(_ctv_model_excerpt "$out" "$jid" "$unit"); then
      res[$ln]=$'unknown\tU1.undecided\tno excerpt'; continue
    fi
    fp=$(printf '%s' "$run|$att|$jid|$unit|$(_ctv_sha < "$ex")" | _ctv_sha)
    row_fp[$ln]=$fp
    if [ -f "$cache/$fp.json" ]; then
      cached=$((cached + 1))
      line=$(jq -r '[.label, .rule, .why] | map(strings) | select(length == 3) | join("\t")' "$cache/$fp.json" 2>/dev/null)
      [ -n "$line" ] || line=$'unknown\tM1.unparseable\tcached answer unreadable'
      res[$ln]=$line
    elif [ -f "$cache/$fp.attempt" ]; then
      cached=$((cached + 1))
      _ctv_model_put "$cache/$fp.json" unknown M1.unparseable "no answer recorded" && rm -f "$cache/$fp.attempt"
      res[$ln]=$'unknown\tM1.unparseable\tno answer recorded'
    elif [ -z "${exf[$fp]:-}" ]; then
      ask+=("$fp"); exf[$fp]=$ex; meta[$fp]="$unit"$'\x1f'"$urc"$'\x1f'"$ev"$'\x1f'"$isb"
    fi
  done < <(LC_ALL=C awk -F'\t' -v OFS='\037' '!/^#/ && $11 == "unknown" && $12 == "U1.undecided" { print NR, $1, $2, $3, $5, $6, $8, $9 }' "$occ")

  # The route, only when there is a row to ask.
  if [ "${#ask[@]}" -gt 0 ]; then
    root="${HARNESS:-${H:-}}"
    repo="${_CTV_LIB_DIR:+$_CTV_LIB_DIR/../..}"
    prompt="$repo/catalog/prompts/ci-test-value-classify.md"
    model=
    if [ -n "$root" ] && [ -n "$repo" ] && [ -r "$prompt" ]; then
      if ! declare -F lane_role_model >/dev/null; then
        # shellcheck source=bin/lib/lane-model.sh
        . "$_CTV_LIB_DIR/lane-model.sh" 2>/dev/null || true
      fi
      declare -F lane_role_model >/dev/null && model=$(lane_role_model stage.ci-test-value 2>/dev/null) || model=
    fi
    if [ -z "$model" ]; then
      noroute=${#ask[@]}; ask=()
      echo "ctv: no model route stage.ci-test-value; $noroute row(s) left undecided" >&2
    fi
  fi

  for ((i = 0; i < ${#ask[@]}; i += batch)); do
    part=("${ask[@]:i:batch}")
    if [ "$calls" -ge "$max" ]; then
      for fp in "${part[@]}"; do got[$fp]=$'unknown\tU1.undecided\t'"model call cap $max"; done
      continue
    fi
    # The ledger first: no .attempt for every row, no call.
    wfail=0 pf='' raw=''
    written=()
    for fp in "${part[@]}"; do
      if date -u +%FT%TZ 2>/dev/null > "$cache/$fp.attempt"; then written+=("$fp"); else wfail=1; break; fi
    done
    if [ "$wfail" = 0 ]; then
      pf=$(mktemp "${TMPDIR:-/tmp}/ctv-model-prompt.XXXXXX") && raw=$(mktemp "${TMPDIR:-/tmp}/ctv-model-answer.XXXXXX") || wfail=1
    fi
    if [ "$wfail" = 1 ]; then
      for fp in ${written[@]+"${written[@]}"}; do rm -f "$cache/$fp.attempt"; done
      rm -f ${pf:+"$pf"} ${raw:+"$raw"}
      for fp in "${part[@]}"; do got[$fp]=$'unknown\tU1.undecided\tcache write failed'; done
      continue
    fi
    {
      cat "$prompt"
      printf '\n## Rows\n'
      for fp in "${part[@]}"; do
        IFS=$'\x1f' read -r unit urc ev isb <<<"${meta[$fp]}"
        printf '\nfp: %s\nunit: %s\nrc: %s\nevent: %s\nis_batch: %s\n=== UNTRUSTED INPUT %s ===\n' "$fp" "$unit" "$urc" "$ev" "$isb" "$fp"
        cat "${exf[$fp]}"
        printf '=== END UNTRUSTED INPUT %s ===\n' "$fp"
      done
    } > "$pf"
    k=$(printf '%s\n' "${part[@]}" | LC_ALL=C sort | _ctv_sha)
    calls=$((calls + 1)); asked=$((asked + ${#part[@]}))
    rc=0
    # No tools: a PR author writes the log text in this prompt, so the session
    # must not be able to act on it (bin/agent-call.sh NO-TOOLS CONTRACT). A
    # non-claude rung refuses with rc 78, read below as "not billed".
    AGENT_CALL_NO_TOOLS=1 AGENT_CALL_FP="ci-test-value:$k" AGENT_CALL_BUDGET_USD_CI_TEST_VALUE="$usd" "$root/bin/agent-call.sh" ci-test-value cromford "$model" 300 "$raw" "@$pf" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -ge 74 ] && [ "$rc" -le 79 ]; then
      for fp in "${part[@]}"; do rm -f "$cache/$fp.attempt"; got[$fp]=$'unknown\tU1.undecided\t'"model refused rc=$rc"; done
    elif [ "$rc" != 0 ]; then
      for fp in "${part[@]}"; do got[$fp]=$'unknown\tM1.unparseable\t'"model failed rc=$rc"; done
    else
      kept=()
      # One object per line with string fp, label and why. A fenced line is
      # dropped. why: tab, CR and LF become spaces, 0x1f goes. Only the batch's
      # own fps are read back below, so a foreign fp writes nothing.
      while IFS=$'\t' read -r fp label why; do
        [ -z "${kept[$fp]:-}" ] || continue
        [[ "$_CTV_MODEL_LABELS" == *" $label "* ]] || continue
        read -r -a w <<<"$why"
        kept[$fp]="$label"$'\t'"M1.model"$'\t'"${w[*]:0:20}"
      done < <(jq -R -r 'select(startswith("```") | not) | fromjson?
        | select(type == "object" and (.fp | type) == "string" and (.label | type) == "string" and (.why | type) == "string")
        | select((.fp | test("^[0-9a-f]{64}$")) and (.label | test("^[a-z-]+$")))
        | "\(.fp)\t\(.label)\t\(.why | gsub("[\t\r\n]"; " ") | gsub("\u001f"; ""))"' "$raw" 2>/dev/null)
      for fp in "${part[@]}"; do got[$fp]=${kept[$fp]:-$'unknown\tM1.unparseable\tempty or invalid answer'}; done
    fi
    # A terminal answer is recorded before its .attempt goes.
    for fp in "${part[@]}"; do
      [[ "${got[$fp]}" == *$'\tU1.undecided\t'* ]] && continue
      IFS=$'\t' read -r label rule why <<<"${got[$fp]}"
      _ctv_model_put "$cache/$fp.json" "$label" "$rule" "$why" && rm -f "$cache/$fp.attempt"
    done
    rm -f "$pf" "$raw"
  done

  for ln in "${!row_fp[@]}"; do
    fp=${row_fp[$ln]}
    [ -n "${got[$fp]:-}" ] && res[$ln]=${got[$fp]}
  done
  if [ "${#res[@]}" -gt 0 ]; then
    tmp="$occ.tmp.$$"
    for ln in "${!res[@]}"; do printf '%s\t%s\n' "$ln" "${res[$ln]}"; done \
      | LC_ALL=C awk -F'\t' -v OFS='\t' 'NR == FNR { c[$1] = $2; r[$1] = $3; w[$1] = $4; next }
          (FNR in c) { $11 = c[FNR]; $12 = r[FNR]; $15 = w[FNR] } { print }' - "$occ" > "$tmp" \
      && mv -f "$tmp" "$occ" || { rm -f "$tmp"; echo "ctv: cannot rewrite $occ" >&2; return 1; }
  fi
  for ln in "${!res[@]}"; do
    case "${res[$ln]}" in
      *$'\tM1.model\t'*) labelled=$((labelled + 1)) ;;
      *$'\tM1.unparseable\t'*) unparseable=$((unparseable + 1)) ;;
      *$'\tmodel refused rc='*) refused=$((refused + 1)) ;;
    esac
  done
  echo "ctv: model pass undecided=$undecided cached=$cached asked=$asked calls=$calls labelled=$labelled unparseable=$unparseable refused=$refused" >&2
  return 0
}
