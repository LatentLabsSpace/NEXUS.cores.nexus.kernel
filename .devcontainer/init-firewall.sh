#!/bin/bash
set -euo pipefail  # Exit on error, undefined vars, and pipeline failures
IFS=$'\n\t'       # Stricter word splitting

# One-shot per container start. The rules and ipsets live in this container's
# network namespace, which a restart recreates, so every boot starts clean. Once
# a boot has COMPLETED (marker ipset below, created last), any later invocation
# is a no-op: a devcontainer postStartCommand, or an agent re-running this via
# the node sudo rule with its own module choices, can never widen egress after
# boot. A run that failed part-way leaves no marker, so it can be retried.
if ipset list -n kernel-firewall-done >/dev/null 2>&1; then
    echo "Firewall already initialized for this container start; not re-applying."
    exit 0
fi

# 1. Extract Docker DNS info BEFORE any flushing
DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)

# Reset default policies to ACCEPT before flushing so that re-runs
# don't inherit the previous DROP policy while rebuilding rules.
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT

# Flush existing rules and delete existing ipsets
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true

# 2. Selectively restore ONLY internal Docker DNS resolution
if [ -n "$DOCKER_DNS_RULES" ]; then
    echo "Restoring Docker DNS rules..."
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
else
    echo "No Docker DNS rules to restore"
fi

# First allow DNS and localhost before any restrictions
# Allow outbound DNS
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
# Allow inbound DNS responses
iptables -A INPUT -p udp --sport 53 -j ACCEPT
# Allow outbound SSH
iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT
# Allow inbound SSH responses
iptables -A INPUT -p tcp --sport 22 -m state --state ESTABLISHED -j ACCEPT
# Allow localhost
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Create ipset with CIDR support
ipset create allowed-domains hash:net

DROPIN_DIR="$(dirname "$0")/firewall.d"

# Load universal kernel domains. Both tiers are selected per module by
# FIREWALL_KERNEL_MODULES (default: all); the tiers differ only in what a DNS
# miss does to a SELECTED module:
#
#   _required/  hard-fail: a DNS miss aborts the boot (github, npm).
#   _optional/  warn-and-skip: a DNS miss logs a warning and continues.
#
#   FIREWALL_KERNEL_MODULES:
#     all           every kernel module, both tiers (the default)
#     none          no kernel modules
#     a,b           allowlist: only these modules
#     all,-a,-b     every module except these (`-a` alone implies all)
#   Module names are the .conf basenames ([a-z0-9-]); invalid or unknown names
#   warn and are ignored. Deselecting `github` also skips the GitHub meta IP
#   ranges and the LFS S3 supernets, which exist only for GitHub.
#
# Keep _required/ minimal. A domain listed there is a boot-blocker for every
# downstream consumer the day its DNS changes; statsig.anthropic.com went
# NXDOMAIN in July 2026 and bricked consumer boots for exactly that reason.
REQUIRED_DOMAINS=()
OPTIONAL_DOMAINS=()
# Membership/joins done explicitly: this script runs with IFS=$'\n\t', so
# "${arr[*]}" joins with newlines and string-match membership tests break.
_contains() { local _n="$1" _x; shift; for _x in "$@"; do [ "$_x" = "$_n" ] && return 0; done; return 1; }
_join() { local IFS=' '; echo "$*"; }
_kernel_sel="${FIREWALL_KERNEL_MODULES:-all}"
_kernel_sel="${_kernel_sel// /}"
_kmode=""; _kinclude=(); _kexclude=()
IFS=',' read -ra _ktokens <<< "$_kernel_sel"
_valid_module() { [[ "$1" =~ ^[a-z0-9][a-z0-9-]*$ ]]; }
for _t in "${_ktokens[@]}"; do
    case "$_t" in
        "")   ;;
        all)  [ "$_kmode" = none ] || _kmode=all ;;
        none) _kmode=none ;;
        -*)   if _valid_module "${_t#-}"; then _kexclude+=("${_t#-}"); else echo "WARN: FIREWALL_KERNEL_MODULES: invalid module name '${_t#-}' ignored"; fi ;;
        *)    if _valid_module "$_t"; then _kinclude+=("$_t"); else echo "WARN: FIREWALL_KERNEL_MODULES: invalid module name '$_t' ignored"; fi ;;
    esac
