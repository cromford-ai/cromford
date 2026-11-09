#!/bin/bash
# bin/transcript-cost.sh <session-id|/path/to/session.jsonl> [options]
#
# What a claude run ACTUALLY cost, summed from its own session transcript and
# priced from catalog/model-prices.json. Prints one '|'-separated line:
#
#   input|output|cache_read|cache_write|usd|model|messages|files|unpriced
#
#   model     the model that produced the most output tokens (cost.csv has one
#             model column; --format json carries the full per-model split)
#   messages  API responses counted, AFTER de-duplication (see below)
#   files     transcript files summed (the session plus any sidechain file)
#   unpriced  models with no row in the price table, ";"-joined, empty when all
#             priced. usd is then a PARTIAL number and says so rather than
#             quietly reading low.
#
# Exit: 0 priced; 3 no transcript for this session (reason on stderr);
#       4 transcript exists but carries no usage (a run killed before its first
#         API response — still a real answer, and the caller writes a row);
#         with --advisor, the transcript has no advisor iterations.
#
# ── THE BUG THIS FILE EXISTS TO NOT HAVE ────────────────────────────────────
# Claude Code writes ONE JSONL ENTRY PER CONTENT BLOCK of an API response, and
# every one of them repeats the SAME usage object. Measured on a real hub
# session (4c9ab765, 2026-09-14): 65 usage-carrying entries for 40 API
# responses; one response was written three times (text + two tool_use blocks),
# each line claiming in=2 out=343 cache_read=10010 cache_write=22555. Summing
# lines gives 5,378,875 cache_read where the session really read 2,400,809 —
# 2.24x high.
#
# So the sum is keyed on the API response, not the line: message.id first (the
# server's own id for the response), requestId, then the entry uuid. Both the
# reference pricer (/tmp/jsum.py) and bin/claude-usage.sh sum lines, which is
# why the "transcript says 3-4x more than cost.csv" measurement that started
# this wave is itself about 2x hot. cost.csv still undercounts — the CLI's
# .usage envelope reports one turn, not the session — but by less than that.
#
# ── CACHE WRITES ARE PRICED PER TTL, NOT BY A GUESS ─────────────────────────
# usage.cache_creation splits the write into ephemeral_5m_input_tokens and
# ephemeral_1h_input_tokens, per message, so the TTL is READ rather than
# detected: a session that used both pays both rates. catalog/model-prices.json
# carries the 5-minute rate (it is 1.25x the prompt rate on every anthropic row
# in the file); the 1-hour rate is 2x the prompt rate, derived rather than
# stored so a catalog refresh cannot leave the two halves disagreeing.
# COST_CACHE_TTL=5m|1h forces one rate for messages that carry NO split (older
# transcripts); default `auto` = read the split, fall back to 5m.
#
# ── SUBAGENTS ───────────────────────────────────────────────────────────────
# A Task/Agent subagent's turns land in the SAME session file with
# isSidechain:true, so they are summed by construction. Some CLI versions write
# a companion file instead; `<session>*.jsonl` in the same project directory is
# summed too, and a file whose entries name this session as their parent is
# picked up by the (bounded, off-by-default-able) sibling scan. --no-subagents
# turns both off.
#
# Options:
#   --cwd <dir>          the directory the session ran in (narrows the search to
#                        Claude Code's own slug for it: every "/" becomes "-")
#   --config-dir <dir>   CLAUDE_CONFIG_DIR (default: $CLAUDE_CONFIG_DIR, ~/.claude)
#   --since <epoch>      count only entries at/after this time. For `claude -c`,
#                        where the session file already holds earlier turns and
#                        summing it whole would bill this turn for the history.
#   --prices <file>      price table (default: the repo catalog, then $HARNESS's)
#   --no-subagents       primary session file only
#   --format line|json   json prints the per-model breakdown
#   --price-version      (BH-5652) append a 10th field: the `version` of the
#                        price row the row's model (field 6) was priced from,
#                        empty when that row has none (the committed catalog)
#                        or the model is unpriced. Opt-in, so every 9-field
#                        reader keeps its exact line.
#   --peak               (BH-9124) append one more field, LAST: `peak`, the
#                        largest context of ONE API response in the sum
#                        (input + cache_read + cache_write of that response).
#                        It is field 10, or field 11 after --price-version.
#                        Opt-in for the same reason: cost-live's `unp` and the
#                        --price-version readers name the last field, and an
#                        extra field would land in it. The context meter's
#                        declared kill (bin/agent-call.sh) reads it.
#   --advisor            price the ADVISOR instead (BH-3491): only the
#                        usage.iterations[] entries of type advisor_message, each
#                        at its own model, deduped on the response like the
#                        default sum. The top-level usage is executor-only and is
#                        not counted in this mode. Exit 4 = no advisor iterations.
set -uo pipefail

