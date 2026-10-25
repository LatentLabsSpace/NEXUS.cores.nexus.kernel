# firewall-lib.sh: helpers shared by init-firewall.sh (boot) and firewall-refresh.
# Sourced, never executed. Root-owned in the image (/usr/local/bin/firewall-lib.sh).

# fw_valid_domain NAME: allowlist entries must be plain hostnames. This also
# stops a conf line starting with "-" from reaching dig as an option
# (e.g. "-f/path" would make root read that file).
fw_valid_domain() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]]
}

# fw_started_by_pid1: true when this process descends from the container's
# PID 1 (an entrypoint or firewall-exec), false under `docker exec` (e.g. a
# devcontainer postStartCommand), whose process tree tops out at ppid 0.
# Reads /proc/<pid>/stat, which needs no ptrace rights.
fw_started_by_pid1() {
    local p=$PPID n=0 st
    while [ "$p" -gt 1 ] && [ "$n" -lt 64 ]; do
        st=$(cat "/proc/$p/stat" 2>/dev/null) || return 1
        st=${st##*) }                       # drop "pid (comm) "; comm may hold spaces
        p=${st#* }; p=${p%% *}              # field after state = ppid
        [[ "$p" =~ ^[0-9]+$ ]] || return 1
        n=$((n + 1))
    done
    [ "$p" = 1 ]
}

# fw_public_ipv4 IP: true only for a dotted quad in public unicast space.
# A DNS answer must never allow private, loopback, link-local (169.254.169.254
# is the cloud metadata service), CGNAT, benchmark, multicast or reserved
# space, whether the answer is poisoned or a drop-in domain rebinds.
# (Compose-network peers are allowed separately by interface, not by DNS.)
fw_public_ipv4() {
    local ip=$1 a b c d
    [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    a=$((10#${BASH_REMATCH[1]})); b=$((10#${BASH_REMATCH[2]}))
    c=$((10#${BASH_REMATCH[3]})); d=$((10#${BASH_REMATCH[4]}))
    (( a <= 255 && b <= 255 && c <= 255 && d <= 255 )) || return 1
    (( a == 0 || a == 10 || a == 127 )) && return 1            # this-net, private, loopback
    (( a >= 224 )) && return 1                                  # multicast, reserved, broadcast
    (( a == 100 && b >= 64 && b <= 127 )) && return 1           # 100.64/10 CGNAT
    (( a == 169 && b == 254 )) && return 1                      # link-local, cloud metadata
    (( a == 172 && b >= 16 && b <= 31 )) && return 1            # 172.16/12
    (( a == 192 && b == 168 )) && return 1                      # 192.168/16
    (( a == 192 && b == 0 && c == 0 )) && return 1              # 192.0.0/24 IETF
    (( a == 192 && b == 0 && c == 2 )) && return 1              # TEST-NET-1
    (( a == 198 && (b == 18 || b == 19) )) && return 1          # 198.18/15 benchmark
    (( a == 198 && b == 51 && c == 100 )) && return 1           # TEST-NET-2
    (( a == 203 && b == 0 && c == 113 )) && return 1            # TEST-NET-3
    return 0
}

# --- Compose peers (FIREWALL_ALLOW_PEERS) ------------------------------------
# A narrow exception for a container that runs with FIREWALL_ALLOW_LOCAL_NETWORKS=0
# but must reach ONE sibling service: "ip:port@gateway[,...]". IPv4 literals only,
# never names: a name resolves through Docker's DNS, which forwards unknown names
# upstream, so a peer that is down could be answered by any resolver with, say,
# a gateway address, and a container can't see a non-default network's gateway.
# The peer's address is pinned in compose (ipv4_address on a network whose
# subnet and gateway are pinned too), so it comes only from trusted config.
# A container can't discover a non-default network's gateway (no route names it,
# and compose can put it anywhere in the subnet), so the gateway is an explicit,
# trusted input: "@gateway", the network's gateway as pinned in compose. An entry
# without it is refused. Each peer must be private and inside one of this
# container's OWN attached subnets, with the declared gateway in that same
# subnet, and must not be the declared gateway, the default gateway, that
# network's first host (Docker's default gateway), its network or broadcast
# address, or this container's own address. One rule per peer: TCP to that port
# only, in FW_PEERS. Anything else is skipped with a warning (fail closed).

# fw_ip2int IP -> 32-bit integer
fw_ip2int() {
    local o1 o2 o3 o4
    IFS=. read -r o1 o2 o3 o4 <<< "$1"
    echo $(( (10#$o1 << 24) | (10#$o2 << 16) | (10#$o3 << 8) | 10#$o4 ))
}

# fw_valid_ipv4 IP: a dotted quad with octets <= 255
fw_valid_ipv4() {
    [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    (( 10#${BASH_REMATCH[1]} <= 255 && 10#${BASH_REMATCH[2]} <= 255 \
       && 10#${BASH_REMATCH[3]} <= 255 && 10#${BASH_REMATCH[4]} <= 255 ))
}

# fw_valid_peer IP:PORT@GATEWAY
fw_valid_peer() {
    local gw=${1##*@} rest=${1%@*} ip port
    [ "$gw" != "$1" ] || return 1                    # gateway is required
    ip=${rest%:*}; port=${rest##*:}
    [ "$ip" != "$rest" ] || return 1
    fw_valid_ipv4 "$ip" && fw_valid_ipv4 "$gw" || return 1
    [[ "$port" =~ ^[0-9]{1,5}$ ]] && (( 10#$port >= 1 && 10#$port <= 65535 ))
}

# fw_peer_ip_ok IP DECLARED_GW: private, inside an attached subnet that also
# holds DECLARED_GW, not a gateway (declared or default), network, broadcast or
# own address.
fw_peer_ip_ok() {
    local ip=$1 dgw=$2 cidr addr bits n_ip n_gw n_addr mask net gw
    fw_public_ipv4 "$ip" && return 1                 # peers are private by definition
    [ -n "$dgw" ] && [ "$ip" != "$dgw" ] || return 1 # never the declared gateway
    n_ip=$(fw_ip2int "$ip"); n_gw=$(fw_ip2int "$dgw")
    while read -r gw; do
        [ -n "$gw" ] && [ "$gw" = "$ip" ] && return 1
    done < <(ip -4 route show 2>/dev/null | awk '$1 == "default" {print $3}')
    while read -r cidr; do
        [[ "$cidr" =~ ^([0-9]{1,3}(\.[0-9]{1,3}){3})/([0-9]{1,2})$ ]] || continue
        addr=${BASH_REMATCH[1]}; bits=${BASH_REMATCH[3]}
        [ "$addr" = "$ip" ] && return 1              # this container itself
        (( bits >= 8 && bits <= 30 )) || continue
        n_addr=$(fw_ip2int "$addr")
        mask=$(( (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
        net=$(( n_addr & mask ))
        if (( (n_ip & mask) == net )); then
            (( (n_gw & mask) == net )) || return 1                             # gateway on another network
            (( n_ip == net || n_ip == net + 1 )) && return 1                    # network, first host
            (( n_ip == (net | (~mask & 0xFFFFFFFF)) )) && return 1              # broadcast
            return 0
        fi
    done < <(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}')
    return 1
}

# fw_peers_apply "ip:port@gateway,..." [logfn]: rebuild FW_PEERS. One line per decision
# through logfn (default: echo). Requires the FW_PEERS chain to exist.
fw_peers_apply() {
    local spec=$1 logfn=${2:-echo} entry ip port gw rest n=0
    iptables -F FW_PEERS 2>/dev/null || return 1
    [ -n "$spec" ] || return 0
    IFS=, read -ra _fw_peer_entries <<< "$spec"
    for entry in "${_fw_peer_entries[@]}"; do
        entry=${entry//[[:space:]]/}
        [ -n "$entry" ] || continue
        if ! fw_valid_peer "$entry"; then
            "$logfn" "WARN: peer '$entry' is not ipv4:port@gateway (names are not accepted, the gateway is required); skipped"
            continue
        fi
        gw=${entry##*@}; rest=${entry%@*}
        ip=${rest%:*}; port=$((10#${rest##*:}))
        if fw_peer_ip_ok "$ip" "$gw"; then
            iptables -A FW_PEERS -d "$ip" -p tcp --dport "$port" -j ACCEPT && n=$((n + 1))
        else
            "$logfn" "WARN: peer $ip (gateway $gw) is not a private address on one of this container's own networks with that gateway, or is a gateway, network, broadcast or own address; skipped"
        fi
    done
    "$logfn" "peers: $n rule(s) for '${spec}'"
}