done
if [ "$_kmode" = none ] && { [ ${#_kinclude[@]} -gt 0 ] || [ ${#_kexclude[@]} -gt 0 ]; }; then
    echo "WARN: FIREWALL_KERNEL_MODULES='$_kernel_sel' mixes 'none' with module names; honoring 'none'"
fi
if [ -z "$_kmode" ]; then
    # Bare exclusions ("-vscode") mean "all minus these"; bare names are an allowlist.
    if [ ${#_kinclude[@]} -eq 0 ]; then _kmode=all; else _kmode=list; fi
elif [ "$_kmode" = all ] && [ ${#_kinclude[@]} -gt 0 ]; then
    echo "WARN: FIREWALL_KERNEL_MODULES='$_kernel_sel': names next to 'all' are redundant; loading all"
fi
if [ "$_kmode" = list ] && [ ${#_kexclude[@]} -gt 0 ]; then
    echo "WARN: FIREWALL_KERNEL_MODULES='$_kernel_sel': exclusions have no effect on an allowlist"
fi
_kavailable=(); _krequired=()
for _conf in "$DROPIN_DIR/_required"/*.conf; do
    [ -f "$_conf" ] && _kavailable+=("$(basename "$_conf" .conf)") && _krequired+=("$(basename "$_conf" .conf)")
done
for _conf in "$DROPIN_DIR/_optional"/*.conf; do
    [ -f "$_conf" ] && _kavailable+=("$(basename "$_conf" .conf)")
done
for _name in "${_kinclude[@]}" "${_kexclude[@]}"; do
    _contains "$_name" "${_kavailable[@]}" || \
        echo "WARN: FIREWALL_KERNEL_MODULES names unknown kernel module '$_name' (available: $(_join "${_kavailable[@]}"))"
done
_kloaded=(); _kskipped=()
for _name in "${_kavailable[@]}"; do
    _want=false
    case "$_kmode" in
        all)  _want=true ;;
        list) _contains "$_name" "${_kinclude[@]}" && _want=true ;;
    esac
    _contains "$_name" "${_kexclude[@]}" && _want=false
    if ! $_want; then _kskipped+=("$_name"); continue; fi
    _kloaded+=("$_name")
    if _contains "$_name" "${_krequired[@]}"; then _tier=_required; else _tier=_optional; fi
    while IFS= read -r _line || [ -n "$_line" ]; do
        _line="${_line%%#*}"; _line="${_line// /}"
        [ -z "$_line" ] && continue
        if [ "$_tier" = _required ]; then REQUIRED_DOMAINS+=("$_line"); else OPTIONAL_DOMAINS+=("$_line"); fi
    done < "$DROPIN_DIR/$_tier/$_name.conf"
done
echo "Kernel modules (FIREWALL_KERNEL_MODULES=$_kernel_sel): loaded [$(_join "${_kloaded[@]}")] skipped [$(_join "${_kskipped[@]}")] (required tier: $(_join "${_krequired[@]}"))"

if _contains github "${_kloaded[@]}"; then
    # Fetch GitHub meta information and aggregate + add their IP ranges
    echo "Fetching GitHub IP ranges..."
    gh_ranges=""
    for attempt in 1 2 3 4 5; do
        gh_ranges=$(curl -s --connect-timeout 5 --retry 0 https://api.github.com/meta)
        [ -n "$gh_ranges" ] && break
        echo "Attempt $attempt failed, retrying in 3s..."
        sleep 3
    done
    if [ -z "$gh_ranges" ]; then
        echo "ERROR: Failed to fetch GitHub IP ranges after 5 attempts"
        exit 1
    fi

    if ! echo "$gh_ranges" | jq -e '.web and .api and .git' >/dev/null; then
        echo "ERROR: GitHub API response missing required fields"
        exit 1
    fi

    echo "Processing GitHub IPs..."
    while read -r cidr; do
        if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
            echo "ERROR: Invalid CIDR range from GitHub meta: $cidr"
            exit 1
        fi
        echo "Adding GitHub range $cidr"
        ipset add -exist allowed-domains "$cidr"
    done < <(echo "$gh_ranges" | jq -r '(.web + .api + .git)[]' | aggregate -q)

    # GitHub LFS uses S3 (github-cloud.s3.amazonaws.com) which rotates IPs
    # across many AWS /16 blocks. DNS-based resolution is insufficient because
    # S3 returns different IPs on every request. We hardcode the /16 supernets
    # that cover known GitHub LFS storage IPs.
    #
    # Security tradeoff: this opens ~327k IPs across 5 AWS S3 /16 blocks,
    # making any S3 endpoint in those ranges reachable on port 443. However:
    #   - Write access to S3 requires AWS credentials (the agent has none)
    #   - Read access to public buckets is low-severity vs the GitHub API
    #     access already allowed
    #   - This is required for agents to push LFS-tracked files (images, etc.)
    # If this surface is no longer acceptable, set GIT_LFS_SKIP_PUSH=1 and
    # push LFS objects from a machine outside the firewall.
    echo "Adding S3 ranges for GitHub LFS..."
    for cidr in 3.5.0.0/16 16.15.0.0/16 52.216.0.0/16 52.217.0.0/16 54.231.0.0/16; do
        ipset add -exist allowed-domains "$cidr"
    done
    echo "Added S3 supernets for LFS"
else
    echo "github module not selected: skipping GitHub meta IP ranges and LFS S3 supernets"
fi

# Load project-specific domains from drop-in directory.
# If FIREWALL_MODULES is set, only load the named modules (comma-separated,
# without .conf suffix). If unset or "all", load every .conf file found.
if [ -d "$DROPIN_DIR" ]; then
    if [ "${FIREWALL_MODULES:-}" = "none" ]; then
        echo "FIREWALL_MODULES=none — skipping all drop-in modules"
    elif [ -n "${FIREWALL_MODULES:-}" ] && [ "$FIREWALL_MODULES" != "all" ]; then
        # Selective: only load explicitly requested modules
        IFS=',' read -ra _fw_modules <<< "$FIREWALL_MODULES"
        for mod in "${_fw_modules[@]}"; do
            mod="${mod// /}"  # strip whitespace
            [ -z "$mod" ] && continue
            if ! [[ "$mod" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
                echo "WARN: FIREWALL_MODULES: invalid module name '${mod}' ignored"
                continue
            fi
            conf="$DROPIN_DIR/${mod}.conf"
            if [ ! -f "$conf" ]; then
                if [ -f "$DROPIN_DIR/_optional/${mod}.conf" ]; then
                    echo "WARN: '${mod}' is a kernel module (firewall.d/_optional/${mod}.conf); it is selected by FIREWALL_KERNEL_MODULES, not FIREWALL_MODULES — ignoring it here"
                else
                    echo "WARN: Requested firewall module '${mod}' not found at $conf, skipping"
                fi
                continue
            fi
            while IFS= read -r line || [ -n "$line" ]; do
                line="${line%%#*}"
                line="${line// /}"
                [ -z "$line" ] && continue
                echo "Loading domain from ${mod}.conf: $line"
                OPTIONAL_DOMAINS+=("$line")
            done < "$conf"
        done
    else
        # Default: load all .conf files
        for conf in "$DROPIN_DIR"/*.conf; do
            [ -f "$conf" ] || continue
            while IFS= read -r line || [ -n "$line" ]; do
                line="${line%%#*}"
                line="${line// /}"
                [ -z "$line" ] && continue
                echo "Loading domain from $(basename "$conf"): $line"
                OPTIONAL_DOMAINS+=("$line")
            done < "$conf"
        done
    fi
fi

ALL_DOMAINS=("${REQUIRED_DOMAINS[@]}" "${OPTIONAL_DOMAINS[@]}")
for domain in "${ALL_DOMAINS[@]}"; do
    echo "Resolving $domain..."
    ips=$(dig +noall +answer A "$domain" | awk '$4 == "A" {print $5}')
    if [ -z "$ips" ]; then
        is_required=false
        for rd in "${REQUIRED_DOMAINS[@]}"; do
            [[ "$rd" == "$domain" ]] && is_required=true && break
        done
        if $is_required; then
            echo "ERROR: Failed to resolve required domain $domain"
            exit 1
        else
            echo "WARN: Failed to resolve $domain, skipping"
            continue
        fi
    fi
    
    while read -r ip; do
        if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            echo "ERROR: Invalid IP from DNS for $domain: $ip"
            exit 1
        fi
        echo "Adding $ip for $domain"
        ipset add -exist allowed-domains "$ip"
    done < <(echo "$ips")
done

# Get host IP from default route
HOST_IP=$(ip route | grep default | cut -d" " -f3)
if [ -z "$HOST_IP" ]; then
    echo "ERROR: Failed to detect host IP"
    exit 1
fi

HOST_NETWORK=$(echo "$HOST_IP" | sed "s/\.[0-9]*$/.0\/24/")
echo "Host network detected as: $HOST_NETWORK"

# Set up remaining iptables rules
iptables -A INPUT -s "$HOST_NETWORK" -j ACCEPT
iptables -A OUTPUT -d "$HOST_NETWORK" -j ACCEPT

# --- Compose-network peers -------------------------------------------------
# Sibling services (the beads server, a database, any compose service reached
# by DNS alias) live on RFC1918 addresses that the domain allowlist above
# cannot express: they have no public name to resolve, and their addresses are
# assigned per-`docker compose up`.
#
# The HOST_NETWORK rule above covers only the gateway's /24, which is NOT the
# whole network. Docker's default address pool hands out /16 subnets, so a peer
# at 172.20.0.x is reachable while an otherwise identical peer at 172.20.5.x is
# dropped — a silent, address-assignment-dependent failure that surfaces as a
# client hang. Measured on the kernel firewall before this rule existed:
# 172.31.0.9 -> 172.31.5.5:3307 on a /16 compose network failed with "No route
# to host" while the same pair inside the gateway /24 succeeded.
#
# So: allow the networks this container is ACTUALLY attached to, derived from
# its own interfaces. Scope is deliberately narrow — the container's own docker
# networks, nothing else. It does not open the host LAN or the internet, and it
# grants no reachability a compose peer on the gateway /24 didn't already have.
# Set FIREWALL_ALLOW_LOCAL_NETWORKS=0 to opt out (a container that must not talk
# to its own compose siblings at all).
#
# Not a `firewall.d/` drop-in: those tiers describe DNS-resolvable domains and
# differ only in resolution-failure semantics. This is a link-layer fact about
# the container, so it is always applied and warns (never aborts) if the
# interface list can't be read.
_cidr_network() {
    local cidr="$1"
    local addr="${cidr%%/*}"
    local bits="${cidr##*/}"
    local o1 o2 o3 o4
    IFS=. read -r o1 o2 o3 o4 <<< "$addr"
    local ipnum=$(( (o1 << 24) | (o2 << 16) | (o3 << 8) | o4 ))
    local mask=$(( bits == 0 ? 0 : (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
    local net=$(( ipnum & mask ))
    echo "$(( (net >> 24) & 255 )).$(( (net >> 16) & 255 )).$(( (net >> 8) & 255 )).$(( net & 255 ))/$bits"
}

if [ "${FIREWALL_ALLOW_LOCAL_NETWORKS:-1}" = "0" ]; then
    echo "FIREWALL_ALLOW_LOCAL_NETWORKS=0 — skipping compose-network allowance"
else
    _local_cidrs=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' || true)
    if [ -z "$_local_cidrs" ]; then
        echo "WARN: no global-scope IPv4 addresses found; skipping compose-network allowance"
    fi
    for _cidr in $_local_cidrs; do
        if [[ ! "$_cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
            echo "WARN: unparseable interface CIDR '$_cidr', skipping"
            continue
        fi
        _net=$(_cidr_network "$_cidr")
        echo "Allowing container network $_net (from interface $_cidr)"
        iptables -A INPUT -s "$_net" -j ACCEPT
        iptables -A OUTPUT -d "$_net" -j ACCEPT
    done
fi

# Set default policies to DROP first
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# First allow established connections for already approved traffic
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Then allow only specific outbound traffic to allowed domains
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT

# Explicitly REJECT all other outbound traffic for immediate feedback
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

echo "Firewall configuration complete"
echo "Verifying firewall rules..."
if curl --connect-timeout 5 https://example.com >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - was able to reach https://example.com"
    exit 1
else
    echo "Firewall verification passed - unable to reach https://example.com as expected"
fi

# Verify GitHub API access
if ! _contains github "${_kloaded[@]}"; then
    echo "Firewall verification: github module not selected, skipping the GitHub reachability check"
elif ! curl --connect-timeout 5 https://api.github.com/zen >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - unable to reach https://api.github.com"
    exit 1
else
    echo "Firewall verification passed - able to reach https://api.github.com as expected"
fi

# Completion marker — see the one-shot guard at the top. Created only after the
# DROP policies are in place and verification passed.
ipset create kernel-firewall-done hash:ip
echo "Firewall configuration locked for this container start"
