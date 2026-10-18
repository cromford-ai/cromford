#!/bin/bash
# tests/lib/fake-docker.bh-7347.sh — the stub `docker` CLI that
# tests/docker-pool-runner.bh-7347-test.sh puts first on PATH. It records
# every call (one line: the argv) to $FAKE_DOCKER_LOG and keeps one directory
# per container under $FAKE_DOCKER_DIR/<id>/ (state, log, labels, pid, mounts).
#
# `docker run -d ...` parses the `-v host:/run/harness` and `-v host:/data`
# mounts and the `--label` flags, then plays a scripted container in the
# background, chosen by FAKE_DOCKER_SCRIPT at run time:
#   result   after FAKE_DOCKER_DELAY s (default 1): write data/harness/logs/cost.csv,
#            run/RESULT `PR_CREATED https://x/pull/1` and the done line
#            `job cycle complete`, then idle (state stays running)
#   smoke    the same with RESULT `SMOKE_OK claude credential alive host=builder-<p>`
#   late     RESULT at once, the done line FAKE_DOCKER_LATE_S s later (default 3)
#   forever  idle, no RESULT
#   noresult after FAKE_DOCKER_DELAY s: the container exits, no RESULT
# At run time it also writes <id>/seen: which files the mounts held then.
#
# Other verbs: info (rc FAKE_DOCKER_INFO_RC, default 0), inspect -f (prints the
# state), logs, stop, rm, ps --filter label=harness.docker-pool=1 (prints
# `<id>\t<lease label>` for each running container with that label).
set -u
D="${FAKE_DOCKER_DIR:?FAKE_DOCKER_DIR unset}"
mkdir -p "$D"
printf '%s\n' "$*" >> "${FAKE_DOCKER_LOG:-$D/docker.log}"
verb="${1:-}"; shift || true

cdir() { [ -n "${1:-}" ] && [ -d "$D/c/$1" ] && printf '%s' "$D/c/$1"; }

case "$verb" in
  info) exit "${FAKE_DOCKER_INFO_RC:-0}" ;;
  run)
    runh=""; datah=""; labels=""; proj=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -v) case "$2" in *:/run/harness) runh="${2%:/run/harness}" ;; *:/data) datah="${2%:/data}" ;; esac; shift 2 ;;
        --label) labels="$labels$2"$'\n'; shift 2 ;;
        -e) case "$2" in PROJECT=*) proj="${2#PROJECT=}" ;; esac; shift 2 ;;
        -d) shift ;;
        --platform|--name|--hostname|--cpus|--memory) shift 2 ;;
        *) shift ;;
      esac
    done
    [ -n "$runh" ] && [ -n "$datah" ] || { echo "fake docker: no mounts" >&2; exit 125; }
    n=$(( $(cat "$D/count" 2>/dev/null || echo 0) + 1 )); printf '%s\n' "$n" > "$D/count"
    id=$(printf 'fd%010x' "$n")
    c="$D/c/$id"; mkdir -p "$c"
    printf '%s' "$labels" > "$c/labels"
    printf '%s\n%s\n' "$runh" "$datah" > "$c/mounts"
    echo running > "$c/state"; : > "$c/log"
    { [ -x "$datah/harness/fly/builder-runner.sh" ] && echo builder-runner
      [ -s "$runh/job.json" ] && echo "job $(cat "$runh/job.json")"
      for f in "$runh"/../env/*; do [ -e "$f" ] && echo "env ${f##*/}"; done
      [ -s "$datah/harness/HARNESS_COMMIT" ] && echo harness-commit
    } > "$c/seen"
    script="${FAKE_DOCKER_SCRIPT:-result}"; delay="${FAKE_DOCKER_DELAY:-1}"; late="${FAKE_DOCKER_LATE_S:-3}"
    (
      done_line() { echo "[fixture] [runner/$proj] job cycle complete; idling up to 600s for next push" >> "$c/log"; }
      case "$script" in
        result|smoke)
          sleep "$delay"
          mkdir -p "$datah/harness/logs"
          echo "ts,box,fixture-cost-row" > "$datah/harness/logs/cost.csv"
          if [ "$script" = smoke ]; then echo "SMOKE_OK claude credential alive host=builder-$proj" > "$runh/RESULT"
          else printf 'PR_CREATED https://x/pull/1\nTIER: 2\n' > "$runh/RESULT"; fi
          done_line ;;
        late) printf 'PR_CREATED https://x/pull/1\n' > "$runh/RESULT"; sleep "$late"; done_line ;;
        noresult) sleep "$delay"; echo exited > "$c/state"; exit 0 ;;
      esac
      exec sleep 600
    ) </dev/null >/dev/null 2>&1 &
    echo $! > "$c/pid"
    printf '%s\n' "$id" ;;
  inspect)
    [ "${1:-}" = -f ] && shift 2
    c=$(cdir "${1:-}") || exit 1
    cat "$c/state" ;;
  logs)
    [ "${1:-}" = --tail ] && shift 2
    c=$(cdir "${1:-}") || exit 1
    cat "$c/log" ;;
  stop)
    [ "${1:-}" = -t ] && shift 2
    c=$(cdir "${1:-}") || exit 1
    kill "$(cat "$c/pid" 2>/dev/null)" 2>/dev/null
    echo exited > "$c/state"; printf '%s\n' "$1" ;;
  rm)
    [ "${1:-}" = -f ] && shift
    c=$(cdir "${1:-}") || exit 1
    kill "$(cat "$c/pid" 2>/dev/null)" 2>/dev/null
    echo removed > "$c/state"; printf '%s\n' "$1" ;;
  ps)
    case "$*" in *label=harness.docker-pool=1*) ;; *) exit 0 ;; esac
    for c in "$D"/c/*; do
      [ -d "$c" ] || continue
      [ "$(cat "$c/state")" = running ] || continue
      grep -qx 'harness.docker-pool=1' "$c/labels" 2>/dev/null || continue
      printf '%s\t%s\n' "${c##*/}" "$(sed -n 's/^harness\.docker-pool\.lease=//p' "$c/labels")"
    done ;;
  *) echo "fake docker: verb '$verb' not stubbed" >&2; exit 125 ;;
esac
