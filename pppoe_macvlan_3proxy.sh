#!/bin/bash

set -e

############################################
# 0. Licence check with progress bar
############################################

BAR_WIDTH=30
BAR_CHAR="#"

GREEN="\e[32m"
RED="\e[31m"
RESET="\e[0m"
YELLOW='\e[33m'
ORANGE='\e[38;5;208m'
PINK='\e[35m'
BLUE='\e[34m'

TMP_OUT=$(mktemp)

/usr/local/bin/check_license.sh --no-reboot >"$TMP_OUT" 2>&1 &
LIC_PID=$!
progress=0

printf "Checking licence... ${GREEN}[%*s]${RESET}" "$BAR_WIDTH" ""

while kill -0 "$LIC_PID" 2>/dev/null; do
    if [ "$progress" -lt "$BAR_WIDTH" ]; then
        progress=$((progress + 1))
    fi

    filled=$(printf "%*s" "$progress" "" | tr ' ' "$BAR_CHAR")
    empty=$(printf "%*s" "$((BAR_WIDTH - progress))" "")

    printf "\rChecking licence... ${GREEN}[%s%s]${RESET}" "$filled" "$empty"
    sleep 0.1
done

if wait "$LIC_PID"; then
    LIC_RC=0
else
    LIC_RC=$?
fi

filled=$(printf "%*s" "$BAR_WIDTH" "" | tr ' ' "$BAR_CHAR")
printf "\rChecking licence... ${GREEN}[%s]${RESET}\n" "$filled"

if [ "$LIC_RC" -ne 0 ]; then
    echo
    cat "$TMP_OUT"
    rm -f "$TMP_OUT"
    exit "$LIC_RC"
fi

rm -f "$TMP_OUT"
echo

############################################
# 1. Ask how many proxies to generate
############################################

DEFAULT_COUNT=3000
echo
read -r -p "How many proxies do you want to generate? [default: ${DEFAULT_COUNT}]: " USER_COUNT

if [ -z "$USER_COUNT" ]; then
    COUNT="$DEFAULT_COUNT"
elif [[ "$USER_COUNT" =~ ^[0-9]+$ ]] && [ "$USER_COUNT" -gt 0 ]; then
    COUNT="$USER_COUNT"
else
    echo "Invalid number, using default ${DEFAULT_COUNT}."
    COUNT="$DEFAULT_COUNT"
fi

echo
echo "Using COUNT=${COUNT} proxies."
echo

############################################
# 2. Global configuration
############################################

# Physical WAN interface
WAN_IF="ens160"

# Single 3proxy instance, single listening port
BASE_PORT=60000          # every proxy will be IP_PPP:60000

# Parallel PPPoE start
PARALLEL_START=500       # Number of PPP sessions to start before short pause

# Routing table base ID
TABLE_BASE=9000

# PPP credentials
PPP_USER="centre04"
PPP_PASS="centre04"

# Files and binaries
PROXY_LIST_RAW="/root/proxies_raw.txt"   # internal raw list (for generation & tests)
PROXY_LIST_FILE="/root/proxies.txt"      # final public list (served on port 1991)

THREEPROXY_BIN="/usr/local/bin/3proxy"
THREEPROXY_CFG="/usr/local/etc/3proxy/3proxy.cfg"

# (Conservé et corrigé même si pas utilisé, pour d'autres scripts éventuels)
# Map proxy TCP port -> PPP index (pppX) – version corrigée
get_ppp_index_from_port() {
    local port="$1"

    local BASE_PORT1=30000
    local BASE_PORT2=60000
    local MAX_PER_INSTANCE=1000

    # First 3proxy instance ports: BASE_PORT1 .. BASE_PORT1+MAX_PER_INSTANCE-1
    if (( port >= BASE_PORT1 && port < BASE_PORT1 + MAX_PER_INSTANCE )); then
        echo $(( port - BASE_PORT1 ))
        return 0
    fi

    # Second 3proxy instance ports: BASE_PORT2 .. BASE_PORT2+MAX_PER_INSTANCE-1
    if (( port >= BASE_PORT2 && port < BASE_PORT2 + MAX_PER_INSTANCE )); then
        echo $(( port - BASE_PORT2 + MAX_PER_INSTANCE ))
        return 0
    fi

    # Unknown / out of range
    echo "-1"
    return 1
}

############################################
# 3. Detect local IP on WAN_IF
############################################

LISTEN_IP=$(ip -4 addr show dev "$WAN_IF" | awk '/inet / {print $2}' | cut -d/ -f1 | head -n1)

if [ -z "$LISTEN_IP" ]; then
    echo "Unable to automatically detect IP address on ${WAN_IF}"
    exit 1
fi

echo "$(date) - Local IP on ${WAN_IF}: ${LISTEN_IP}"
echo

