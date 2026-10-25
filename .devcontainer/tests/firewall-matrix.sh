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

# --- FIREWALL_ALLOW_PEERS ----------------------------------------------------
# A locked container (no local networks) allowed exactly one peer port, by IPv4
# literal (names are refused: a DNS answer must never open the private space).
# Two pinned networks: A (gateway .1, the default route) and B with a CUSTOM
# gateway at .254 that the container can't see. "peera" (A, .10) listens on 8080
# and 9090, "other" (A, .11) on 8080. Then peera is recreated at its pinned address.
peers_case() {
  local na="fw-peers-a-$$" nb="fw-peers-b-$$" fw="fw-peers-test-$$"
  local serve='python3 -m http.server 8080 >/dev/null 2>&1 & python3 -m http.server 9090 >/dev/null 2>&1 & wait'
  docker network create --subnet 172.31.240.0/24 --gateway 172.31.240.1 "$na" >/dev/null
  docker network create --subnet 172.31.241.0/24 --gateway 172.31.241.254 "$nb" >/dev/null
  docker run -d --rm --name "$fw-peera" --network "$na" --ip 172.31.240.10 --network-alias peera --entrypoint bash "$IMAGE" -c "$serve" >/dev/null
  docker run -d --rm --name "$fw-other" --network "$na" --ip 172.31.240.11 --entrypoint bash "$IMAGE" -c "$serve" >/dev/null
  docker create --rm --name "$fw" --user root --cap-add NET_ADMIN --cap-add NET_RAW --network "$na" \
    -e FIREWALL_MODULES=none -e FIREWALL_KERNEL_MODULES=github,anthropic -e FIREWALL_ALLOW_SSH=0 \
    -e FIREWALL_ALLOW_HOST_NETWORK=0 -e FIREWALL_ALLOW_LOCAL_NETWORKS=0 \
    -e FIREWALL_ALLOW_PEERS="172.31.240.10:8080@172.31.240.1,peera:8080@172.31.240.1,172.31.241.254:8080@172.31.241.254,172.31.241.254:8080,172.31.240.11:8080@172.31.241.254,172.31.240.1:8080@172.31.240.1,172.31.240.0:8080@172.31.240.1,8.8.8.8:53@172.31.240.1,172.31.240.10:notaport@172.31.240.1" \
    -v "$HERE:/src:ro" --entrypoint bash "$IMAGE" -c '
      mkdir -p /opt/fw && cp -r /src/init-firewall.sh /src/firewall-lib.sh /src/firewall.d /opt/fw/ && chmod +x /opt/fw/init-firewall.sh
      /opt/fw/init-firewall.sh >/tmp/fw.log 2>&1 && touch /tmp/fw.ok; sleep infinity' >/dev/null
  docker network connect "$nb" "$fw"
  docker start "$fw" >/dev/null
  for _ in $(seq 1 60); do docker exec "$fw" test -e /tmp/fw.ok 2>/dev/null && break; sleep 1; done
  probe() {  # probe host port -> open|blocked
    docker exec "$fw" bash -c "timeout 4 bash -c 'exec 3<>/dev/tcp/$1/$2' 2>/dev/null && echo open || echo blocked"
  }
  check() {  # check label got want
    if [ "$2" = "$3" ]; then echo "  ok    $1: $2"; else echo "  FAIL  $1: got '$2', want $3"; fail=1; fi
  }
  logcount() { docker exec "$fw" grep -c -- "$1" /tmp/fw.log; }
  echo "=== peers: FIREWALL_ALLOW_PEERS=172.31.240.10:8080@172.31.240.1 on a locked container (two networks)"
  check "init" "$(docker exec "$fw" test -e /tmp/fw.ok && echo ok || echo failed)" ok
  check "peer_8080" "$(probe 172.31.240.10 8080)" open
  check "peer_9090" "$(probe 172.31.240.10 9090)" blocked
  check "other_8080" "$(probe 172.31.240.11 8080)" blocked
  check "gateway_a" "$(probe 172.31.240.1 8080)" blocked
  check "custom_gateway_b" "$(probe 172.31.241.254 8080)" blocked
  check "rules" "$(docker exec "$fw" iptables -S FW_PEERS | grep -c -- '-j ACCEPT')" 1
  check "name_refused" "$(logcount "peer 'peera:8080@172.31.240.1' is not ipv4:port@gateway")" 1
  check "custom_gateway_as_peer_refused" "$(logcount "peer 172.31.241.254 (gateway 172.31.241.254)")" 1
  check "missing_gateway_refused" "$(logcount "peer '172.31.241.254:8080' is not ipv4:port@gateway")" 1
  check "gateway_on_other_network_refused" "$(logcount "peer 172.31.240.11 (gateway 172.31.241.254)")" 1
  check "default_gateway_refused" "$(logcount "peer 172.31.240.1 (gateway 172.31.240.1)")" 1
  check "network_address_refused" "$(logcount "peer 172.31.240.0 (gateway")" 1
  check "public_refused" "$(logcount "peer 8.8.8.8 (gateway")" 1
  check "bad_port_refused" "$(logcount "peer '172.31.240.10:notaport@172.31.240.1' is not")" 1
  # Recreate peera at its pinned address: the rule still applies, nothing to follow.
  docker rm -f "$fw-peera" >/dev/null
  docker run -d --rm --name "$fw-peera" --network "$na" --ip 172.31.240.10 --entrypoint bash "$IMAGE" -c "$serve" >/dev/null
  sleep 2
  check "peer_8080_after_recreate" "$(probe 172.31.240.10 8080)" open
  docker rm -f "$fw" "$fw-peera" "$fw-other" >/dev/null 2>&1
  docker network rm "$na" "$nb" >/dev/null 2>&1
}
peers_case

[ "$fail" = 0 ] && echo "ALL OK" || echo "FAILURES"
exit "$fail"
