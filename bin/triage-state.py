#!/usr/bin/env python3
"""bin/triage-state.py — the deterministic half of the per-ticket triage-state
gate (TRIAGE-STATE, docs/TRIAGE-STATE.md). No network, no clock of its own
(`--now` is passed in), no model. bin/lib/triage-state.sh is the only caller.

  entries --world W [--prefix P] [--keymap M]
      One TSV line per ticket on the board fingerprint W (state/<p>.gate.pending
      or gate.json): key, label, entry_sha, open (1|0), seed (waiting_client|-).
      key is the tick's canonical unit key (the issue NUMBER on a GitHub-Issues
      board, the board ticket id in-app). entry_sha moves whenever the gate's own
      row for the ticket moves, and is what the thread cache is keyed on.

  hash --world W --key K [--prefix P]
      stdin: the wrapper `bin/triage-gate.sh <p> --thread <id>` prints
      ({kind, self_actors, self_apps, self_identities, doc}). stdout: one JSON
      object {input_hash, last_update_at, absent_refs}. `--batch F` hashes
      many (key<TAB>raw-file lines -> key, hash, last_update_at, absent refs);
      `--refs R` is the caller's REST-looked-up state of refs the board
      fingerprint cannot place (refs.json). THE INPUT HASH is sha256 over:
        sig    bin/triage-signal.py's own inapp()/gh() document, imported, not
               re-implemented: title, body, state/status, priority, attachments by
               identity, and every comment NOT written by us as (id, author,
               body). Our own triage comments never move it.
        labels every label minus TRIAGE_STATE_SELF_LABELS (the ones we write).
        deps   GitHub: every #N / <PREFIX>-N the title, body or a non-self
               comment names, resolved against W: the issue's state, `pr-open`
               for an open PR, else the --refs state (OPEN/CLOSED/MERGED/MISSING,
               looked up by REST), else `absent` (so a merged PR, which leaves
               the open list, moves it). In-app: blocked, parentId and dependsOn with
               the status W carries for each, plus keys the thread names.
        reason every #N / KEY-N the stored row's `reason` names (--rows R, the
               triage_state rows), resolved the same way. The hash is composed:
               base = the thread-only hash above; input_hash = base when the
               reason names no ref, else sha256({v:2, base, reason_deps}).
               Batch output adds columns 5-6: base, reason deps (JSON | -).
               `--merged-refs M` (in-app only, BH-3829): a JSON object
               {KEY: [pr, merged_at_epoch]} built by bin/lib/triage-state.sh
               from bin/lib/gate-release.sh's gr_key_merged. A REASON ref KEY
               whose merged_at is later than the row's triaged_at resolves to
               "<status>|merged", so the hash moves once when the thing a
               verdict waited on merges. `record` never reads the map, so the
               re-triage stamps the unsuffixed state and the hash settles. No
               map, an empty one or an unreadable file: byte-identical.
      Timestamps, comment counts, waitingOn/triageVerdict/turn: out.
      rc 1, nothing printed: a shape it cannot read. The caller then sends the
      ticket to the model — an unread thread is never "unchanged".

  record --project P --out OUT --rc RC --now EPOCH --ttl S [--decisions D | --key K --hash H]
         [--rows R --hnd-backoff S --nudge S]
      The session's verdicts as triage_state rows (JSON {project, rows}), from
      its DECISION lines, each stamped with the hash the pre-check computed
      BEFORE the session. A model-set ticket an rc-0 session left no evidence
      for gets a `handed-no-decision` reason and a backoff, never a verdict
      (BH-3920). See cmd_record.

  decide --hashes H --rows R --now EPOCH --ttl S [--defer-ttl S2 --nudge S3 --decisions D --prefix P --keymap M]
      H: TSV key, label, hash|-, last_update_at|-, open, seed, base, reason_deps (every entry;
      a CLOSED ticket whose row holds a verdict that is not `closed` is
      `llm closed`, once). R: the
      triage_state rows (a JSON array). D: logs/decisions.log. One TSV line per
      open ticket: key, label, decision, reason, input_hash, seed_json, base,
      note (`restamp`: a legacy row re-stamped in place, see cmd_decide).
      decision is llm | skip | candidate (a `buildable` verdict whose inputs did
      not move: the shell decides enqueue vs owned). seed_json is `-` or the
      row a seed would write (a decisions.log verdict newer than the ticket's
      last update of ANY kind, or in-app waitingOn=client).
      --deferred F (BH-3921): the keys whose thread was NOT read this tick
      though their board row moved (past the fetch cap, a low GitHub budget).
      Each is `skip deferred:cap`, or `skip deferred:budget` under
      --deferred-why budget, with or without a cached thread: carried to the
      next tick, never sent to the model unread. Column 5 is the hash of the
      stale cached thread when there is one, else `-`. The legacy re-stamp
      never runs for it. A CLOSED key is still `stamp closed-on-board`.
      THE TIMER (due_at): --ttl 0 means a verdict with unchanged inputs is
      never re-offered on a timer, except a defer-like verdict naming no ref
      (--defer-ttl) and a client-turn verdict (--nudge, 0 = off). --ttl > 0 is
      the per-ticket sweep: every verdict is due at its next_recheck_at.
      A key whose row carries a `handed-no-decision <marker>` reason equal to
      this tick's hash, inside its backoff, is `skip handed-no-decision`.
"""
import argparse
import hashlib
import importlib.util
import json
import os
import re
import sys
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
CLOSED_STATUSES = {"done", "closed", "cancelled", "canceled", "archived", "rejected", "resolved", "completed", "wontfix"}
DEFAULT_SELF_LABELS = "ai-build,dequeued,stale-conflict,broke"


def fail():
    sys.exit(1)


def canon(obj):
    return json.dumps(obj, sort_keys=True, separators=(",", ":"))


def sha(obj):
    return hashlib.sha256(canon(obj).encode()).hexdigest()


def load_world(path):
    try:
        with open(path) as f:
            w = json.load(f)
    except (OSError, ValueError):
        fail()
    if not isinstance(w, dict):
        fail()
    return w


def load_keymap(path):
    if not path:
        return {}
    try:
        with open(path) as f:
            m = json.load(f)
        return m if isinstance(m, dict) else {}
    except (OSError, ValueError):
        return {}


def is_gh(w):
    return isinstance(w.get("issues"), list)


def inapp_tickets(w):
    for bid, rows in sorted(w.items()):
        if bid == "meta" or not isinstance(rows, list):
            continue
        for t in rows:
            if isinstance(t, dict) and t.get("id") is not None:
                yield t