if [ ! -x "$THREEPROXY_BIN" ]; then
    echo "3proxy binary not found at: $THREEPROXY_BIN"
    exit 1
fi

if ! ip link show "$WAN_IF" >/dev/null 2>&1; then
    echo "Interface ${WAN_IF} not found."
    exit 1
fi

############################################
# 4. Cleanup old configs + macvlans
############################################

echo "$(date) - Cleaning old configuration..."

pkill 3proxy  >/dev/null 2>&1 || true
pkill pppd    >/dev/null 2>&1 || true

# Clean old macvlan interfaces (up to COUNT + 500, just to be safe)
MAX_CLEAN=$((COUNT + 500))

for i in $(seq 0 "$MAX_CLEAN"); do
    ip link show "macvlan$i" >/dev/null 2>&1 && ip link delete "macvlan$i" || true
done

# Reset RAW proxy list file (do not write anything yet)
: > "$PROXY_LIST_RAW"

############################################
# 5. Ensure PPP secrets contain our user
############################################

for f in /etc/ppp/chap-secrets /etc/ppp/pap-secrets; do
    if [ -f "$f" ]; then
        if ! grep -q "[[:space:]]${PPP_USER}[[:space:]]" "$f" 2>/dev/null; then
            echo "${PPP_USER} * ${PPP_PASS} *" >>"$f"
        fi
    fi
done

mkdir -p /etc/ppp/peers
mkdir -p "$(dirname "$THREEPROXY_CFG")"
mkdir -p /var/log/3proxy

############################################
# 6. Prepare 3proxy config (single instance)
############################################

cat >"$THREEPROXY_CFG" <<'EOF'
daemon
maxconn 15000
nserver 81.192.17.62
nserver 8.8.8.8
nscache 65536
log /var/log/3proxy/log.log D
logformat "L%Y-%m-%d %H:%M:%S %E %U %C:%c %R:%r %O %I %h %T"
timeouts 1 5 30 60 180 1000 15 60
auth none
allow *
EOF

############################################
# 7. Phase 1 - Create PPPoE sessions in parallel
############################################

echo "Starting service..."
echo
echo "Phase 1: creating PPPoE sessions..."
echo

for i in $(seq 0 $((COUNT - 1))); do
    echo "# Proxy number $i starting..."

    MACVLAN_IF="macvlan$i"

    if ! ip link add link "$WAN_IF" name "$MACVLAN_IF" type macvlan mode bridge 2>/dev/null; then
        echo "!!! Failed to create ${MACVLAN_IF}"
        continue
    fi

    ip link set "$MACVLAN_IF" up

    PEER_FILE="/etc/ppp/peers/pppoe$i"

    cat >"$PEER_FILE" <<EOF
plugin rp-pppoe.so
$MACVLAN_IF
noauth
defaultroute
usepeerdns
mtu 1492
mru 1492

idle 0
demand

# Keep the PPP session alive and reconnect automatically
lcp-echo-interval 30
lcp-echo-failure 10
persist
maxfail 0
holdoff 5
ipcp-accept-local
ipcp-accept-remote
noccp
user "$PPP_USER"
password "$PPP_PASS"
unit $i
EOF

    # start pppd in BACKGROUND (we don't wait here)
    pppd call "pppoe$i" >/var/log/pppoe_$i.log 2>&1 &

    # small pause every PARALLEL_START sessions to avoid overloading everything at once
    if (((i + 1) % PARALLEL_START == 0)); then
        echo " -> $((i + 1)) sessions started, taking a short break..."
        sleep 1
    fi
done

############################################
# 8. Phase 2 - Wait for PPP + routes + 3proxy entries
############################################

echo
echo "Phase 2: configuring routes and proxies..."
echo

