#!/bin/bash
# bin/lib/hub-move-reach.sh — can the new hub reach the fleet? (BH-8123).
# Sourced by bin/hub-move.sh, never executed; sourcing it has no side effects.
#
#   hmr_proxy_check_script <ssh dir>   print a bash script for the target: a
#       `dead <port> <line>` line for each active ProxyCommand in <ssh
#       dir>/config that sends ssh through a loopback proxy port nothing
#       listens on. rc 0 always. seed pipes it to `bash -s` on the target.
#   hmr_reach_host <bin dir>           the fleet box a tick dials:
#       HUB_MOVE_REACH_HOST, else the first `fleet-conf.sh --tailnet-ips`
#       address, else `-`.
#   hmr_reach_run <host> <flyctl|""> <timeout_s> <out file> <ssh config> [ssh opts...]
#       one `ssh root@<host> true` and one `<flyctl> version`. Sets HMR_SSH_RC,
#       HMR_FLY_RC (127: no flyctl) and HMR_PROXY (the ProxyCommand ssh uses
#       for <host>, or `none`). Both outputs go to <out file>.
#   hmr_c1_reach <tick table>          print why C1 refuses the table's reach,
#       or nothing when line 2 is `# reach ssh=0 flyctl=0 host=<h>`.
#
# THE INCIDENT (2026-10-23). bh-hub-2 had an Orgo ssh config with
# `ProxyCommand /usr/bin/nc -x 127.0.0.1:1055 %h %p` and no SOCKS listener on
# 1055. Every ssh to a fleet box failed. C1 and C6 never ran an ssh or a
# flyctl, so both passed, and the new hub built nothing for 3 h.

# The script reads only bash builtins (no cat, no grep), so it runs on a target
# with a bare PATH. A port is listening when `ss -ltnH "sport = :<port>"` prints
# a line; with no ss, when a /dev/tcp connect succeeds. With neither the port
# reads dead and seed refuses (fail closed). `-x HOST` with no port is nc's
# SOCKS default, 1080 (a protocol fact, not a knob).
hmr_proxy_check_script() {
  local dir="$1"
  cat <<EOF
cfg="$dir/config"
[ -f "\$cfg" ] || exit 0
hmr_listening() {
  if command -v ss >/dev/null 2>&1; then
    [ -n "\$(ss -ltnH "sport = :\$1" 2>/dev/null)" ]; return
  fi
  ( exec 3<>"/dev/tcp/127.0.0.1/\$1" ) 2>/dev/null
}
hmr_addr_port() { # stdout: the port of a loopback address, else nothing
  local a="\$1" h p=""
  case "\$a" in
    '['*']'*) h="\${a#[}"; h="\${h%%]*}"; p="\${a#*]}"; p="\${p#:}" ;;
    ::1) h="::1" ;;
    *:*) h="\${a%:*}"; p="\${a##*:}" ;;
    *) h="\$a" ;;
  esac
  case "\$h" in 127.*|localhost|::1) ;; *) return 0 ;; esac
  [ -n "\$p" ] || p=1080
  case "\$p" in *[!0-9]*) return 0 ;; esac
  printf '%s\n' "\$p"
}
while IFS= read -r line || [ -n "\$line" ]; do
  t="\${line#"\${line%%[![:space:]]*}"}"
  case "\$t" in '#'*|'') continue ;; esac
  shopt -s nocasematch
  if [[ "\$t" =~ ^proxycommand([[:space:]]*=[[:space:]]*|[[:space:]]+)(.*)\$ ]]; then m=0; else m=1; fi
  shopt -u nocasematch
  [ "\$m" -eq 0 ] || continue
  read -ra w <<<"\${BASH_REMATCH[2]}"
  i=0
  while [ "\$i" -lt "\${#w[@]}" ]; do
    a=""
    case "\${w[\$i]}" in
      -x|-S|--proxy) a="\${w[\$((i + 1))]:-}"; i=\$((i + 1)) ;;
      --proxy=*) a="\${w[\$i]#--proxy=}" ;;
      -x?*) a="\${w[\$i]#-x}" ;;
    esac
    i=\$((i + 1))
    [ -n "\$a" ] || continue
    p=\$(hmr_addr_port "\$a")
    [ -n "\$p" ] || continue
    hmr_listening "\$p" || printf 'dead %s %s\n' "\$p" "\$t"
  done