# ── entries ──────────────────────────────────────────────────────────────────
def cmd_entries(a):
    w = load_world(a.world)
    km = load_keymap(a.keymap)
    out = []
    if is_gh(w):
        meta = w.get("meta") if isinstance(w.get("meta"), dict) else {}
        for i in w["issues"]:
            if not isinstance(i, dict) or i.get("number") is None:
                continue
            n = str(i["number"])
            label = f"{a.prefix}-{n}" if a.prefix else n
            op = "1" if str(i.get("state", "")).upper() == "OPEN" else "0"
            out.append((n, label, sha([i, meta.get(n)])[:16], op, "-"))
    else:
        for t in inapp_tickets(w):
            k = str(t["id"])
            label = str(t.get("key") or km.get(k) or k)
            # the label becomes a lock name and a run-build argument
            if not re.fullmatch(r"[A-Za-z0-9._#-]{1,64}", label):
                label = k
            op = "0" if str(t.get("status") or "").strip().lower() in CLOSED_STATUSES else "1"
            seed = "waiting_client" if str(t.get("waitingOn") or "").lower() == "client" else "-"
            out.append((k, str(label), sha(t)[:16], op, seed))
    for r in out:
        if re.fullmatch(r"[A-Za-z0-9._-]{1,64}", r[0]):
            print("\t".join(r))


# ── hash ─────────────────────────────────────────────────────────────────────
def signal_module():
    spec = importlib.util.spec_from_file_location("triage_signal", os.path.join(HERE, "triage-signal.py"))
    if spec is None or spec.loader is None:
        fail()
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def label_names(v):
    out = []
    for lb in v or []:
        n = lb.get("name") if isinstance(lb, dict) else lb
        if n is not None and str(n).strip():
            out.append(str(n).strip().lower())
    return out


def ts_of(c):
    for k in ("createdAt", "created_at", "updatedAt", "updated_at"):
        v = c.get(k)
        if isinstance(v, str) and v:
            return v
    return ""


# REASON text only: a `#N` right after one of these WHOLE words is a count, not
# a ref ("attempt #2", "round #3"); "bypass #3165" and "PR number #3165" are refs. Never applied to the THREAD: that would move the
# base hash of every row whose thread says "attempt #2".
NOT_A_REF = re.compile(r"\b(?:attempt|round|try|retry|pass|step|take|item|option|point|no\.?)\s*$", re.I)


def gh_ref_names(text, prefix, key, reason_mode=False):
    names = set()
    for m in re.finditer(r"#(\d+)\b", text):
        if reason_mode and NOT_A_REF.search(text[max(0, m.start() - 12):m.start()]):
            continue
        names.add(m.group(1))
    if prefix:
        names |= set(re.findall(r"\b" + re.escape(prefix) + r"-(\d+)\b", text))
    names.discard(str(key))
    return names


def inapp_ref_names(text, self_key):
    return {k for k in re.findall(r"\b[A-Z][A-Z0-9]{0,9}-\d+\b", text) if k != self_key}


def reason_names_refs(gh, text, prefix, key, label=""):
    """Does a verdict reason name any ref? Decides the defer TTL: a defer whose
    reason names a ref is caught by the hash when that ref moves, so it gets
    no defer timer (only the TTL, when one is set); only a defer naming nothing
    gets the short recheck."""
    if gh:
        return bool(gh_ref_names(text or "", prefix, key, reason_mode=True))
    return bool(inapp_ref_names(text or "", label or None))


def resolve_refs(kind, w, key, prefix, extra, text, inapp_struct=False, reason_mode=False, merged=None, since=None):
    """The dependency list for the refs `text` names -> (deps, absent). ONE
    resolution path for thread refs and reason refs. GitHub: each #N /
    <PREFIX>-N (never the ticket itself) against the board fingerprint (the
    issue's state, `pr-open` for an open PR), else the caller's REST-looked-up
    state (refs.json: OPEN/CLOSED/MERGED/MISSING), else `absent`; every ref off
    the fingerprint is reported in `absent` so the caller looks it up (inside
    the per-tick fetch cap) and keeps it in refs.json. In-app: KEY-N with the
    status the fingerprint carries; inapp_struct adds the ticket's own
    blocked / parentId / dependsOn (the thread hash only, never a reason).
    merged/since (in-app reason refs only): a KEY merged after `since` (the
    verdict's triaged_at) is "<status>|merged"."""
    deps, absent = [], []
    if kind == "gh" and is_gh(w):
        states = {str(i.get("number")): str(i.get("state", "")).upper() for i in w["issues"] if isinstance(i, dict)}
        open_prs = {str(p.get("number")) for p in (w.get("prs") or []) if isinstance(p, dict)}
        refs = gh_ref_names(text, prefix, key, reason_mode)
        for n in sorted(refs, key=int):
            st = states.get(n) or ("pr-open" if n in open_prs else None)
            if not st:
                # off the board fingerprint: the caller's REST-looked-up state,
                # else absent. Reported either way, so the caller knows which
                # refs are still named (and re-asks / prunes by that).
                st = extra.get(n) or "absent"
                absent.append(n)
            deps.append([n, st])
    elif kind == "inapp":
        by_id = {str(t["id"]): t for t in inapp_tickets(w)}
        by_key = {str(t.get("key")): t for t in inapp_tickets(w) if t.get("key")}
        me = by_id.get(str(key)) or {}

        def st(t):
            return str((t or {}).get("status") or "absent")
        if inapp_struct:
            if isinstance(me.get("blocked"), bool):
                deps.append(["blocked", str(me["blocked"]).lower()])
            if me.get("parentId") is not None:
                deps.append(["parent:" + str(me["parentId"]), st(by_id.get(str(me["parentId"])))])
            for d in me.get("dependsOn") or []:
                deps.append(["dep:" + str(d), st(by_id.get(str(d)))])
        for k in sorted(inapp_ref_names(text, me.get("key"))):
            s = st(by_key.get(k))
            if reason_mode and merged and since is not None and merged.get(k, -1) > since:
                s += "|merged"
            deps.append(["ref:" + k, s])
    return deps, absent


def compose(base, rdeps):
    """The input hash: the thread-only base hash, composed with the reason's
    dependency states when the reason names any. A reason with no refs leaves
    the hash EXACTLY the base (the pre-reason-refs formula), so every row whose
    reason names nothing is untouched by the change."""
    return sha({"v": 2, "base": base, "reason_deps": sorted(rdeps)}) if rdeps else base


# A ref in one of these states will not change again: the thing a verdict
# waited on has happened (or is gone). Used by the legacy-row transition.
SETTLED = {"CLOSED", "MERGED", "MISSING"} | {x.upper() for x in CLOSED_STATUSES}


def settled(state):
    # "<status>|merged" (a reason ref merged after the verdict) is settled too:
    # the legacy-row transition must send it to the model, never restamp it.
    return str(state or "").upper() in SETTLED or str(state or "").endswith("|merged")