for i in $(seq 0 $((COUNT - 1))); do
    PPP_IF="ppp$i"
    MACVLAN_IF="macvlan$i"

    # Wait for pppX interface to appear
    TIMEOUT=60
    while ! ip addr show "$PPP_IF" >/dev/null 2>&1 && [ "$TIMEOUT" -gt 0 ]; do
        sleep 1
        TIMEOUT=$((TIMEOUT - 1))
    done

    if ! ip addr show "$PPP_IF" >/dev/null 2>&1; then
        echo "!!! PPPoE failed on ${MACVLAN_IF} (${PPP_IF} not created)"
        continue
    fi

    # Get public IP on PPP interface
    IP_PPP=""
    TIMEOUT_IP=30
    while [ -z "$IP_PPP" ] && [ "$TIMEOUT_IP" -gt 0 ]; do
        IP_PPP=$(ip -4 addr show dev "$PPP_IF" | awk '/inet / {print $2}' | cut -d/ -f1 | head -n1)
        [ -n "$IP_PPP" ] && break
        sleep 1
        TIMEOUT_IP=$((TIMEOUT_IP - 1))
    done

    if [ -z "$IP_PPP" ]; then
        echo "!!! Unable to get IP on ${PPP_IF} (timeout)"
        continue
    fi

    echo " -> Proxy READY <<< ${PPP_IF} with IP ${IP_PPP}"

    # Quick connectivity test on this PPP (optional but recommended)
    if command -v curl >/dev/null 2>&1; then
        TEST_IP=$(curl -s --interface "$PPP_IF" --max-time 5 https://api.ipify.org 2>/dev/null || true)
        if [ -z "$TEST_IP" ]; then
            echo "!!! Skipping ${PPP_IF} (${IP_PPP}) - no internet connectivity"
            # Do NOT create proxy or routes for this PPP
            continue
        fi
    fi

    ########################################
    # Dedicated routing table for this PPP
    ########################################

    TABLE_ID=$((TABLE_BASE + i))

    # 1) Remove all existing rules for this IP (in any table)
    while ip rule show | grep -q "from $IP_PPP"; do
        ip rule delete from "$IP_PPP" >/dev/null 2>&1 || break
    done

    # 2) Flush routing table for this PPP
    ip route flush table "$TABLE_ID" >/dev/null 2>&1 || true

    # 3) Add host route for the PPP IP in its table
    if ! ip route add "$IP_PPP"/32 dev "$PPP_IF" table "$TABLE_ID" >/dev/null 2>&1; then
        echo "!!! Failed to add host route ${IP_PPP}/32 via ${PPP_IF} (interface probably went down)"
        continue
    fi

    # 4) Add default route via this PPP interface
    if ! ip route add default dev "$PPP_IF" table "$TABLE_ID" >/dev/null 2>&1; then
        echo "!!! Failed to add default route via ${PPP_IF}"
        continue
    fi

    # 5) Add a single routing rule for this IP to this table
    if ! ip rule add from "$IP_PPP" table "$TABLE_ID" priority $((9000 + i)) >/dev/null 2>&1; then
        echo "!!! Failed to add ip rule from ${IP_PPP} for table ${TABLE_ID}"
        continue
    fi

    ########################################
    # 3proxy mapping for this PPP (single port 60000)
    ########################################

    PORT=$BASE_PORT   # 60000 pour tous

    # 3proxy : écoute et sortie par IP de la PPP
    echo "proxy -a -p${PORT} -i${IP_PPP} -e${IP_PPP}" >>"$THREEPROXY_CFG"

    # Open the port in firewall if iptables is available
    if command -v iptables >/dev/null 2>&1; then
        iptables -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || \
        iptables -A INPUT -p tcp --dport "$PORT" -j ACCEPT
    fi

    # Add to RAW proxy list file (login/pass fixed example)
    echo "${IP_PPP}:${PORT}:fibre123:fibrebe123" >>"$PROXY_LIST_RAW"
done

############################################
# 9. Optional: adjust default route via ppp0
############################################

if ip link show ppp0 >/dev/null 2>&1; then
    ip route del default dev "$WAN_IF" >/dev/null 2>&1 || true
    ip route add default dev ppp0       >/dev/null 2>&1 || true
fi

############################################
# 10. Mini HTTP server to download proxies.txt
############################################

IP_PUBLIC="$LISTEN_IP"

if command -v python3 >/dev/null 2>&1; then
    echo "Server Ready For ${PROXY_LIST_FILE} (ALL interfaces):"
    (
        cd "$(dirname "$PROXY_LIST_FILE")" || exit 1
        python3 -m http.server 1991 --bind 0.0.0.0 >/dev/null 2>&1 &
    )
    echo " -> http://${IP_PUBLIC}:1991/$(basename "$PROXY_LIST_FILE")"
else
    echo "python3 not found, HTTP server not started."
fi

############################################
# 11. Start 3proxy instance
############################################

echo
echo "Starting 3proxy with generated configuration..."

if [ -s "$THREEPROXY_CFG" ]; then
    "$THREEPROXY_BIN" "$THREEPROXY_CFG" &
    echo " -> 3proxy started (all proxies on port ${BASE_PORT})"
fi

echo
echo "Done."

############################################
# 12. Initial proxy verification before export
#     (keep only proxies that return same IP as HOST)
############################################

echo -e "Running initial proxy verification (keeping only ${GREEN}STATUS OK${RESET} proxies)..."

TMP_FILE=$(mktemp)
EXPORT_OK=0
EXPORT_FAIL=0

# Read the RAW proxy list and keep only proxies that are really OK
while IFS=':' read -r HOST PORT USER PASS; do
    # Skip empty lines
    [ -z "$HOST" ] && continue

    if [ -n "$USER" ] && [ -n "$PASS" ]; then
        PROXY_URL="http://${USER}:${PASS}@${HOST}:${PORT}"
    else
        PROXY_URL="http://${HOST}:${PORT}"
    fi

    # Test through api.ipify.org (returned IP must match HOST)
    PUBLIC_IP=$(curl -sS --max-time 10 -x "$PROXY_URL" https://api.ipify.org 2>/dev/null || true)

    if [ -n "$PUBLIC_IP" ] && [ "$PUBLIC_IP" = "$HOST" ]; then
        # Proxy is good -> keep it in the FINAL file
        if [ -n "$USER" ] && [ -n "$PASS" ]; then
            echo "${HOST}:${PORT}:${USER}:${PASS}" >>"$TMP_FILE"
        else
            echo "${HOST}:${PORT}" >>"$TMP_FILE"
        fi
        EXPORT_OK=$((EXPORT_OK+1))
        echo -e "${HOST}:${PORT} -> ${PUBLIC_IP} ${GREEN}STATUS OK (KEPT)${RESET}"
    else
        # Proxy failed or IP mismatch -> do NOT write it to the FINAL file
        EXPORT_FAIL=$((EXPORT_FAIL+1))
        if [ -z "$PUBLIC_IP" ]; then
            echo -e "${HOST}:${PORT} -> ${RED}STATUS FAIL (no response, REMOVED)${RESET}"
        else
            echo -e "${HOST}:${PORT} -> ${PUBLIC_IP} ${RED}STATUS MISMATCH (REMOVED)${RESET}"
        fi
    fi
done < "$PROXY_LIST_RAW"

# Replace/create the FINAL public file
mv "$TMP_FILE" "$PROXY_LIST_FILE"

echo "Initial export filter summary:"
echo -e "  ${GREEN}OK proxies kept${RESET} : ${EXPORT_OK}"
echo -e "  ${RED}Removed (bad)${RESET}    : ${EXPORT_FAIL}"

echo "Proxy list available in: ${PROXY_LIST_FILE}"

echo
echo "Starting live proxy health check (Ctrl+C to stop)..."

############################################
# 13. Live proxy health check loop
############################################

while true; do
    echo
    echo "============================================"
    echo -e " ${PINK}Proxy health check at $(date)${RESET}"
    echo -e " File: ${PINK}${PROXY_LIST_FILE}${RESET}"
    echo "============================================"

    if [ ! -f "$PROXY_LIST_FILE" ]; then
        echo "Proxy list file ${PROXY_LIST_FILE} not found, exiting health check."
        break
    fi

    # Counters for this round
    OK_COUNT=0
    FAIL_COUNT=0
    # List of FAILED proxies for this round
    FAILED_LIST=""

    # Read each proxy from the list: HOST:PORT:USER:PASS
    while IFS=':' read -r HOST PORT USER PASS; do
        # Skip empty lines
        [ -z "$HOST" ] && continue

        if [ -n "$USER" ] && [ -n "$PASS" ]; then
            PROXY_URL="http://${USER}:${PASS}@${HOST}:${PORT}"
        else
            PROXY_URL="http://${HOST}:${PORT}"
        fi

        # Test the proxy like an external client: HTTPS request to Google
        #  - If the request succeeds within 20 seconds => proxy OK
        #  - If it times out or fails => proxy FAILED
        if curl -sS --max-time 20 -x "$PROXY_URL" https://www.google.com >/dev/null 2>&1; then
            echo -e "${HOST}:${PORT} -> ${GREEN}STATUS OK !${RESET}"
            OK_COUNT=$((OK_COUNT+1))
        else
            echo -e "${HOST}:${PORT} -> ${RED}STATUS FAIL${RESET}"
            FAIL_COUNT=$((FAIL_COUNT+1))
            # Keep list of failed proxies for the summary
            FAILED_LIST+="${HOST}:${PORT}\n"
        fi

    done < "$PROXY_LIST_FILE"

    TOTAL=$((OK_COUNT + FAIL_COUNT))

    echo "----------------------------------------------"
    echo -e " ${YELLOW}Summary for this check:${RESET}"
    echo -e "  ${ORANGE}Total proxies tested${RESET} : ${TOTAL}"
    echo -e "  ${GREEN}STATUS OK${RESET}            : ${GREEN}${OK_COUNT}${RESET}"
    echo -e "  ${RED}Failed${RESET}               : ${RED}${FAIL_COUNT}${RESET}"

    # If some proxies failed, print their list in red
    if [ "$FAIL_COUNT" -gt 0 ]; then
        echo
        echo -e "${RED}Failed proxies list:${RESET}"
        printf '%b' "$FAILED_LIST"
        echo
    fi

    echo -e " ${BLUE}Next check in 60 Sec... (Press Ctrl+C to stop)${RESET}"
    sleep 60
done
