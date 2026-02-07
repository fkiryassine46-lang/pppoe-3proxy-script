#!/bin/bash

set -e
#script complet mlih
############################################
# 0. Licence check with progress bar
############################################

BAR_WIDTH=30
BAR_CHAR="█"   # blocs pleins

GREEN="\e[32m"
RED="\e[31m"
RESET="\e[0m"
YELLOW='\e[33m'
ORANGE='\e[38;5;208m'
PINK='\e[35m'
BLUE='\e[34m'

# couleurs spéciales pour les barres
BAR_GREEN="\e[92m"   # vert clair
BAR_BLUE="\e[94m"    # bleu clair
BAR_YELLOW="\e[93m"  # jaune clair

TMP_OUT=$(mktemp)

/usr/local/bin/check_license.sh --no-reboot >"$TMP_OUT" 2>&1 &
LIC_PID=$!
progress=0

# Affichage initial
printf "Checking licence... ${BAR_YELLOW}%3d%% [%-*s]${RESET}" 0 "$BAR_WIDTH" ""

while kill -0 "$LIC_PID" 2>/dev/null; do
    if [ "$progress" -lt "$BAR_WIDTH" ]; then
        progress=$((progress + 1))
    fi

    percent=$(( progress * 100 / BAR_WIDTH ))
    [ "$percent" -gt 100 ] && percent=100

    filled=$(printf "%*s" "$progress" "" | tr ' ' "$BAR_CHAR")
    empty=$(printf "%*s" "$((BAR_WIDTH - progress))" "")

    printf "\rChecking licence... ${BAR_YELLOW}%3d%% [%s%s]${RESET}" "$percent" "$filled" "$empty"
    sleep 0.1
done

if wait "$LIC_PID"; then
    LIC_RC=0
else
    LIC_RC=$?
fi

# fin : 100% et barre pleine
filled=$(printf "%*s" "$BAR_WIDTH" "" | tr ' ' "$BAR_CHAR")
printf "\rChecking licence... ${BAR_YELLOW}%3d%% [%s]${RESET}\n" 100 "$filled"

if [ "$LIC_RC" -ne 0 ]; then
    echo
    cat "$TMP_OUT"
    rm -f "$TMP_OUT"
    exit "$LIC_RC"
fi

rm -f "$TMP_OUT"
echo

############################################
# Helpers
############################################

# Barre de progression style "Loading..." avec couleur
# usage: show_progress <current> <total> "<label>" <color>
show_progress() {
    local current="$1"
    local total="$2"
    local label="$3"
    local color="$4"
    local width=40
    local block="█"

    if [ "$total" -le 0 ]; then
        return
    fi

    local percent=$(( current * 100 / total ))
    [ "$percent" -gt 100 ] && percent=100

    local filled=$(( current * width / total ))
    [ "$filled" -gt "$width" ] && filled="$width"
    local empty=$(( width - filled ))

    # label + pourcentage coloré
    printf "\r%s %b%3d%%%b [" "$label" "$color" "$percent" "$RESET"

    # partie remplie colorée
    local j
    for ((j=0; j<filled; j++)); do
        printf "%b" "${color}${block}${RESET}"
    done

    # partie vide
    for ((j=0; j<empty; j++)); do
        printf " "
    done

    printf "]"
}

# helpers dédiés aux deux phases
show_progress_phase1() {
    show_progress "$1" "$2" "$3" "$BAR_GREEN"
}

show_progress_phase2() {
    show_progress "$1" "$2" "$3" "$BAR_BLUE"
}

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

# 3proxy instances
BASE_PORT1=30000          # Instance 1 base port
BASE_PORT2=60000          # Instance 2 base port
MAX_PER_INSTANCE=1000     # Max proxies on instance 1

PARALLEL_START=500        # PPP sessions to start before short pause

# Routing table base ID
TABLE_BASE=9000

# PPP credentials
PPP_USER="centre04"
PPP_PASS="centre04"

# Files and binaries
PROXY_LIST_RAW="/root/proxies_raw.txt"   # internal raw list (for generation & tests)
PROXY_LIST_FILE="/root/proxies.txt"      # final public list (served on port 1991)

THREEPROXY_BIN="/usr/local/bin/3proxy"
THREEPROXY_CFG1="/usr/local/etc/3proxy/3proxy1.cfg"
THREEPROXY_CFG2="/usr/local/etc/3proxy/3proxy2.cfg"