def hash_one(wrap, w, key, prefix, sm, extra=None, reason="", triaged_at=None, merged=None):
    """-> (input_hash, last_update_at, absent_refs, base_hash, reason_deps);
    raises SystemExit on a shape it cannot read. base_hash is the thread-only
    hash (the pre-reason-refs formula); input_hash composes it with the refs the
    stored verdict's `reason` names (see compose). last_update_at is the newest change of ANY kind the thread
    carries (the ticket's own updated stamp, every comment, ours included): the
    backfill seeds only from a decision newer than that. absent_refs are the #N
    this board fingerprint cannot place, for the caller to look up."""
    extra = extra or {}
    if not isinstance(wrap, dict) or wrap.get("kind") not in ("gh", "inapp"):
        fail()
    kind = wrap["kind"]
    doc = wrap.get("doc")
    if not isinstance(doc, dict):
        fail()
    # The signal module reads its self-identities from the environment: the
    # wrapper carries the values bin/triage-gate.sh resolved for this board.
    os.environ["SELF_ACTORS"] = str(wrap.get("self_actors") or "")
    os.environ["SELF_IDENTITIES"] = str(wrap.get("self_identities") or "")
    os.environ["SELF_APPS_JSON"] = json.dumps(wrap.get("self_apps") or [])
    sig = sm.gh(doc) if kind == "gh" else sm.inapp(doc)
    sig["comments"].sort(key=lambda r: canon(r))
    kept = {str(c[0]) for c in sig["comments"]}

    self_labels = {x.strip().lower() for x in (os.environ.get("TRIAGE_STATE_SELF_LABELS") or DEFAULT_SELF_LABELS).split(",") if x.strip()}
    if kind == "gh":
        ticket = doc.get("issue") or {}
        raw_comments = doc.get("comments") or []
    else:
        ticket = doc
        for k in ("ticket", "data"):
            if isinstance(doc.get(k), dict):
                ticket = doc[k]
                break
        raw_comments = ticket.get("comments") if isinstance(ticket.get("comments"), list) else doc.get("comments") or []
    labels = sorted(set(label_names(ticket.get("labels"))) - self_labels)

    stamps = [ts_of(c) for c in raw_comments if isinstance(c, dict)]
    for k in ("updated_at", "updatedAt", "lastActivityAt", "created_at", "createdAt"):
        v = ticket.get(k)
        if isinstance(v, str) and v:
            stamps.append(v)
    last_update_at = max((x for x in stamps if x), default="")

    def body_text(c):
        v = c[-1]
        return " ".join(str(y or "") for y in v) if isinstance(v, list) else str(v or "")
    text = " ".join([str(sig.get(k) or "") for k in ("title", "body", "description")] + [body_text(c) for c in sig["comments"]])
    deps, absent = resolve_refs(kind, w, key, prefix, extra, text, inapp_struct=True)
    base = sha({"v": 1, "sig": sig, "labels": labels, "deps": sorted(deps)})
    # REASON REFS: every #N / KEY-N the stored verdict's reason names is a
    # dependency too (a defer "until #3165" whose thread never names #3165).
    rdeps, rabsent = resolve_refs(kind, w, key, prefix, extra, reason or "", reason_mode=True,
                                  merged=merged, since=triaged_at)
    for n in rabsent:
        if n not in absent:
            absent.append(n)
    return compose(base, rdeps), last_update_at, (absent if kind == "gh" else []), base, rdeps


def cmd_hash(a):
    w = load_world(a.world)
    sm = signal_module()
    extra = load_refs(a.refs)
    reasons = load_reasons(a.rows)
    merged = load_merged_refs(a.merged_refs)
    triaged = load_triaged_at(a.rows) if merged else {}
    if a.batch:
        # key<TAB>raw-file per line -> key, hash, last_update_at, absent refs,
        # base (thread-only) hash, reason deps (JSON) — `-` for a thread this
        # cannot read (that ticket goes to the model).
        for line in open(a.batch):
            f = line.rstrip("\n").split("\t")
            if len(f) < 2:
                continue
            k, path = f[0], f[1]
            try:
                with open(path) as fh:
                    wrap = json.load(fh)
                h, lua, ab, base, rd = hash_one(wrap, w, k, a.prefix, sm, extra, reasons.get(k, ""),
                                                triaged.get(k), merged)
            except (SystemExit, OSError, ValueError, TypeError, AttributeError, KeyError):
                h, lua, ab, base, rd = "-", "", [], "-", []
            print("\t".join([k, h, lua or "-", ",".join(ab) or "-", base, canon(rd) if rd else "-"]))
        return
    try:
        wrap = json.loads(sys.stdin.read())
    except ValueError:
        fail()
    h, lua, ab, base, rd = hash_one(wrap, w, a.key, a.prefix, sm, extra, reasons.get(str(a.key), ""),
                                    triaged.get(str(a.key)), merged)
    print(canon({"input_hash": h, "last_update_at": lua, "absent_refs": ab, "base_hash": base, "reason_deps": rd}))


def load_reasons(path):
    """ticket_key -> the stored verdict's `reason` (the triage_state rows). Only
    `reason`: `last_decision` is the pre-check's own per-tick answer (`skip
    unchanged:queued`, `skip buildable-owned:pr-N`), rewritten every tick, so a
    ref in it would churn the hash; the model's words live in `reason`."""
    if not path:
        return {}
    try:
        rows = json.load(open(path))
    except (OSError, ValueError):
        return {}
    if not isinstance(rows, list):
        return {}
    return {str(r.get("ticket_key")): str(r.get("reason") or "") for r in rows
            if isinstance(r, dict) and r.get("verdict_hash")}


def load_triaged_at(path):
    """ticket_key -> the stored verdict's triaged_at (epoch), for rows with a
    verdict_hash: the sibling of load_reasons. An unparseable stamp is left
    out, so that row's reason refs are never suffixed."""
    if not path:
        return {}
    try:
        rows = json.load(open(path))
    except (OSError, ValueError):
        return {}
    if not isinstance(rows, list):
        return {}
    out = {}
    for r in rows:
        if isinstance(r, dict) and r.get("verdict_hash"):
            e = iso_epoch(r.get("triaged_at"))
            if e is not None:
                out[str(r.get("ticket_key"))] = e
    return out


def load_merged_refs(path):
    """KEY -> merged_at epoch from --merged-refs ({KEY: [pr, merged_at]}).
    Malformed entries are skipped; a missing or unreadable file is {}."""
    if not path:
        return {}
    try:
        m = json.load(open(path))
    except (OSError, ValueError):
        return {}
    if not isinstance(m, dict):
        return {}
    out = {}
    for k, v in m.items():
        if isinstance(v, list) and len(v) == 2 and isinstance(v[1], int) and not isinstance(v[1], bool):
            out[str(k)] = v[1]
    return out


