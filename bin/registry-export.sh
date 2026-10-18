#!/bin/bash
# bin/registry-export.sh — BH-5651 (BH-5633.3): fleet.conf and the box maps of
# catalog/cost-accounts.json, rendered FROM the D1 fleet registry. On a box in
# REGISTRY_SOURCE=db these files are an export of the registry, never an input.
#
#   --fleet-conf [--template <file>]
#       Print fleet.conf text. Template comment and blank lines print verbatim,
#       in place. A template project row, `# @standby`, `# @retired` or `# @box`
#       line prints VERBATIM when its whitespace-split tokens equal the
#       registry's (a `# @retired p` with no box equals `-`; a 6th column `-` is
#       no box). A row whose tokens differ prints as the registry's tokens, one
#       space apart. A row the registry no longer has is dropped. Registry rows
#       with no template line are appended in bin/lib/registry.sh _rg_render
#       order (standby, @box, retired, then active by position, project); an
#       appended `# @box` only for a box no active row names. A template
#       `# @boxrole` line prints verbatim, like any comment: it is not refreshed
#       from the registry's roles (db-mode readers read the registry render).
#       With no template the output is _rg_render's minus its GENERATED header
#       line, `# @boxrole` lines included.
#   --cost-accounts --template <file>
#       Print the template JSON with accounts[a].login.box, accounts[a].boxes
#       .cost_rows/.jobs and .box_aliases taken from the registry. An array
#       whose SET is unchanged keeps the template order; an unchanged registry
#       prints the template bytes. An account the registry names and the
#       template lacks is skipped with one registry.log line: the file holds
#       the account metadata, and this never invents an account.
#   --install <harness-root> [--checkout <dir>]
#       env/global.env first (the caller's REGISTRY_SOURCE wins). Not db: rc 1,
#       no write. db: renders both files (template <checkout>/fleet.conf, else
#       the root's own, same for catalog/cost-accounts.json) and replaces
#       <root>/fleet.conf and <root>/catalog/cost-accounts.json, each by mktemp
#       + mv in the same directory and only when the bytes differ. A render
#       with no project row, or whose project set is not the registry's active
#       set, is REFUSED: rc 1, one registry.log line, both files untouched. No
#       usable registry is rc 1: the read ladder already wrote the outage line.
#       Callers: bin/harness-sync.sh (rc 1 = copy the committed fleet.conf, as
#       before) and bin/registry-sync.sh every tick.
#   --snapshot <dir> [--keep N] [--checkout <dir>]
#       The nightly hub lane `registry-export`. Writes <dir>/<YYYYmmddTHHMMSSZ>/
#       {registry.json,import.json,fleet.conf,cost-accounts.json} through a .tmp
#       dir and a rename, points <dir>/latest at it and keeps the newest N
#       (--keep, else REGISTRY_EXPORT_KEEP, else 14; 0 or non-numeric = 14).
#       Only a registry answer FETCHED by this run is snapshotted: a cache
#       served through an outage is rc 1 and latest is kept. import.json is the
#       POST /api/registry/import body that bin/registry-seed.sh --from-export
#       restores. <dir>/.fail-count counts consecutive failures; the third
#       writes ONE line through bin/alert-line.sh, success resets it.
#   --registry <file>   the registry.json to read, instead of the read ladder
#                       (bin/lib/registry.sh registry_json_path).
#
# rc 0 = printed / installed / snapshotted; 1 = nothing written (see above);
# 2 = usage. Logs: <root>/logs/registry.log (install), registry-export.log
# (snapshot). The root is HARNESS (default /root/harness).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
H="${HARNESS:-/root/harness}"
MODE=""; TEMPLATE=""; REG=""; CHECKOUT=""; SNAPDIR=""; KEEP=""
usage() { echo "usage: registry-export.sh --fleet-conf [--template f] | --cost-accounts --template f | --install <root> [--checkout d] | --snapshot <dir> [--keep N] [--checkout d]  [--registry f]" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --fleet-conf) MODE=fleet; shift ;;
    --cost-accounts) MODE=cost; shift ;;
    --install) MODE=install; H="${2:?--install needs a harness root}"; shift 2 ;;
    --snapshot) MODE=snapshot; SNAPDIR="${2:?--snapshot needs a dir}"; shift 2 ;;
    --template) TEMPLATE="${2:?--template needs a file}"; shift 2 ;;
    --registry) REG="${2:?--registry needs a file}"; shift 2 ;;
    --checkout) CHECKOUT="${2:?--checkout needs a dir}"; shift 2 ;;
    --keep) KEEP="${2:?--keep needs a number}"; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$MODE" ] || usage
