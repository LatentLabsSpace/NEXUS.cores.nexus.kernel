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