def load_refs(path):
    if not path:
        return {}
    try:
        return {str(k): str(v) for k, v in json.load(open(path)).items()}
    except (OSError, ValueError, AttributeError):
        return {}


# ── decide ───────────────────────────────────────────────────────────────────
def iso_epoch(s):
    if not isinstance(s, str) or not s:
        return None
    try:
        return int(datetime.strptime(s[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc).timestamp())
    except ValueError:
        return None


def epoch_iso(e):
    return datetime.fromtimestamp(int(e), timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


CLIENT_RE = re.compile(r"client|clarif|question|asked|waiting on|needs? (info|answer)", re.I)


def verdict_of(action, reason):
    """The DECISION action (catalog/agent-contracts/triage-system-append.txt)
    mapped to a verdict and whose turn it is. Only `launch` is buildable: a
    `queue` line waits on a gate the queue lane owns."""
    action = (action or "").strip().lower()
    if action == "launch":
        return "buildable", "team"
    if action in ("queue", "defer"):
        return "queued", "team"
    if action == "escalate":
        return "hold", "none"
    if action == "close":
        return "closed", "none"
    if CLIENT_RE.search(reason or ""):
        return "needs_clarification", "client"
    return "triaged", "none"


# The action that changes nothing: the model read the ticket and left it
# ("skip :: QUEUED_FLY on pool, still running"). Part of the DECISION
# vocabulary above; the shadow scorecard never counts it as a miss.
NOOP_ACTIONS = ("skip",)
# Actions that ALWAYS have effect, whatever the stored verdict. A `launch` on a
# ticket already stored `buildable` is the real-miss shape: the earlier launch
# was lost (a context-drift deferral, a stranded queue row, a failed build —
# BH-1174) and the model relaunches it, which enforce would skip as owned. An
# `escalate` pages a person every time.
ALWAYS_EFFECT = ("launch", "escalate")


def has_effect(action, why, stored_verdict):
    """Would this DECISION have changed anything the gate kept from the model?
    Derived from the verdict vocabulary, not a second action list:
      - NOOP_ACTIONS (`skip`): never;
      - ALWAYS_EFFECT (`launch`, `escalate`): always;
      - `close`: unless the ticket is already stored `closed`;
      - anything else: when its verdict (verdict_of) differs from the stored
        one. So a `defer` on a triaged ticket is a miss, while a comment
        re-asking the client on a ticket already `needs_clarification` is not:
        the ticket is waiting on the client either way, the client's reply
        moves the input hash (and re-offers it), and enforce skipping the
        reminder loses no work — it only saves a nag."""
    a = (action or "").strip().lower()
    stored = stored_verdict or ""
    if a in NOOP_ACTIONS:
        return False
    if a in ALWAYS_EFFECT:
        return True
    if a == "close":
        return stored != "closed"
    return verdict_of(action, why)[0] != stored


def canon_key(k, gh, prefix, keymap):
    k = (k or "").strip().lstrip("#")
    if gh:
        m = re.fullmatch(r"(?:[A-Za-z]+-)?(\d+)", k)
        return m.group(1) if m else None
    if keymap.get(k) is not None and not re.fullmatch(r"[A-Z][A-Z0-9]*-\d+", str(keymap.get(k))):
        return str(keymap[k])
    return k if re.fullmatch(r"[A-Za-z0-9._-]{1,64}", k) else None


DEC_RE = re.compile(r"^(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2})Z \[([^\]]+)\] gate=\S* scope=\S* (.+?) :: (\S+) :: ?(.*)$")


def last_decisions(path, project, gh, prefix, keymap):
    out = {}
    if not path:
        return out
    try:
        f = open(path, errors="replace")
    except OSError:
        return out
    with f:
        for line in f:
            m = DEC_RE.match(line.rstrip("\n"))
            if not m or m.group(3) != project:
                continue
            k = canon_key(m.group(4), gh, prefix, keymap)
            if k:
                out[k] = (f"{m.group(1)}T{m.group(2)}Z", m.group(5), m.group(6))
    return out


# DEFER-LIKE verdicts wait on something that may carry no ref at all (a
# harness code change, a gate another lane owns), so they come back to the
# model after TRIAGE_STATE_DEFER_TTL_S (7200), even at TTL 0. From the
# verdict vocabulary (worker/jobs/src/routes/triage-state.js TRIAGE_VERDICTS):
#   queued   DECISION `defer` or `queue` (verdict_of)
#   blocked  in the vocabulary for a verdict that waits on a blocker
# NOT defer-like: needs_clarification / waiting_client (the client's reply
# moves the thread hash; its only timer is the CLIENT_TURN nudge), hold (an
# escalation waits on a person, whose comment or label moves the hash),
# buildable / triaged / closed (nothing awaited).
DEFER_LIKE = ("queued", "blocked")

# HANDED-NO-DECISION (BH-3920). A ticket an rc-0 session was handed and
# answered with no DECISION line (and no summary) gets this reason, with the
# input hash it was handed as its marker, and a backoff in next_recheck_at. No
# verdict is claimed. Until the backoff ends, and while its inputs still hash
# to the marker, the pre-check keeps it off the model.
HND = "handed-no-decision"
HND_RE = re.compile(r"^handed-no-decision ([0-9a-f]{16,64})\b")
HND_WAS = "; was: "


def hnd_marker(row):
    """The input hash a handed-no-decision row was handed, else None."""
    m = HND_RE.match(str((row or {}).get("reason") or ""))
    return m.group(1) if m else None


def hnd_was(reason):
    """The reason a hand-off replaced: a hand-off's own `; was: X` keeps X only,
    so a second hand-off never nests the first."""
    reason = str(reason or "")
    if not HND_RE.match(reason):
        return reason
    i = reason.find(HND_WAS)
    return reason[i + len(HND_WAS):] if i >= 0 else ""


# NO-DECISION RETRY (BH-8497). An rc-0 session that left evidence (a DECISION
# line for another ticket, or a `tickets=` summary) but no DECISION line for a
# model-set ticket stamps it `triaged` with this reason. That was final: at TTL
# 0 nothing re-offered it, and an old ticket sat off the model forever. Now the
# reason carries a counter, `(no-decision c/N)`, and the row is due again after
# the backoff until c reaches N (--no-decision-retries); the next one is
# `(no-decision retries spent N/N)`, final, and named in `no_decision_spent`.
# The bare prefix (no counter) is a row written before this, or with N = 0: it
# counts as 1.
ND_PREFIX = "in the model set and in scope, no DECISION line, session rc 0"
ND_RE = re.compile(r" \(no-decision (\d+)/(\d+)\)$")
ND_SPENT = " (no-decision retries spent "


def nd_count(reason):
    """The no-DECISION count a reason carries: 0 for any other reason, 1 for
    the bare prefix, the counter when present, None when spent."""
    reason = str(reason or "")
    if not reason.startswith(ND_PREFIX):
        return 0
    rest = reason[len(ND_PREFIX):]
    if not rest:
        return 1
    if rest.startswith(ND_SPENT):
        return None
    m = ND_RE.fullmatch(rest)
    return int(m.group(1)) if m else 0


# CLIENT TURN (BH-3921): the ticket waits on the client. Its reply moves the
# input hash, so the only timer it gets is the nudge (--nudge, 0 = off).
CLIENT_TURN = ("needs_clarification", "waiting_client")


def client_turn(verdict, waiting_on):
    return verdict in CLIENT_TURN or waiting_on == "client"


def recheck_ttl(verdict, ttl, defer_ttl, names_refs=False, nudge=0, client=False):
    """Seconds until a fresh verdict's recheck, or None (no timer: the row
    carries no next_recheck_at). A defer-like verdict naming NO ref gets the
    defer TTL (one that names a ref is re-offered by the hash when the ref
    moves); a client turn gets the nudge; anything else the TTL, and at TTL 0
    nothing."""
    if verdict in DEFER_LIKE and not names_refs:
        return min(ttl, defer_ttl) if ttl > 0 else defer_ttl
    if client and nudge > 0:
        return min(ttl, nudge) if ttl > 0 else nudge
    return ttl if ttl > 0 else None


def due_at(row, now, ttl, defer_ttl, names_refs, nudge=0, nd_retries=0):
    """When a stored verdict is due back at the model (epoch), or None: never
    on a timer. ONE place for the rule (`due` and `decide` both ask it):
      a. a handed-no-decision row: its backoff stamp;
      a2. nd_retries > 0, a `triaged` no-DECISION row with retries left
         (1 <= nd_count <= nd_retries): its stamp, else now (BH-8497);
      b. ttl > 0, the per-ticket sweep: the stamp, else triaged_at + ttl; a
         defer-like verdict naming no ref is clamped to triaged_at + defer_ttl
         and a client turn to triaged_at + nudge;
      c. ttl == 0, defer-like naming no ref: the earlier of the stamp and
         triaged_at + defer_ttl;
      d. ttl == 0, a client turn, nudge > 0: triaged_at + nudge;
      e. otherwise never. A leftover next_recheck_at is ignored."""
    stamp = iso_epoch(row.get("next_recheck_at"))
    if stamp is not None and hnd_marker(row):
        # a hand-off's backoff, never cut short by the clamps below
        return stamp
    if nd_retries > 0 and row.get("verdict") == "triaged":
        c = nd_count(row.get("reason"))
        if c is not None and 1 <= c <= nd_retries:
            return stamp if stamp is not None else now
    ta = iso_epoch(row.get("triaged_at"))
    defer = row.get("verdict") in DEFER_LIKE and not names_refs
    client = client_turn(row.get("verdict"), row.get("waiting_on"))
    if ttl > 0:
        due = stamp
        if due is None:
            due = (ta + ttl) if ta is not None else now
        if defer and ta is not None:
            # a defer stamped under a longer TTL (before this knob) is due too
            due = min(due, ta + defer_ttl)
        if client and nudge > 0 and ta is not None:
            due = min(due, ta + nudge)
        return due
    if defer:
        c = [x for x in (stamp, (ta + defer_ttl) if ta is not None else None) if x is not None]
        return min(c) if c else None
    if client and nudge > 0 and ta is not None:
        return ta + nudge
    return None


def cmd_due(a):
    """The keys of the rows whose recheck is due now (one per line)."""
    try:
        rows = json.load(open(a.rows))
    except (OSError, ValueError):
        return
    if not isinstance(rows, list):
        return
    now, ttl = int(a.now), int(a.ttl)
    defer_ttl = int(a.defer_ttl) if a.defer_ttl else ttl
    nudge = int(a.nudge or 0)
    nd = int(a.no_decision_retries or 0)
    for r in rows:
        if not isinstance(r, dict) or not r.get("ticket_key"):
            continue
        if not r.get("next_recheck_at") and not r.get("triaged_at"):
            continue
        refs = reason_names_refs(a.gh == "1", str(r.get("reason") or ""), a.prefix, r["ticket_key"], r.get("ticket_label") or "")
        d = due_at(r, now, ttl, defer_ttl, refs, nudge, nd)
        if d is not None and now >= d:
            print(r["ticket_key"])


def closed_state(w):
    """ticket key -> closedAt ('' when the world does not carry it) for every
    ticket CLOSED in this world (a GitHub issue's state, an in-app status in
    CLOSED_STATUSES)."""
    out = {}
    if not isinstance(w, dict):
        return out
    if is_gh(w):
        for i in w["issues"]:
            if isinstance(i, dict) and i.get("number") is not None and str(i.get("state", "")).upper() == "CLOSED":
                out[str(i["number"])] = str(i.get("closedAt") or i.get("closed_at") or "")
    else:
        for t in inapp_tickets(w):
            if str(t.get("status") or "").strip().lower() in CLOSED_STATUSES:
                out[str(t["id"])] = str(t.get("closedAt") or t.get("closed_at") or "")
    return out


def closed_stamp(h):
    """The verdict hash a `closed` verdict is stamped with. A closed ticket is
    never hashed (only open ones are), so the hash on hand is its last OPEN
    hash; stamping that would make a reopen with an unchanged thread read as
    unchanged. Salted, a reopen always moves the hash and goes to the model."""
    return sha({"closed": h})


def cmd_decide(a):
    try:
        rows = json.load(open(a.rows))
    except (OSError, ValueError):
        rows = None
    rows_ok = isinstance(rows, list)
    by_key = {str(r.get("ticket_key")): r for r in rows} if rows_ok else {}
    keymap = load_keymap(a.keymap)
    decs = last_decisions(a.decisions, a.project, a.gh == "1", a.prefix, keymap)
    now, ttl = int(a.now), int(a.ttl)
    defer_ttl = int(a.defer_ttl) if a.defer_ttl else ttl
    nudge = int(a.nudge or 0)
    nd = int(a.no_decision_retries or 0)
    gh = a.gh == "1"
    deferred_why = "deferred:" + (a.deferred_why if a.deferred_why in ("cap", "budget") else "cap")
    deferred = set()
    if a.deferred:
        try:
            deferred = {x.strip() for x in open(a.deferred) if x.strip()}
        except OSError:
            deferred = set()

    def emit(key, label, dec, why, h, seed_json, base="-", note="-"):
        print("\t".join([key, label, dec, why, h, seed_json, base or "-", note]))

    def out(key, label, dec, why, h, seed_json, base="-", note="-"):
        if key in deferred and dec != "stamp":
            # A thread whose row moved and was not read this tick is never
            # "unchanged" and never the model's: it is carried to the next tick
            # (deferred.keys, gate step 1d). Its stale hash is still recorded
            # (column 5).
            dec, why = "skip", deferred_why
        elif dec == "llm" and why in ("new", "changed", "recheck-due") and rows_ok:
            row = by_key.get(key) or {}
            hold = iso_epoch(row.get("next_recheck_at"))
            if hnd_marker(row) == h and hold is not None and now < hold:
                dec, why = "skip", HND
        emit(key, label, dec, why, h, seed_json, base, note)
    for line in open(a.hashes):
        f = line.rstrip("\n").split("\t")
        if len(f) < 6:
            continue
        key, label, h, lua, op, seed = f[:6]
        base = f[6] if len(f) > 6 and f[6] else "-"
        try:
            rdeps = json.loads(f[7]) if len(f) > 7 and f[7] not in ("", "-") else []
        except ValueError:
            rdeps = []
        if op != "1":
            # CLOSED in this tick's world. Stamped `closed` HERE, with no model
            # call: #3388 stamped it only when a session ran for the ticket, and
            # none does (every shard is a PR or an open ticket), so BH-3316,
            # 3320, 2649, 2652, 3321 sat `triaged` and "to the model" every
            # enforce tick. Also a closed ticket never triaged at all (no row).
            # The stamp is salted (closed_stamp), so a reopen moves the hash.
            if not rows_ok:
                continue
            row = by_key.get(key) or {}
            if row.get("verdict") == "closed":
                continue
            st = closed_stamp(row.get("input_hash") or row.get("verdict_hash") or ("key:" + key))
            seed = {"verdict": "closed", "waiting_on": "none", "verdict_hash": st, "input_hash": st,
                    "triaged_at": epoch_iso(now),
                    "reason": "closed on the board; stamped without a model call"}
            if ttl > 0:
                seed["next_recheck_at"] = epoch_iso(now + ttl)
            out(key, label, "stamp", "closed-on-board", st, canon(seed))
            continue
        seed_json = "-"
        note = "-"
        if h == "-":
            # a deferred key (no cached thread, no read this tick) is not a
            # failed read: out() carries it as `skip deferred:<why>`
            out(key, label, "llm", "unhashable", "-", "-")
            continue
        if not rows_ok:
            out(key, label, "llm", "rows-unreadable", h, "-", base)
            continue
        row = by_key.get(key)
        if row is None or not row.get("verdict_hash"):
            d = decs.get(key)
            lh = iso_epoch(lua) if lua != "-" else None
            v = None
            if d and (lh is None or (iso_epoch(d[0]) or 0) >= lh):
                v, won = verdict_of(d[1], d[2])
                why = f"seeded from decisions.log {d[0]}: {d[1]} :: {d[2]}"[:480]
                tat = d[0]
            elif seed == "waiting_client":
                v, won, why, tat = "waiting_client", "client", "seeded from the board's waitingOn=client", epoch_iso(now)
            if v:
                te = iso_epoch(tat) or now
                # Seeded against the hash computed with no stored reason (the
                # base). A seed reason that names refs is a legacy row next
                # tick: re-stamped if they are all open, to the model if one
                # has settled since.
                row = {"verdict": v, "waiting_on": won, "verdict_hash": h, "triaged_at": tat, "reason": why}
                rt = recheck_ttl(v, ttl, defer_ttl, reason_names_refs(gh, why, a.prefix, key, label),
                                 nudge, client_turn(v, won))
                if rt is not None:
                    row["next_recheck_at"] = epoch_iso(te + rt)
                seed_json = canon(row)
            else:
                out(key, label, "llm", "new", h, "-", base)
                continue
        vh = row.get("verdict_hash")
        if vh != h and rdeps and base != "-" and vh == base and key not in deferred:
            # THE TRANSITION. This row was stamped before reason refs joined the
            # hash (or seeded without its reason): its verdict_hash is the
            # thread-only base, and the thread has not moved. Its reason's refs
            # were not recorded, so their verdict-time state is unknown:
            #  - one has SETTLED (merged/closed/missing): the thing the verdict
            #    waited on may have happened — the incident — to the model;
            #  - one is not yet looked up (GitHub `absent`: the fetch cap or a
            #    low budget): decide as unchanged, re-stamp nothing, ask again;
            #  - all still open: re-stamp verdict_hash to the new hash in place,
            #    no model call. One-time, bounded by the rows whose reason names
            #    a ref, logged by the shell ("re-stamped N legacy verdict(s)").
            states = [x[1] for x in rdeps if isinstance(x, list) and len(x) > 1]
            if any(settled(x) for x in states):
                out(key, label, "llm", "changed", h, seed_json, base, "reason-ref-settled")
                continue
            if not (gh and any(x == "absent" for x in states)):
                sj = json.loads(seed_json) if seed_json != "-" else {}
                sj["verdict_hash"] = h
                seed_json = canon(sj)
                note = "restamp"
            vh = h
        if vh != h:
            out(key, label, "llm", "changed", h, seed_json, base)
            continue
        due = due_at(row, now, ttl, defer_ttl, bool(rdeps), nudge, nd)
        if due is not None and now >= due:
            out(key, label, "llm", "recheck-due", h, seed_json, base, note)
            continue
        v = row.get("verdict") or "triaged"
        if v == "buildable":
            out(key, label, "candidate", "buildable", h, seed_json, base, note)
        else:
            out(key, label, "skip", "unchanged:" + v, h, seed_json, base, note)


def cmd_record(a):
    """The session's verdicts as triage_state rows: {project, rows:[...]}.
    Single session (no --key): every DECISION line whose ticket has a pre-check
    hash this tick, and on rc 0 every model-set ticket with no line is
    `triaged`. Shard (--key K --hash H): that key only. rc != 0: nothing.
    The shadow scorecard rides along: a DECISION that changed something on a
    ticket the gate kept from the model is `missed` (with `missed_detail`:
    key, label, action, gate reason), unless the ticket had a queue line or a
    finished build this tick (decisions.tsv column 9), which is `work`; one
    that changed nothing is `noop`.
    HANDED-NO-DECISION (BH-3920): rc 0, a model-set ticket in scope with no
    DECISION line, and a session that left no evidence at all (no DECISION
    line, no `tickets=` summary). It gets a partial row: `reason` =
    `handed-no-decision <marker>: ...[; was: <previous reason>]` and
    next_recheck_at = now + --hnd-backoff. No verdict, verdict_hash,
    triaged_at or waiting_on: nothing is claimed about the ticket. pr-* keys
    never get one (the BH-3417 PR record contract). Listed in
    `handed_no_decision`."""
    if a.rc != "0":
        print(canon({"project": a.project, "rows": [], "missed": [], "missed_detail": [], "noop": [], "work": [],
                     "handed_no_decision": []}))
        return
    keymap = load_keymap(a.keymap)
    gh = a.gh == "1"
    now, ttl = int(a.now), int(a.ttl)
    nudge = int(a.nudge or 0)
    lines = []
    try:
        for line in open(a.out, errors="replace"):
            if line.startswith("DECISION:"):
                lines.append(line.rstrip("\n")[len("DECISION:"):].strip())
    except OSError:
        pass
    said = {}
    for body in lines:
        parts = [x.strip() for x in body.split("::", 2)]
        if len(parts) < 2:
            continue
        k = canon_key(parts[0], gh, a.prefix, keymap)
        if k:
            said[k] = (parts[1], parts[2] if len(parts) > 2 else "")
        # A PR shard (--key pr-<n>): its DECISION names the PR as pr-<n>, #<n>
        # or <n> (issues and PRs share one number space); canon_key folds all
        # of them onto <n>, which is not the shard's key.
        if a.key.startswith("pr-"):
            m = re.fullmatch(r"(?i)(?:pr-|#)?(\d+)", parts[0].strip())
            if m and m.group(1) == a.key[3:]:
                said[a.key] = (parts[1], parts[2] if len(parts) > 2 else "")
    # A session that printed neither its summary nor a single DECISION line has
    # told us nothing about what it read: no blanket stamp from it.
    evidence = bool(lines)
    if not evidence:
        try:
            evidence = any("tickets=" in line for line in open(a.out, errors="replace"))
        except OSError:
            evidence = False
    targets = {}   # key -> (label, hash, in_model_set, in_scope, reason, decision, base, work)
    shard_llm = True
    tsv = []
    try:
        for line in open(a.decisions) if a.decisions else []:
            f = line.rstrip("\n").split("\t")
            if len(f) >= 5 and f[4] != "-":
                tsv.append(f)
    except OSError:
        tsv = []
    if a.key:
        if a.hash and re.fullmatch(r"[0-9a-f]{16,64}", a.hash):
            # the shard's base: the decisions.tsv line that handed it this hash
            line = next((f for f in tsv if f[0] == a.key and f[4] == a.hash), None)
            base = line[7] if line and len(line) > 7 else "-"
            # the shard's decision reason too (`closed` for an `llm closed` key),
            # and for a PR shard its decision (`skip` when the pre-check would
            # have kept it from the model), so has_effect can score a miss
            dec0 = line[2] if a.key.startswith("pr-") and line and len(line) > 2 else "llm"
            # a shard for a key the pre-check did not send to the model (shadow
            # dispatches every key) is never a hand-off
            shard_llm = not (line and len(line) > 2 and line[2] != "llm")
            targets[a.key] = ("", a.hash, True, True, line[3] if line and len(line) > 3 else "", dec0, base,
                              bool(line and len(line) > 8 and line[8] == "1"))
    else:
        for f in tsv:
            targets[f[0]] = (f[1], f[4], f[2] == "llm", (f[6] if len(f) > 6 else "1") == "1", f[3], f[2],
                             f[7] if len(f) > 7 else "-", len(f) > 8 and f[8] == "1")
    w = None
    if a.world:
        try:
            w = json.load(open(a.world))
        except (OSError, ValueError):
            w = None
    kind = "gh" if isinstance(w, dict) and is_gh(w) else "inapp"
    closed_now = closed_state(w)
    extra = load_refs(a.refs)
    defer_ttl = int(a.defer_ttl) if a.defer_ttl else ttl
    hnd_backoff = int(a.hnd_backoff) if a.hnd_backoff else defer_ttl
    nd_cap = int(a.no_decision_retries or 0)
    nd_backoff = int(a.nd_backoff) if a.nd_backoff else hnd_backoff
    prev = {}   # ticket_key -> the row's reason before this session
    if a.rows:
        try:
            for r in json.load(open(a.rows)):
                if isinstance(r, dict) and r.get("ticket_key") is not None:
                    prev[str(r["ticket_key"])] = str(r.get("reason") or "")
        except (OSError, ValueError, TypeError):
            prev = {}
    unresolved = set()

    def stamp_of(k, h, base, reason):
        # The verdict is stamped against the PRE-session thread (base) composed
        # with the refs its NEW reason names, at their pre-session state (the
        # tick's board fingerprint and refs.json): exactly what next tick's
        # pre-check computes when nothing moved. Stamping the pre-session
        # composite instead would carry the OLD reason's refs and re-offer the
        # ticket the tick after every verdict whose reason names a new ref.
        if not isinstance(w, dict) or not re.fullmatch(r"[0-9a-f]{16,64}", base or ""):
            return h   # no base to compose from: the hash handed over, as before
        rd, ab = resolve_refs(kind, w, k, a.prefix, extra, reason, reason_mode=True)
        unresolved.update(n for n in ab if extra.get(n) is None)
        return compose(base, rd)

    rows = []
    missed = []   # the shadow scorecard: a DECISION the gate would have lost
    missed_detail = []   # [key, label, action, gate reason] per miss, for the snapshot
    noop = []     # a DECISION on a skipped ticket that changed nothing
    work = []     # a DECISION on a skipped ticket with queue / close-out work
    handed = []   # model-set tickets the session returned nothing for
    nd_spent = []  # no-DECISION retries spent this session (BH-8497)
    for k, (label, h, in_set, in_scope, why0, dec0, base, wk) in sorted(targets.items()):
        nd_next = None
        if k in said:
            action, why = said[k]
            v, won = verdict_of(action, why)
            reason = f"DECISION {action}: {why}"
            # A ticket the gate kept from the model: `skip unchanged:<verdict>`,
            # or `skip buildable-owned:…` / `buildable-held:…` (stored buildable),
            # or `skip handed-no-decision` (held; it stores no verdict).
            if dec0 == "skip" and (why0.startswith("unchanged") or why0.startswith("buildable-") or why0 == HND):
                stored = ("buildable" if why0.startswith("buildable-") else
                          "" if why0 == HND else (why0.split(":", 1)[1] if ":" in why0 else ""))
                if not has_effect(action, why, stored):
                    noop.append(f"{label or k} ({action})")
                elif wk:
                    # A queue line or a finished build in this tick (decisions.tsv
                    # column 9): enforce never keeps it from the model
                    # (ts_tick), so the scorecard does not count it lost.
                    work.append(f"{label or k} ({action})")
                else:
                    missed.append(f"{label or k} ({action})")
                    missed_detail.append([k, label or k, action, why0])
        elif in_set and in_scope and evidence:
            # Only a ticket this tick's scope actually put in front of the
            # model: a scoped tick never read the rest of the model set.
            v, won, reason = "triaged", "none", ND_PREFIX
            if nd_cap > 0 and why0 != "closed" and k not in closed_now:
                c0 = nd_count(prev.get(k, ""))
                if c0 is None:
                    # already spent: stays final, and was named when it spent
                    reason = f"{ND_PREFIX}{ND_SPENT}{nd_cap}/{nd_cap})"
                elif c0 + 1 <= nd_cap:
                    reason = f"{ND_PREFIX} (no-decision {c0 + 1}/{nd_cap})"
                    nd_next = now + nd_backoff
                else:
                    reason = f"{ND_PREFIX}{ND_SPENT}{nd_cap}/{nd_cap})"
                    nd_spent.append(label or k)
        elif in_set and in_scope and shard_llm and not k.startswith("pr-") and k not in closed_now and why0 != "closed":
            # HANDED, NO DECISION, NO EVIDENCE: hold it for the backoff, claim
            # nothing. The marker is the hash the next tick computes when
            # nothing moves (the marker text names no ref, so the full reason
            # resolves the same refs as the reason it replaced).
            was = hnd_was(prev.get(k, ""))
            marker = stamp_of(k, h, base, was)
            reason = (f"{HND} {marker}: the session was handed this ticket and returned no DECISION line; "
                      f"offered again after {hnd_backoff}s" + (f"{HND_WAS}{was}" if was else ""))[:480]
            r = {"ticket_key": k, "next_recheck_at": epoch_iso(now + hnd_backoff), "reason": reason}
            if label and re.fullmatch(r"[A-Za-z0-9._#-]{1,64}", label):
                r["ticket_label"] = label
            rows.append(r)
            handed.append(label or k)
            continue
        else:
            continue
        # A ticket CLOSED in this tick's world (or handed over as `llm closed`)
        # is stamped `closed` WHATEVER the action: the model answers a closed
        # ticket with `skip` or a close-out `comment`, which verdict_of maps to
        # `triaged`, and a `triaged` row on a closed ticket is `llm closed`
        # again next tick, forever (BH-3316 / BH-3320, enforce 2026-09-28).
        # The model's reason text is kept.
        is_closed = why0 == "closed" or k in closed_now
        if is_closed:
            v, won = "closed", "none"
        reason = reason[:480]
        hv = closed_stamp(h) if is_closed else stamp_of(k, h, base, reason)
        r = {"ticket_key": k, "verdict": v, "waiting_on": won, "verdict_hash": hv, "input_hash": hv,
             "triaged_at": epoch_iso(now), "reason": reason}
        # No timer, no stamp: the worker keeps an existing row's old stamp,
        # which due_at at TTL 0 ignores for a verdict that has no timer.
        rt = recheck_ttl(v, ttl, defer_ttl, reason_names_refs(gh, reason, a.prefix, k, label), nudge, client_turn(v, won))
        if rt is not None:
            r["next_recheck_at"] = epoch_iso(now + rt)
        if not is_closed and nd_next is not None:
            r["next_recheck_at"] = epoch_iso(nd_next)
        if label and re.fullmatch(r"[A-Za-z0-9._#-]{1,64}", label):
            r["ticket_label"] = label
        rows.append(r)
    print(canon({"project": a.project, "rows": rows, "missed": missed, "missed_detail": missed_detail,
                 "noop": noop, "work": work, "handed_no_decision": handed, "no_decision_spent": nd_spent,
                 "unresolved": sorted(unresolved, key=lambda x: int(x) if x.isdigit() else 0)}))


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd")
    e = sub.add_parser("entries")
    e.add_argument("--world", required=True)
    e.add_argument("--prefix", default="")
    e.add_argument("--keymap", default="")
    h = sub.add_parser("hash")
    h.add_argument("--world", required=True)
    h.add_argument("--key", default="")
    h.add_argument("--batch", default="")
    h.add_argument("--refs", default="")
    h.add_argument("--prefix", default="")
    h.add_argument("--rows", default="")
    h.add_argument("--merged-refs", default="")
    d = sub.add_parser("decide")
    d.add_argument("--hashes", required=True)
    d.add_argument("--rows", required=True)
    d.add_argument("--now", required=True)
    d.add_argument("--ttl", required=True)
    d.add_argument("--defer-ttl", default="")
    d.add_argument("--world", default="")   # accepted; the closed stamp needs no closedAt
    d.add_argument("--decisions", default="")
    d.add_argument("--project", default="")
    d.add_argument("--prefix", default="")
    d.add_argument("--keymap", default="")
    d.add_argument("--gh", default="0")
    d.add_argument("--deferred", default="")
    d.add_argument("--deferred-why", default="cap")   # cap | budget (anything else reads as cap)
    d.add_argument("--nudge", default="0")
    d.add_argument("--no-decision-retries", default="0")   # 0 = a no-DECISION verdict is final
    u = sub.add_parser("due")
    u.add_argument("--rows", required=True)
    u.add_argument("--now", required=True)
    u.add_argument("--ttl", required=True)
    u.add_argument("--defer-ttl", default="")
    u.add_argument("--prefix", default="")
    u.add_argument("--gh", default="0")
    u.add_argument("--nudge", default="0")
    u.add_argument("--no-decision-retries", default="0")
    r = sub.add_parser("record")
    r.add_argument("--project", required=True)
    r.add_argument("--out", required=True)
    r.add_argument("--rc", required=True)
    r.add_argument("--now", required=True)
    r.add_argument("--ttl", required=True)
    r.add_argument("--defer-ttl", default="")
    r.add_argument("--world", default="")
    r.add_argument("--refs", default="")
    r.add_argument("--decisions", default="")
    r.add_argument("--key", default="")
    r.add_argument("--hash", default="")
    r.add_argument("--prefix", default="")
    r.add_argument("--keymap", default="")
    r.add_argument("--gh", default="0")
    r.add_argument("--rows", default="")
    r.add_argument("--hnd-backoff", default="")
    r.add_argument("--nudge", default="0")
    r.add_argument("--no-decision-retries", default="0")
    r.add_argument("--nd-backoff", default="")   # empty = --hnd-backoff
    a = ap.parse_args()
    if a.cmd == "entries":
        cmd_entries(a)
    elif a.cmd == "hash":
        cmd_hash(a)
    elif a.cmd == "decide":
        cmd_decide(a)
    elif a.cmd == "due":
        cmd_due(a)
    elif a.cmd == "record":
        cmd_record(a)
    else:
        fail()


if __name__ == "__main__":
    main()