# Performance tuning
CHECK_MAX_TIME=7          # Timeout for initial check (ipv4.icanhazip.com)
CHECK_PARALLEL_JOBS=50    # Parallel curl jobs during initial check
HEALTH_MAX_TIME=15        # Timeout for live health check (Google)

# Map proxy TCP port -> PPP index (pppX) (garde pour debug/usage futur)
get_ppp_index_from_port() {
    local port="$1"

    # First 3proxy instance ports: BASE_PORT1 .. BASE_PORT1+MAX_PER_INSTANCE-1
    if (( port >= BASE_PORT1 && port < BASE_PORT1 + MAX_PER_INSTANCE )); then
        echo $((port - BASE_PORT1))
        return 0
    fi

    # Second 3proxy instance ports: BASE_PORT2 .. BASE_PORT2+MAX_PER_INSTANCE-1
    if (( port >= BASE_PORT2 && port < BASE_PORT2 + MAX_PER_INSTANCE )); then
        echo $((port - BASE_PORT2))
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

pkill 3proxy >/dev/null 2>&1 || true
pkill pppd   >/dev/null 2>&1 || true

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
mkdir -p "$(dirname "$THREEPROXY_CFG1")"
mkdir -p /var/log/3proxy

############################################
# 6. Prepare 3proxy configs (two instances)
############################################

cat >"$THREEPROXY_CFG1" <<'EOF1'
daemon
maxconn 15000
nserver 81.192.17.62
nserver 8.8.8.8
nscache 65536
log /var/log/3proxy/log1.log D
logformat "L%Y-%m-%d %H:%M:%S %E %U %C:%c %R:%r %O %I %h %T"
timeouts 1 5 30 60 180 1000 15 60
auth none
allow *
EOF1

cat >"$THREEPROXY_CFG2" <<'EOF2'
daemon
maxconn 15000
nserver 81.192.17.62
nserver 8.8.8.8
nscache 65536
log /var/log/3proxy/log2.log D
logformat "L%Y-%m-%d %H:%M:%S %E %U %C:%c %R:%r %O %I %h %T"
timeouts 1 5 30 60 180 1000 15 60
auth none
allow *
EOF2

############################################
# 7. Phase 1 - Create PPPoE sessions in parallel
############################################

echo "Starting service..."
echo
echo "Phase 1: creating PPPoE sessions..."
echo

for i in $(seq 0 $((COUNT - 1))); do
    MACVLAN_IF="macvlan$i"

    if ! ip link add link "$WAN_IF" name "$MACVLAN_IF" type macvlan mode bridge 2>/dev/null; then
        echo
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
        sleep 1
    fi

    show_progress_phase1 $((i + 1)) "$COUNT" "Phase 1 (PPPoE sessions):"
done
echo
echo

############################################
# 8. Phase 2 - Wait for PPP + routes + 3proxy entries
############################################

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
        echo
        echo "!!! PPPoE failed on ${MACVLAN_IF} (${PPP_IF} not created)"
        show_progress_phase2 $((i + 1)) "$COUNT" "Phase 2 (routes+proxies):"
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
        echo
        echo "!!! Unable to get IP on ${PPP_IF} (timeout)"
        show_progress_phase2 $((i + 1)) "$COUNT" "Phase 2 (routes+proxies):"
        continue
    fi

    # Quick connectivity test on this PPP via ping
    PING_OK=0
    if command -v ping >/dev/null 2>&1; then
        if ping -c 1 -W 2 -I "$PPP_IF" 8.8.8.8 >/dev/null 2>&1; then
            PING_OK=1
        fi
    fi
    if [ "$PING_OK" -ne 1 ]; then
        echo
        echo "!!! Skipping ${PPP_IF} (${IP_PPP}) - no internet connectivity"
        show_progress_phase2 $((i + 1)) "$COUNT" "Phase 2 (routes+proxies):"
        continue
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
        echo
        echo "!!! Failed to add host route ${IP_PPP}/32 via ${PPP_IF} (interface probably went down)"
        show_progress_phase2 $((i + 1)) "$COUNT" "Phase 2 (routes+proxies):"
        continue
    fi

    # 4) Add default route via this PPP interface
    if ! ip route add default dev "$PPP_IF" table "$TABLE_ID" >/dev/null 2>&1; then
        echo
        echo "!!! Failed to add default route via ${PPP_IF}"
        show_progress_phase2 $((i + 1)) "$COUNT" "Phase 2 (routes+proxies):"
        continue
    fi

    # 5) Add a single routing rule for this IP to this table
    if ! ip rule add from "$IP_PPP" table "$TABLE_ID" priority $((9000 + i)) >/dev/null 2>&1; then
        echo
        echo "!!! Failed to add ip rule from ${IP_PPP} for table ${TABLE_ID}"
        show_progress_phase2 $((i + 1)) "$COUNT" "Phase 2 (routes+proxies):"
        continue
    fi

    ########################################
    # 3proxy mapping for this PPP
    ########################################

    if [ "$i" -lt "$MAX_PER_INSTANCE" ]; then
        # Instance 1
        PORT=$((BASE_PORT1 + i))
        echo "proxy -a -p${PORT} -i0.0.0.0 -e${IP_PPP}" >>"$THREEPROXY_CFG1"
    else
        # Instance 2
        INDEX2=$((i - MAX_PER_INSTANCE))
        PORT=$((BASE_PORT2 + INDEX2))
        echo "proxy -a -p${PORT} -i0.0.0.0 -e${IP_PPP}" >>"$THREEPROXY_CFG2"
    fi

    # Open the port in firewall if iptables is available
    if command -v iptables >/dev/null 2>&1; then
        iptables -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || \
        iptables -A INPUT -p tcp --dport "$PORT" -j ACCEPT
    fi

    # Add to RAW proxy list file (login/pass fixed example)
    echo "${IP_PPP}:${PORT}:fibre123:fibrebe123" >>"$PROXY_LIST_RAW"

    show_progress_phase2 $((i + 1)) "$COUNT" "Phase 2 (routes+proxies):"
done
echo
echo

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
# 11. Start 3proxy instances
############################################

echo
echo "Starting 3proxy with generated configurations..."

if [ -s "$THREEPROXY_CFG1" ]; then
    "$THREEPROXY_BIN" "$THREEPROXY_CFG1" &
    echo " -> 3proxy instance 1 started (ports from ${BASE_PORT1})"
fi

if [ -s "$THREEPROXY_CFG2" ]; then
    "$THREEPROXY_BIN" "$THREEPROXY_CFG2" &
    echo " -> 3proxy instance 2 started (ports from ${BASE_PORT2})"
fi

echo
echo "Done."

############################################
# 12. Initial proxy verification before export
#     (keep only proxies that return same IP as HOST)
############################################

echo -e "Running initial proxy verification in PARALLEL (keeping only ${GREEN}STATUS OK${RESET} proxies)..."
echo "  Max parallel jobs : ${CHECK_PARALLEL_JOBS}"
echo "  Curl timeout      : ${CHECK_MAX_TIME}s"
echo

TMP_FILE_OK=$(mktemp)
LOG_FILE=$(mktemp)
TOTAL=0

check_one_proxy() {
    local host="$1"
    local port="$2"
    local user="$3"
    local pass="$4"

    local proxy_url public_ip

    if [ -n "$user" ] && [ -n "$pass" ]; then
        proxy_url="http://${user}:${pass}@${host}:${port}"
    else
        proxy_url="http://${host}:${port}"
    fi

    public_ip=$(curl -sS --max-time "$CHECK_MAX_TIME" -x "$proxy_url" https://ipv4.icanhazip.com 2>/dev/null | tr -d '\r\n' || true)

    if [ -n "$public_ip" ] && [ "$public_ip" = "$host" ]; then
        if [ -n "$user" ] && [ -n "$pass" ]; then
            echo "${host}:${port}:${user}:${pass}" >>"$TMP_FILE_OK"
        else
            echo "${host}:${port}" >>"$TMP_FILE_OK"
        fi
        echo -e "${host}:${port} -> ${public_ip} ${GREEN}STATUS OK (KEPT)${RESET}" >>"$LOG_FILE"
    else
        if [ -z "$public_ip" ]; then
            echo -e "${host}:${port} -> ${RED}STATUS FAIL (no response, REMOVED)${RESET}" >>"$LOG_FILE"
        else
            echo -e "${host}:${port} -> ${public_ip} ${RED}STATUS MISMATCH (REMOVED)${RESET}" >>"$LOG_FILE"
        fi
    fi
}

while IFS=':' read -r HOST PORT USER PASS; do
    [ -z "$HOST" ] && continue
    TOTAL=$((TOTAL + 1))

    while [ "$(jobs -r | wc -l 2>/dev/null)" -ge "$CHECK_PARALLEL_JOBS" ]; do
        sleep 0.1
    done

    check_one_proxy "$HOST" "$PORT" "$USER" "$PASS" &
done < "$PROXY_LIST_RAW"

wait

if [ -s "$LOG_FILE" ]; then
    cat "$LOG_FILE"
fi

EXPORT_OK=0
if [ -s "$TMP_FILE_OK" ]; then
    EXPORT_OK=$(wc -l < "$TMP_FILE_OK")
fi
EXPORT_FAIL=$((TOTAL - EXPORT_OK))

mv "$TMP_FILE_OK" "$PROXY_LIST_FILE"
rm -f "$LOG_FILE"

echo
echo "Initial export filter summary:"
echo -e "  ${GREEN}OK proxies kept${RESET} : ${EXPORT_OK}"
echo -e "  ${RED}Removed (bad)${RESET}    : ${EXPORT_FAIL}"

echo "Proxy list available in: ${PROXY_LIST_FILE}"
echo
echo "Starting live proxy health check (Ctrl+C to stop)..."

############################################
# 13. Live proxy health check loop
#     (et MAJ de /root/proxies.txt : on garde
#      uniquement les proxies STATUS OK)
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

    OK_COUNT=0
    FAIL_COUNT=0
    FAILED_LIST=""
    TMP_HEALTH=$(mktemp)   # nouvelle liste filtrée

    # Lire chaque proxy : HOST:PORT:USER:PASS
    while IFS=':' read -r HOST PORT USER PASS; do
        [ -z "$HOST" ] && continue

        if [ -n "$USER" ] && [ -n "$PASS" ]; then
            PROXY_URL="http://${USER}:${PASS}@${HOST}:${PORT}"
        else
            PROXY_URL="http://${HOST}:${PORT}"
        fi

        # Test comme un client externe (Google)
        if curl -sS --max-time "$HEALTH_MAX_TIME" -x "$PROXY_URL" https://www.google.com >/dev/null 2>&1; then
            echo -e "${HOST}:${PORT} -> ${GREEN}STATUS OK !${RESET}"
            OK_COUNT=$((OK_COUNT + 1))
            # On réécrit le proxy dans la NOUVELLE liste
            if [ -n "$USER" ] && [ -n "$PASS" ]; then
                echo "${HOST}:${PORT}:${USER}:${PASS}" >>"$TMP_HEALTH"
            else
                echo "${HOST}:${PORT}" >>"$TMP_HEALTH"
            fi
        else
            echo -e "${HOST}:${PORT} -> ${RED}STATUS FAIL${RESET}"
            FAIL_COUNT=$((FAIL_COUNT + 1))
            FAILED_LIST+="${HOST}:${PORT}\n"
            # On NE l’écrit PAS dans TMP_HEALTH → supprimé
        fi
    done < "$PROXY_LIST_FILE"

    # Remplacer l’ancienne liste par la nouvelle filtrée
    mv "$TMP_HEALTH" "$PROXY_LIST_FILE"

    TOTAL=$((OK_COUNT + FAIL_COUNT))

    echo "----------------------------------------------"
    echo -e " ${YELLOW}Summary for this check:${RESET}"
    echo -e "  ${ORANGE}Total proxies tested${RESET} : ${TOTAL}"
    echo -e "  ${GREEN}STATUS OK${RESET}            : ${GREEN}${OK_COUNT}${RESET}"
    echo -e "  ${RED}Failed${RESET}               : ${RED}${FAIL_COUNT}${RESET}"

    if [ "$FAIL_COUNT" -gt 0 ]; then
        echo
        echo -e "${RED}Failed proxies REMOVED from list:${RESET}"
        printf '%b' "$FAILED_LIST"
        echo
    fi

    echo -e " ${BLUE}Next check in 60 Sec... (Press Ctrl+C to stop)${RESET}"
    sleep 60
done