done < "\$cfg"
exit 0
EOF
}

hmr_reach_host() {
  local h="${HUB_MOVE_REACH_HOST:-}"
  [ -n "$h" ] || h=$("$1/fleet-conf.sh" --tailnet-ips 2>/dev/null | grep -vE '^(-|local)?$' | head -1)
  printf '%s\n' "${h:--}"
}

hmr_reach_run() {
  local host="$1" fly="$2" to="$3" out="$4" cfg="$5"
  shift 5
  HMR_SSH_RC=2; HMR_FLY_RC=127; HMR_PROXY=none
  : > "$out" 2>/dev/null || return 1
  if [ "$host" = - ]; then
    echo "ssh: no fleet box address (HUB_MOVE_REACH_HOST unset, fleet-conf.sh --tailnet-ips empty)" >> "$out"
  else
    echo "\$ ssh root@$host true" >> "$out"
    timeout -k 5 "$to" ssh "$@" "root@$host" true </dev/null >> "$out" 2>&1; HMR_SSH_RC=$?
    echo "rc=$HMR_SSH_RC" >> "$out"
  fi
  if [ -n "$fly" ]; then
    echo "\$ $fly version" >> "$out"
    timeout -k 5 "$to" "$fly" version </dev/null >> "$out" 2>&1; HMR_FLY_RC=$?
    echo "rc=$HMR_FLY_RC" >> "$out"
  else
    echo "flyctl: not found on this box" >> "$out"
  fi
  [ "$HMR_SSH_RC" -eq 0 ] && return 0
  # Why ssh failed: the ProxyCommand ssh resolves for the host (it follows
  # Include), else the first active one in the config file.
  local p=""
  if [ "$host" != - ]; then
    p=$(timeout -k 5 "$to" ssh -G "$host" </dev/null 2>/dev/null | grep -i '^proxycommand ' | grep -vi '^proxycommand none$' | head -1)
  fi
  [ -n "$p" ] || p=$(grep -iE '^[[:space:]]*proxycommand([[:space:]]|=)' "$cfg" 2>/dev/null | grep -viE 'proxycommand[[:space:]=]+none[[:space:]]*$' | head -1 | sed 's/^[[:space:]]*//')
  HMR_PROXY="${p:-none}"
  { echo "ssh config: $cfg"; echo "ProxyCommand: $HMR_PROXY"; } >> "$out"
  return 0
}

hmr_c1_reach() {
  local f="$1" l1 l2 s fl
  l1=$(sed -n 1p "$f" 2>/dev/null)
  case "$l1" in
    "# mode="*"-reach-failed "*) ;;
    "# mode=nowrite at="*) ;;
    *) return 0 ;;   # the header check names any other table
  esac
  l2=$(sed -n 2p "$f" 2>/dev/null)
  if [[ "$l2" =~ ^\#\ reach\ ssh=([0-9]+)\ flyctl=([0-9]+)\ host=([^[:space:]]+)$ ]]; then
    s="${BASH_REMATCH[1]}"; fl="${BASH_REMATCH[2]}"
    case "$l1" in *-reach-failed*) ;; *) [ "$s" = 0 ] && [ "$fl" = 0 ] && return 0 ;; esac
    printf '%s\n' "ssh=$s flyctl=$fl host=${BASH_REMATCH[3]}"
    return 0
  fi
  printf '%s\n' "no reach line (line 2 is not \`# reach ssh=<rc> flyctl=<rc> host=<h>\`)"
}