[ "$MODE" != cost ] || [ -n "$TEMPLATE" ] || usage

# shellcheck source=bin/lib/registry.sh
. "$HERE/lib/registry.sh" || { echo "registry-export: cannot load bin/lib/registry.sh" >&2; exit 1; }
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

# render_fleet <registry.json> [template] — the fleet.conf text on stdout.
render_fleet() {
  local reg="$1" tpl="${2:-}"
  if [ -z "$tpl" ]; then _rg_render "$reg" | tail -n +2; return "${PIPESTATUS[0]}"; fi
  # One fact per line: kind <TAB> key <TAB> append-if-new <TAB> the rendered line.
  jq -r '
    (.boxes | map({key: .box, value: .}) | from_entries) as $b
    | [.projects[] | select((.status // "active") == "active") | .box // empty] as $named
    | (.boxes | sort_by(.box)[] | select(.standby_hub_name != null and .standby_hub_id != null)
        | ["S", .box, "1", "# @standby \(.box) \(.standby_hub_name) \(.standby_hub_id)"]),
      (.boxes | sort_by(.box)[] | select(.tailnet_ip != null) | .box as $x
        | ["B", .box, (if any($named[]; . == $x) then "0" else "1" end), "# @box \(.box) \(.tailnet_ip)"]),
      (.projects | sort_by(.position, .project)[] | select(.status == "retired")
        | ["X", .project, "1", "# @retired \(.project) \(.box // "-")"]),
      (.projects | sort_by(.position, .project)[] | select((.status // "active") == "active")
        | ["P", .project, "1", ([.project, .repo, .prod, .board_prefix, (.cron_offset | tostring)]
            + (if .box == null then [] else [.box] + ([$b[.box].tailnet_ip // empty]) end) | join(" "))])
    | @tsv' "$reg" > "$TMP/facts" || return 1
  awk -v facts="$TMP/facts" '
    BEGIN {
      while ((getline l < facts) > 0) {
        split(l, a, "\t"); k = a[1] SUBSEP a[2]
        if (!(k in line)) { line[k] = a[4]; app[k] = a[3]; order[++n] = k }
      }
    }
    function norm(   t, m, i, s) {
      m = split($0, t)
      if (kind == "X" && m == 3) t[++m] = "-"
      if (kind == "P" && m == 6 && t[6] == "-") m = 5
      s = t[1]; for (i = 2; i <= m; i++) s = s " " t[i]
      return s
    }
    {
      kind = ""
      if ($1 == "#" && $2 == "@standby" && NF >= 5) kind = "S"
      else if ($1 == "#" && $2 == "@retired" && NF >= 3) kind = "X"
      else if ($1 == "#" && $2 == "@box" && NF >= 4) kind = "B"
      else if ($0 ~ /^[[:space:]]*(#|$)/) { print; next }
      else kind = "P"
      k = kind SUBSEP (kind == "P" ? $1 : $3)
      if (!(k in line) || (k in seen)) next
      seen[k] = 1
      if (norm() == line[k]) print; else print line[k]
    }
    END { for (i = 1; i <= n; i++) if (!(order[i] in seen) && app[order[i]] == "1") print line[order[i]] }
  ' "$tpl"
}

# render_cost <registry.json> <template> — the cost-accounts JSON on stdout.
render_cost() {
  local reg="$1" tpl="$2" a
  jq --slurpfile r "$reg" '
    ($r[0].box_accounts) as $ba
    | def regset($a; $k): [$ba[] | select(.account == $a and .kind == $k) | .box] | unique;
      def keep($old; $new): if (($old // []) | unique) == $new then $old else $new end;
    .accounts |= ((. // {}) | with_entries(.key as $a | .value |= (
        regset($a; "login") as $lg
        | (.login.box? // "") as $cur
        | (if ($lg | length) == 0 then (if .login.box? != null then del(.login.box) else . end)
           elif any($lg[]; . == $cur) then .
           else .login.box = $lg[0] end)
        | reduce ("cost_rows", "jobs") as $k (.;
            regset($a; $k) as $s
            | if (.boxes[$k]? == null and ($s | length) == 0) then . else .boxes[$k] = keep(.boxes[$k]; $s) end))))
    | ([$r[0].boxes[] | select(.cost_box != null) | {key: .box, value: .cost_box}] | from_entries) as $al
    | if ((.box_aliases // {}) | to_entries | sort_by(.key)) == ($al | to_entries | sort_by(.key)) then .
      else .box_aliases = (((.box_aliases // {}) | with_entries(select($al[.key] != null) | .value = $al[.key])) + $al) end
  ' "$tpl" > "$TMP/cost.json" || return 1
  for a in $(comm -23 <(jq -r '[.box_accounts[].account] | unique[]' "$reg") <(jq -r '(.accounts // {}) | keys[]' "$tpl" | sort -u)); do
    _rg_log "$H" "registry-export: account $a is in the registry but not in $tpl; its box maps are not exported (the file holds the account metadata)"
  done
  if [ "$(jq -S . "$TMP/cost.json")" = "$(jq -S . "$tpl")" ]; then cat "$tpl"; else cat "$TMP/cost.json"; fi
}

# put_if_changed <src> <dest> — mktemp + mv in dest's directory, only on a byte change.
put_if_changed() {
  local tmp
  cmp -s "$1" "$2" && return 0
  mkdir -p "$(dirname "$2")" || return 1
  tmp=$(mktemp "$(dirname "$2")/.$(basename "$2").XXXXXX") || return 1
  cat "$1" > "$tmp" && mv -f "$tmp" "$2" || { rm -f "$tmp"; return 1; }
}

active_set() { jq -r '.projects[] | select((.status // "active") == "active") | .project' "$1" | sort; }
conf_set() { awk '!/^[[:space:]]*(#|$)/ {print $1}' "$1" | sort; }
first_file() { local f; for f in "$@"; do [ -n "$f" ] && [ -f "$f" ] && { printf '%s\n' "$f"; return 0; }; done; return 1; }

# usable_registry — sets REG to a valid registry.json, else rc 1.
usable_registry() {
  if [ -z "$REG" ]; then REG=$(HARNESS="$H" registry_json_path 2>/dev/null) || return 1; fi
  registry_valid "$REG"
}

load_env() {
  local rs="${REGISTRY_SOURCE-}" henv
  # shellcheck source=bin/lib/env-path.sh
  . "$HERE/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "$1/env"; }
  henv=$(harness_env_dir "$H")
  set -a; . "$henv/global.env" 2>/dev/null; set +a
  [ -z "$rs" ] || REGISTRY_SOURCE="$rs"
}

case "$MODE" in
  fleet)
    usable_registry || exit 1
    render_fleet "$REG" "$TEMPLATE" > "$TMP/out" || exit 1
    [ -n "$(conf_set "$TMP/out")" ] || exit 1
    cat "$TMP/out"
    ;;
  cost)
    usable_registry || exit 1
    render_cost "$REG" "$TEMPLATE"
    ;;
  install)
    load_env
    [ "${REGISTRY_SOURCE:-file}" = db ] || exit 1
    usable_registry || exit 1
    FT=$(first_file "${CHECKOUT:+$CHECKOUT/fleet.conf}" "$H/fleet.conf")
    if [ -n "$FT" ]; then cp "$FT" "$TMP/fleet.tpl"; FT="$TMP/fleet.tpl"; fi
    render_fleet "$REG" "$FT" > "$TMP/fleet.conf" || { _rg_log "$H" "registry-export --install: the fleet.conf render failed; $H/fleet.conf kept"; exit 1; }
    if [ -z "$(conf_set "$TMP/fleet.conf")" ] || [ "$(conf_set "$TMP/fleet.conf")" != "$(active_set "$REG")" ]; then
      _rg_log "$H" "registry-export --install: REFUSED a fleet.conf render whose project set is not the registry's active set ($(conf_set "$TMP/fleet.conf" | wc -l) rows, registry $(active_set "$REG" | wc -l)); $H/fleet.conf and catalog/cost-accounts.json kept"
      exit 1
    fi
    CT=$(first_file "${CHECKOUT:+$CHECKOUT/catalog/cost-accounts.json}" "$H/catalog/cost-accounts.json")
    if [ -n "$CT" ]; then
      cp "$CT" "$TMP/cost.tpl"
      render_cost "$REG" "$TMP/cost.tpl" > "$TMP/cost-accounts.json" \
        || { _rg_log "$H" "registry-export --install: the cost-accounts render failed; both files kept"; exit 1; }
    fi
    put_if_changed "$TMP/fleet.conf" "$H/fleet.conf" || { _rg_log "$H" "registry-export --install: cannot write $H/fleet.conf"; exit 1; }
    if [ -n "$CT" ]; then
      put_if_changed "$TMP/cost-accounts.json" "$H/catalog/cost-accounts.json" \
        || { _rg_log "$H" "registry-export --install: cannot write $H/catalog/cost-accounts.json"; exit 1; }
    fi
    exit 0
    ;;
  snapshot)
    load_env
    [ ! -e "$H/flags/lane-off-registry-export" ] || exit 0
    # >>> lane gate (BH-1165) — flags/all-off or flags/lane-off-registry-export
    # exits 0 here; lane_env_apply puts this lane's settings rows
    # (REGISTRY_EXPORT_KEEP) into the environment. Both fail OPEN.
    # shellcheck disable=SC1091
    . "$H/bin/lib/lane-gate.sh" 2>/dev/null || true
    command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit registry-export
    command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    registry-export
    export HARNESS="$H"
    LOG="$H/logs/registry-export.log"
    mkdir -p "$H/logs" "$SNAPDIR" 2>/dev/null
    log() { echo "$(STAMP) $*" >> "$LOG" 2>/dev/null; return 0; }
    KEEP="${KEEP:-${REGISTRY_EXPORT_KEEP:-14}}"
    case "$KEEP" in ''|*[!0-9]*|0) KEEP=14 ;; esac
    fail() {
      local n
      n=$(cat "$SNAPDIR/.fail-count" 2>/dev/null); case "$n" in ''|*[!0-9]*) n=0 ;; esac
      n=$((n + 1)); printf '%s\n' "$n" > "$SNAPDIR/.fail-count"
      log "FAILED ($n in a row): $*; $SNAPDIR/latest kept"
      if [ "$n" = 3 ]; then
        HARNESS="$H" "$HERE/alert-line.sh" "registry-export: the nightly registry snapshot failed 3 runs in a row ($*). The newest good snapshot is $(readlink "$SNAPDIR/latest" 2>/dev/null || echo none). Check harness-jobs GET /api/registry and $LOG."
      fi
      exit 1
    }
    if [ -z "$REG" ]; then
      REG=$(registry_json_fetched 2>/dev/null) || fail "no registry answer fetched in this run (a cache served through an outage is not snapshotted)"
    fi
    registry_valid "$REG" || fail "the registry answer is not usable"
    NAME=$(date -u -d "@${REGISTRY_EXPORT_NOW:-$(date +%s)}" +%Y%m%dT%H%M%SZ)
    [ ! -e "$SNAPDIR/$NAME" ] || fail "$SNAPDIR/$NAME already exists"
    W="$SNAPDIR/.tmp.$NAME"
    rm -rf "$W"; mkdir -p "$W" || fail "cannot create $W"
    cp "$REG" "$W/registry.json" || fail "cannot copy registry.json"
    jq '{actor: "registry-restore",
         projects: [.projects[] | {project, repo, prod, board_prefix, cron_offset, box, position, status}],
         boxes: [.boxes[] | {box, box_id, tailnet_ip, cost_box, standby_hub_name, standby_hub_id, role}],
         lane_boxes: [.lane_boxes[] | {lane, box_id}],
         box_accounts: [.box_accounts[] | {account, kind, box}]}' "$REG" > "$W/import.json" || fail "cannot write import.json"
    CO="${CHECKOUT:-/root/harness-checkout}"
    FT=$(first_file "$CO/fleet.conf" "$H/fleet.conf")
    render_fleet "$REG" "$FT" > "$W/fleet.conf" && [ -n "$(conf_set "$W/fleet.conf")" ] || fail "the fleet.conf render failed"
    CT=$(first_file "$CO/catalog/cost-accounts.json" "$H/catalog/cost-accounts.json")
    if [ -n "$CT" ]; then
      render_cost "$REG" "$CT" > "$W/cost-accounts.json" || fail "the cost-accounts render failed"
    else
      log "no catalog/cost-accounts.json template under $CO or $H; the snapshot has no cost-accounts.json"
    fi
    mv "$W" "$SNAPDIR/$NAME" || fail "cannot rename $W"
    ln -sfn "$NAME" "$SNAPDIR/.latest.new" && mv -Tf "$SNAPDIR/.latest.new" "$SNAPDIR/latest" || fail "cannot point latest at $NAME"
    # shellcheck disable=SC2012
    ls -1 "$SNAPDIR" | grep -E '^[0-9]{8}T[0-9]{6}Z$' | sort -r | tail -n +$((KEEP + 1)) | while read -r OLD; do rm -rf "${SNAPDIR:?}/$OLD"; done
    rm -f "$SNAPDIR/.fail-count"
    log "snapshot $NAME written (registry v$(jq -r .version "$REG"), $(conf_set "$SNAPDIR/$NAME/fleet.conf" | wc -l) projects, keep $KEEP)"
    exit 0
    ;;
esac