SESSION=""; CWD=""; CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"; SINCE=""
PRICES=""; FORMAT=line; SUBAGENTS=1; ADVISOR=0; PRICEV=0; PEAK=0
while [ $# -gt 0 ]; do
  case "$1" in
    --cwd)         CWD="${2:-}"; shift 2 ;;
    --cwd=*)       CWD="${1#--cwd=}"; shift ;;
    --config-dir)  CFG="${2:-}"; shift 2 ;;
    --config-dir=*) CFG="${1#--config-dir=}"; shift ;;
    --since)       SINCE="${2:-}"; shift 2 ;;
    --since=*)     SINCE="${1#--since=}"; shift ;;
    --prices)      PRICES="${2:-}"; shift 2 ;;
    --prices=*)    PRICES="${1#--prices=}"; shift ;;
    --format)      FORMAT="${2:-line}"; shift 2 ;;
    --format=*)    FORMAT="${1#--format=}"; shift ;;
    --no-subagents) SUBAGENTS=0; shift ;;
    --advisor)     ADVISOR=1; shift ;;
    --price-version) PRICEV=1; shift ;;
    --peak)        PEAK=1; shift ;;
    -h|--help)     sed -n '2,83p' "$0"; exit 0 ;;
    *)             [ -z "$SESSION" ] && SESSION="$1"; shift ;;
  esac
done
[ -n "$SESSION" ] || { echo "transcript-cost: usage: transcript-cost.sh <session-id|file.jsonl> [--cwd D] [--since EPOCH]" >&2; exit 2; }

# Price table. The daily refresh's live table first where it exists (BH-628:
# $HARNESS/state/model-prices.json, written by bin/update-model-prices.sh on the
# hub), then the repo checkout (hub and boxes run from it), then
# $HARNESS/catalog — fly builders have no checkout and receive catalog/ in the
# sync tarball, and pricing the busiest machines in the fleet off a table that
# is not there is the TK-109 hole one file over. state/ is not propagated, so a
# machine without it resolves exactly the path it always did.
if [ -z "$PRICES" ]; then
  for c in "${MODEL_PRICES:-}" "${HARNESS:-/root/harness}/state/model-prices.json" \
           "$(dirname "$0")/../catalog/model-prices.json" \
           /root/harness-checkout/catalog/model-prices.json \
           "${HARNESS:-/root/harness}/catalog/model-prices.json"; do
    [ -n "$c" ] && [ -r "$c" ] && { PRICES="$c"; break; }
  done
fi

# BH-1939: COST_TRANSCRIPT_SCAN_MAX and COST_CACHE_TTL have no literal here.
# They resolve through lib_env_apply transcript-cost
# (catalog/lanes.d/_lib.transcript-cost.json), in a subshell, the way
# bin/lib/gh-budget.sh does: a fail-closed `exit 75` never ends this cost read,
# and an empty value is left to the python reader below.
_TC_KV=$(
  exec 3>&1
  _TC_R=$(cd "$(dirname "$0")/.." 2>/dev/null && pwd) || exit 0
  # The entry point owns the root default (BH-2613 rule 4): the libs below have none.
  H="${HARNESS:-${H:-/root/harness}}"
  command -v lib_env_apply >/dev/null 2>&1 || . "$_TC_R/bin/lib/lane-gate.sh" >/dev/null 2>&1 || exit 0
  if [ -z "${LANE_REGISTRY:-}" ] && [ ! -r "$(_lg_registry)" ] && . "$_TC_R/bin/lib/lanes-registry.sh" >/dev/null 2>&1; then
    LANE_REGISTRY=$(lanes_json_path "$_TC_R" 2>/dev/null) && export LANE_REGISTRY
  fi
  trap 'for _TC_K in COST_TRANSCRIPT_SCAN_MAX COST_CACHE_TTL; do printf "%s\t%s\n" "$_TC_K" "${!_TC_K:-}" >&3; done' EXIT
  lib_env_apply transcript-cost >/dev/null 2>&1)
