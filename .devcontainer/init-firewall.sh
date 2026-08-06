#!/bin/bash
set -euo pipefail  # Exit on error, undefined vars, and pipeline failures
IFS=$'\n\t'       # Stricter word splitting

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

DROPIN_DIR="$(dirname "$0")/firewall.d"

# Load universal kernel domains. Both directories are always loaded,
# regardless of FIREWALL_MODULES — they differ only in failure semantics:
#
#   _required/  hard-fail: a DNS miss aborts the boot. Reserve this for
#               domains without which the container is genuinely unusable.
#   _optional/  warn-and-skip: a DNS miss logs a warning and continues.
#               Everything else — telemetry, marketplaces, package indexes.
#
# Keep _required/ minimal. A domain listed there is a boot-blocker for every
# downstream consumer the day its DNS changes; statsig.anthropic.com went
# NXDOMAIN in July 2026 and bricked consumer boots for exactly that reason.
REQUIRED_DOMAINS=()
OPTIONAL_DOMAINS=()
for _conf in "$DROPIN_DIR/_required"/*.conf; do
    [ -f "$_conf" ] || continue
    while IFS= read -r _line || [ -n "$_line" ]; do
        _line="${_line%%#*}"; _line="${_line// /}"
        [ -z "$_line" ] && continue
        REQUIRED_DOMAINS+=("$_line")
    done < "$_conf"
done
for _conf in "$DROPIN_DIR/_optional"/*.conf; do
    [ -f "$_conf" ] || continue
    while IFS= read -r _line || [ -n "$_line" ]; do
        _line="${_line%%#*}"; _line="${_line// /}"
        [ -z "$_line" ] && continue
        OPTIONAL_DOMAINS+=("$_line")
    done < "$_conf"
done

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
            conf="$DROPIN_DIR/${mod}.conf"
            if [ ! -f "$conf" ]; then
                echo "WARN: Requested firewall module '${mod}' not found at $conf, skipping"
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
if ! curl --connect-timeout 5 https://api.github.com/zen >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - unable to reach https://api.github.com"
    exit 1
else
    echo "Firewall verification passed - able to reach https://api.github.com as expected"
fi