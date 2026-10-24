#!/usr/bin/env bash
# Firewall regression matrix: runs init-firewall.sh in throwaway containers and
# checks which egress paths are open, for the default policy and for a locked-down
# one (FIREWALL_ALLOW_SSH=0, FIREWALL_ALLOW_HOST_NETWORK=0,
# FIREWALL_ALLOW_LOCAL_NETWORKS=0), on the default bridge and on a user-defined
# network (Docker's 127.0.0.11 resolver).
#
# Usage, from the host, with Docker:
#   cores/nexus/kernel/.devcontainer/tests/firewall-matrix.sh <kernel image> [drop-in dir]
# <kernel image> is any image built from this kernel (it supplies iptables, ipset and
# dig); the script under test comes from this checkout, mounted read-only. [drop-in dir]
# adds a consumer's firewall.d drop-ins (e.g. a discord.conf) to the module set.
# Needs network access to github.com, api.anthropic.com and example.com.
# Exit status: 0 when every probe matches its expectation.
set -uo pipefail

IMAGE="${1:?usage: $0 <kernel image> [drop-in dir]}"
DROPINS="${2:-}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"   # the .devcontainer directory
NET="fw-matrix-$$"
fail=0

inner() {
  cat <<'EOS'
set -u
mkdir -p /opt/fw && cp -r /src/init-firewall.sh /src/firewall-lib.sh /src/firewall.d /opt/fw/
[ -d /dropins ] && cp /dropins/*.conf /opt/fw/firewall.d/ 2>/dev/null
chmod +x /opt/fw/init-firewall.sh
/opt/fw/init-firewall.sh >/tmp/fw.log 2>&1 || { echo "init FAILED"; tail -5 /tmp/fw.log; exit 2; }
GW=$(ip route | awk '/default/{print $3}')
tcp(){ timeout 6 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null && echo open || echo blocked; }
echo "ssh_github $(tcp github.com 22)"
echo "gateway_22 $(tcp "$GW" 22)"
echo "https_github $(tcp github.com 443)"
echo "https_anthropic $(tcp api.anthropic.com 443)"
echo "https_example $(tcp example.com 443)"
echo "dns_resolver $(getent hosts github.com >/dev/null && echo open || echo blocked)"
echo "dns_direct_udp $(dig @8.8.8.8 example.com +time=3 +tries=1 +short >/dev/null 2>&1 && dig @8.8.8.8 example.com +time=3 +tries=1 +short | grep -q . && echo open || echo blocked)"
EOS
}

run_case() {
  local label="$1" net="$2" expect="$3"; shift 3
  local args=(--rm --user root --cap-add NET_ADMIN --cap-add NET_RAW
    -e FIREWALL_MODULES="${DROPINS:+all}" -e FIREWALL_KERNEL_MODULES=github,anthropic
    -v "$HERE:/src:ro")
  [ -z "$DROPINS" ] && args+=(-e FIREWALL_MODULES=none)
  [ -n "$DROPINS" ] && args+=(-v "$DROPINS:/dropins:ro")
  [ -n "$net" ] && args+=(--network "$net")
  local out
  out=$(docker run "${args[@]}" "$@" --entrypoint bash "$IMAGE" -c "$(inner)" 2>&1)
  echo "=== $label"
  local probe want got
  for pair in $expect; do
    probe="${pair%%=*}"; want="${pair##*=}"
    got=$(echo "$out" | awk -v p="$probe" '$1==p{print $2}')
    if [ "$got" = "$want" ]; then
      echo "  ok    $probe: $got"
    else
      echo "  FAIL  $probe: got '${got:-none}', want $want"; fail=1
    fi
  done
}

LOCKED=(-e FIREWALL_ALLOW_SSH=0 -e FIREWALL_ALLOW_HOST_NETWORK=0 -e FIREWALL_ALLOW_LOCAL_NETWORKS=0)
# github and anthropic are selected kernel modules in every case (the "required" tier only
# means a resolution failure aborts; a module still has to be selected).
EXP_LOCKED="ssh_github=blocked gateway_22=blocked https_github=open https_anthropic=open https_example=blocked dns_resolver=open dns_direct_udp=blocked"
EXP_DEFAULT="ssh_github=open gateway_22=open https_github=open https_anthropic=open https_example=blocked dns_resolver=open dns_direct_udp=blocked"

docker network create "$NET" >/dev/null
trap 'docker network rm "$NET" >/dev/null 2>&1' EXIT

run_case "locked, default bridge" "" "$EXP_LOCKED" "${LOCKED[@]}"
run_case "locked, user-defined network" "$NET" "$EXP_LOCKED" "${LOCKED[@]}"
run_case "default policy, default bridge" "" "$EXP_DEFAULT"

[ "$fail" = 0 ] && echo "ALL OK" || echo "FAILURES"
exit "$fail"