while IFS=$'\t' read -r _TC_K _TC_V; do
  if [ -n "$_TC_V" ]; then printf -v "$_TC_K" '%s' "$_TC_V"; fi
done <<<"$_TC_KV"
unset _TC_KV _TC_K _TC_V
MAXSCAN="${COST_TRANSCRIPT_SCAN_MAX:-}"
OUT=$(SESSION="$SESSION" CWD="$CWD" CFG="$CFG" SINCE="$SINCE" PRICES="$PRICES" \
      FORMAT="$FORMAT" SUBAGENTS="$SUBAGENTS" MAXSCAN="$MAXSCAN" ADVISOR="$ADVISOR" PRICEV="$PRICEV" PEAK="$PEAK" \
      CACHE_TTL="${COST_CACHE_TTL:-}" python3 - <<'PYEOF'
import glob, json, os, sys

SESSION = os.environ["SESSION"]
CWD     = os.environ.get("CWD") or ""
CFG     = os.environ.get("CFG") or os.path.expanduser("~/.claude")
SINCE   = os.environ.get("SINCE") or ""
PRICES  = os.environ.get("PRICES") or ""
FORMAT  = os.environ.get("FORMAT") or "line"
SUBAG   = os.environ.get("SUBAGENTS") != "0"
MAXSCAN = int(os.environ.get("MAXSCAN") or 400)
TTL     = (os.environ.get("CACHE_TTL") or "auto").lower()
ADVISOR = os.environ.get("ADVISOR") == "1"

try:
    since = float(SINCE) if SINCE else 0.0
except ValueError:
    since = 0.0


def slug(path):
    """Claude Code's own project-directory rule: every '/' becomes '-'."""
    return path.replace("/", "-")


def find_files():
    """The transcript(s) for this session, primary first.

    A PATH is taken as given — claude-cost.sh discovers the file itself when it
    could not choose the session id (a `-c` continuation), and asking it to
    reverse-engineer a session id out of a filename would be one more place to
    be wrong.
    """
    if SESSION.endswith(".jsonl"):
        return ([SESSION], os.path.dirname(SESSION)) if os.path.exists(SESSION) else ([], "")

    roots = []
    if CWD:
        roots.append(os.path.join(CFG, "projects", slug(os.path.abspath(CWD))))
    # Every project dir, because a session's cwd is not always the caller's: the
    # CLI keys the directory on ITS working directory, and a wrapper that ran
    # `cd` first would otherwise look in the wrong place and report "no
    # transcript" for a session that is right there.
    roots.extend(sorted(glob.glob(os.path.join(CFG, "projects", "*"))))

    primary, extra, seen_dir = [], [], ""
    for root in roots:
        p = os.path.join(root, SESSION + ".jsonl")
        if os.path.exists(p):
            primary = [p]
            seen_dir = root
            break
    if not primary:
        return [], ""
    if SUBAG:
        # Companion files the CLI may write for subagent lanes, e.g.
        # <session>-agent-<n>.jsonl. Cheap: one glob, no read.
        for p in sorted(glob.glob(os.path.join(seen_dir, SESSION + "*.jsonl"))):
            if p not in primary:
                extra.append(p)
        # A sibling that NAMES this session as its parent. Bounded: a project
        # directory with more files than MAXSCAN is not scanned at all rather
        # than scanned partly, because a partial scan undercounts silently and
        # undercounting is the failure this whole file exists to end.
        sibs = [p for p in sorted(glob.glob(os.path.join(seen_dir, "*.jsonl")))
                if p not in primary and p not in extra]
        if len(sibs) <= MAXSCAN:
            needle = '"parentSessionId":"%s"' % SESSION
            for p in sibs:
                try:
                    with open(p, errors="ignore") as fh:
                        for line in fh:
                            if needle in line.replace(" ", ""):
                                extra.append(p)
                                break
                except OSError:
                    continue
    return primary + extra, seen_dir


files, _root = find_files()
if not files:
    sys.stderr.write(
        "transcript-cost: no transcript for session %r under %s/projects"
        "%s — the run may have died before the CLI wrote one, or it ran under a "
        "different CLAUDE_CONFIG_DIR.\n" % (SESSION, CFG, (" (cwd %s)" % CWD) if CWD else ""))
    sys.exit(3)

# ── price table ─────────────────────────────────────────────────────────────
per_token = {}
if PRICES:
    try:
        per_token = json.load(open(PRICES)).get("per_token") or {}
    except Exception:
        per_token = {}


def price_for(model):
    """The row for a model id, or None. NO GUESS: an unknown model is reported
    as unpriced, never funded from a neighbour's rate — guessing high cries
    about healthy runs and guessing low hides the overspend this exists to
    catch."""
    if not model:
        return None
    cands = [model, model.lower(), "anthropic/" + model, model.replace(".", "-"),
             model.replace("-", ".")]
    # A dated release (a family name plus a -YYYYMMDD suffix) prices as its family.
    parts = model.rsplit("-", 1)
    if len(parts) == 2 and parts[1].isdigit() and len(parts[1]) == 8:
        cands += [parts[0], "anthropic/" + parts[0]]
    for c in cands:
        if c in per_token:
            return per_token[c]
    return None


def entry_epoch(o):
    ts = o.get("timestamp")
    if not ts:
        return None
    try:
        import datetime
        d = datetime.datetime.fromisoformat(str(ts).replace("Z", "+00:00"))
        if d.tzinfo is None:
            d = d.replace(tzinfo=datetime.timezone.utc)
        return d.timestamp()
    except ValueError:
        return None


def add_usage(agg, model, u):
    """Add one usage object to agg[model] = [in, out, cache_read, cw_5m, cw_1h, msgs]."""
    a = agg.setdefault(model, [0, 0, 0, 0, 0, 0])
    a[0] += int(u.get("input_tokens") or 0)
    a[1] += int(u.get("output_tokens") or 0)
    a[2] += int(u.get("cache_read_input_tokens") or 0)
    cw = int(u.get("cache_creation_input_tokens") or 0)
    cc = u.get("cache_creation")
    if isinstance(cc, dict) and (cc.get("ephemeral_5m_input_tokens") is not None
                                 or cc.get("ephemeral_1h_input_tokens") is not None):
        w5 = int(cc.get("ephemeral_5m_input_tokens") or 0)
        w1 = int(cc.get("ephemeral_1h_input_tokens") or 0)
        # The split is authoritative, but a message whose split does not
        # add up to the total keeps the remainder rather than losing it.
        rest = cw - w5 - w1
        if rest > 0:
            if TTL == "1h":
                w1 += rest
            else:
                w5 += rest
    elif TTL == "1h":
        w5, w1 = 0, cw
    else:
        w5, w1 = cw, 0
    a[3] += w5
    a[4] += w1
    a[5] += 1


# ── the sum ─────────────────────────────────────────────────────────────────
# Keyed on the API RESPONSE. See the header: one response is written as one
# entry per content block and every entry repeats the same usage.
seen = set()
agg = {}          # model -> [in, out, cache_read, cw_5m, cw_1h, msgs]
msgs = 0
peak = 0          # BH-9124: the largest context of one response (--peak)
for fp in files:
    try:
        fh = open(fp, errors="ignore")
    except OSError:
        continue
    with fh:
        for line in fh:
            if '"usage"' not in line:
                continue
            try:
                o = json.loads(line)
            except Exception:
                continue
            m = o.get("message")
            if not isinstance(m, dict):
                continue
            u = m.get("usage")
            if not isinstance(u, dict):
                continue
            if since:
                ep = entry_epoch(o)
                # An entry with no readable timestamp is COUNTED: dropping it
                # undercounts, and undercounting is the failure mode here.
                if ep is not None and ep < since:
                    continue
            key = m.get("id") or o.get("requestId") or o.get("uuid")
            if key is None or key in seen:
                continue
            seen.add(key)
            # One response's context: what it read plus what it wrote to cache.
            # Read off the top-level usage, so one response counts once.
            try:
                one = (int(u.get("input_tokens") or 0) + int(u.get("cache_read_input_tokens") or 0)
                       + int(u.get("cache_creation_input_tokens") or 0))
            except (TypeError, ValueError):
                one = 0
            peak = max(peak, one)
            if ADVISOR:
                # The advisor's sub-inferences, each at its own model. One
                # response counts once however many lines repeat it (above).
                parts = [(it.get("model") or "unknown", it) for it in (u.get("iterations") or [])
                         if isinstance(it, dict) and it.get("type") == "advisor_message"]
            else:
                parts = [(m.get("model") or "unknown", u)]
            for model, pu in parts:
                add_usage(agg, model, pu)
            msgs += 1 if parts else 0

if not agg:
    if ADVISOR:
        sys.stderr.write("transcript-cost: %s has no advisor iterations — the advisor "
                         "was not consulted in this session.\n" % files[0])
        sys.exit(4)
    sys.stderr.write(
        "transcript-cost: %s carries no usage — the run produced no API response "
        "(killed or refused before its first turn).\n" % files[0])
    sys.exit(4)

tot_i = tot_o = tot_cr = tot_cw = 0
usd = 0.0
unpriced = []
models = {}
for model, a in sorted(agg.items()):
    tot_i += a[0]; tot_o += a[1]; tot_cr += a[2]; tot_cw += a[3] + a[4]
    p = price_for(model)
    if p is None:
        unpriced.append(model)
        c = 0.0
    else:
        g = lambda k: float(p.get(k) or 0)      # the table is PER TOKEN
        # 1h cache writes cost 2x the prompt rate; the table's cache_write is
        # the 5-minute (1.25x) rate. Derived from `prompt` so a catalog refresh
        # cannot leave the two halves disagreeing; where a row has no prompt
        # rate the 5m rate is scaled by the same 2/1.25 ratio instead.
        r5 = g("cache_write")
        # An explicit `cache_write_1h` in the row wins (P1) — the same order
        # bin/lib/cost-row.sh's cost_price_tokens and cost-rollup's row_cost
        # apply, so the three pricers give one answer for one row.
        r1 = (g("cache_write_1h") or (g("prompt") * 2.0 if g("prompt") else r5 * 1.6))
        c = (a[0] * g("prompt") + a[1] * g("completion") + a[2] * g("cache_read")
             + a[3] * r5 + a[4] * r1)
        usd += c
    models[model] = {"input": a[0], "output": a[1], "cache_read": a[2],
                     "cache_write_5m": a[3], "cache_write_1h": a[4],
                     "messages": a[5], "usd": round(c, 6), "priced": p is not None}

top = max(agg.items(), key=lambda kv: (kv[1][1], kv[1][5]))[0]

if FORMAT == "json":
    json.dump({"session": SESSION, "files": files, "messages": msgs,
               "input": tot_i, "output": tot_o, "cache_read": tot_cr,
               "cache_write": tot_cw, "usd": round(usd, 6), "model": top,
               "models": models, "unpriced": unpriced,
               "prices": PRICES, "cache_ttl": TTL}, sys.stdout)
    print()
else:
    line = ("%d|%d|%d|%d|%.6f|%s|%d|%d|%s"
            % (tot_i, tot_o, tot_cr, tot_cw, usd, top, msgs, len(files),
               ";".join(unpriced)))
    if os.environ.get("PRICEV") == "1":
        # BH-5652: the version of the SAME row price_for() priced the top model
        # from, so the row's dollars and its version come from one table read.
        # Only a positive integer is a version; anything else is an empty field.
        v = (price_for(top) or {}).get("version")
        ok = isinstance(v, int) and not isinstance(v, bool) and v > 0
        line += "|" + (str(v) if ok else "")
    if os.environ.get("PEAK") == "1":
        line += "|%d" % peak
    print(line)
PYEOF
)
RC=$?
[ -n "$OUT" ] && printf '%s\n' "$OUT"
exit $RC
