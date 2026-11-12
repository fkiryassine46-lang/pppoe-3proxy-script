#!/bin/bash

set -e

############################################
# 0. Licence check avec barre de progression
############################################

BAR_WIDTH=30

GREEN="\e[32m"
RED="\e[31m"
RESET="\e[0m"
YELLOW='\e[33m'
ORANGE='\e[38;5;208m'
PINK='\e[35m'
BLUE='\e[34m'

GREEN_BG="\e[42m"
PINK_BG="\e[45m"
ORANGE_BG="\e[48;5;208m"

TMP_OUT=$(mktemp)

/usr/local/bin/check_license.sh --no-reboot >"$TMP_OUT" 2>&1 &
LIC_PID=$!
progress=0

printf "\n"
printf "%bChecking licence...%b " "$RED" "$RESET"
printf "%b[" "$ORANGE"
printf "%b%*s%b" "$ORANGE_BG" "$BAR_WIDTH" "" "$RESET"
printf "%b]%b" "$ORANGE" "$RESET"

while kill -0 "$LIC_PID" 2>/dev/null; do
    if [ "$progress" -lt "$BAR_WIDTH" ]; then
        progress=$((progress + 1))
    fi
    filled=$(printf "%*s" "$progress" "")
    empty=$(printf "%*s" "$((BAR_WIDTH - progress))" "")
    printf "\r%bChecking licence...%b " "$RED" "$RESET"
    printf "%b[" "$ORANGE"
    printf "%b%s%b" "$ORANGE_BG" "$filled" "$RESET"
    printf "%s" "$empty"
    printf "%b]%b" "$ORANGE" "$RESET"
    sleep 0.1
done

if wait "$LIC_PID"; then
    LIC_RC=0
else
    LIC_RC=$?
fi

filled=$(printf "%*s" "$BAR_WIDTH" "")
printf "\r%bChecking licence...%b " "$RED" "$RESET"
printf "%b[" "$ORANGE"
printf "%b%s%b" "$ORANGE_BG" "$filled" "$RESET"
printf "%b]%b\n" "$ORANGE" "$RESET"

if [ "$LIC_RC" -ne 0 ]; then
    echo
    cat "$TMP_OUT"
    rm -f "$TMP_OUT"
    exit "$LIC_RC"
fi

rm -f "$TMP_OUT"
echo

############################################
# Helper: barre de progression générique
############################################
progress_bar() {
    local current="$1"
    local total="$2"
    local label="$3"
    local color_fg="$4"
    local color_bg="$5"
    local width=40

    [ "$total" -le 0 ] && total=1
    [ -z "$color_fg" ] && color_fg="$RESET"
    [ -z "$color_bg" ] && color_bg="$color_fg"

    local percent=$(( current * 100 / total ))
    [ "$percent" -gt 100 ] && percent=100
    local filled=$(( current * width / total ))
    local empty=$(( width - filled ))

    local bar_filled bar_empty
    bar_filled=$(printf "%*s" "$filled" "")
    bar_empty=$(printf "%*s" "$empty" "")

    printf "\r%b%s%b " "$color_fg" "$label" "$RESET"
    printf "%b[" "$color_fg"
    printf "%b%s%b" "$color_bg" "$bar_filled" "$RESET"
    printf "%s" "$bar_empty"
    printf "%b]%b " "$color_fg" "$RESET"
    printf "%b%3d%%%b" "$color_fg" "$percent" "$RESET"
}

############################################
# 1. Demande du nombre de proxies
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
# 2. Config globale
############################################

WAN_IF="ens160"

BASE_PORT1=30000
BASE_PORT2=60000
MAX_PER_INSTANCE=1000

# --- Rythme de démarrage PPPoE ---
# Le BRAS Maroc Telecom (Huawei ME60) bloque temporairement si trop de
# demandes PPPoE arrivent trop vite. Le script ralentit automatiquement
# dès qu'il détecte des "Timeout waiting for PADO", puis ré-accélère.
BATCH_SIZE=5              # nb de sessions lancées avant une pause
BATCH_PAUSE=5             # pause normale (s) entre deux lots
MAX_BATCH_PAUSE=60        # pause max (s) quand le BRAS sature
START_DELAY=1             # pause (s) entre chaque session

# --- Attente d'une vraie IP par session (Phase 2, 1er passage) ---
WAIT_IP=20

# --- Nouvelles tentatives pour les sessions ratées ---
RETRY_ROUNDS=5            # nb de tours de rattrapage
RETRY_WAIT=45             # attente (s) avant chaque tour

# --- Délai après arrêt des anciennes sessions ---
CLEAN_WAIT=10

# --- MAC fixes par macvlan (1 = MAC stable, 0 = aléatoire) ---
USE_FIXED_MAC=1

TABLE_BASE=9000

PPP_USER="centre04"
PPP_PASS="centre04"

PROXY_LIST_RAW="/root/proxies_raw.txt"
PROXY_LIST_FILE="/root/proxies.txt"

THREEPROXY_BIN="/usr/local/bin/3proxy"
THREEPROXY_CFG1="/usr/local/etc/3proxy/3proxy1.cfg"
THREEPROXY_CFG2="/usr/local/etc/3proxy/3proxy2.cfg"

get_ppp_index_from_port() {
    local port="$1"
    if (( port >= BASE_PORT1 && port < BASE_PORT1 + MAX_PER_INSTANCE )); then
        echo $(( port - BASE_PORT1 )); return 0
    fi
    if (( port >= BASE_PORT2 && port < BASE_PORT2 + MAX_PER_INSTANCE )); then
        echo $(( port - BASE_PORT2 + MAX_PER_INSTANCE )); return 0
    fi
    echo "-1"; return 1
}

# IP valide = pas une adresse temporaire pppd (10.64.64.x / 10.112.112.x)
is_valid_ppp_ip() {
    case "$1" in
        ""|10.64.64.*|10.112.112.*|169.254.*|0.0.0.0) return 1 ;;
    esac
    return 0
}

get_ppp_ip() {
    ip -4 addr show dev "$1" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -n1
}

ppp_session_running() {
    pgrep -f "pppd call pppoe${1}\$" >/dev/null 2>&1
}

stop_ppp_session() {
    pkill -f "pppd call pppoe${1}\$" >/dev/null 2>&1 || true
}

count_pado_timeouts() {
    cat /var/log/pppoe_*.log 2>/dev/null | grep -c "Timeout waiting for PADO" || true
}

############################################
# 3. Détection IP locale sur WAN_IF
############################################

LISTEN_IP=$(get_ppp_ip "$WAN_IF")

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
# 4. Cleanup propre (sessions, règles, macvlans)
############################################

echo "$(date) - Cleaning old configuration..."

pkill 3proxy >/dev/null 2>&1 || true
pkill -f "http.server 1991" >/dev/null 2>&1 || true

# Arrêt PROPRE de pppd (PADT envoyé => sessions libérées chez le FAI)
if pgrep -x pppd >/dev/null 2>&1; then
    pkill -TERM -x pppd >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
        pgrep -x pppd >/dev/null 2>&1 || break
        sleep 1
    done
    pkill -KILL -x pppd >/dev/null 2>&1 || true
    echo "  -> Waiting ${CLEAN_WAIT}s so the ISP releases old sessions..."
    sleep "$CLEAN_WAIT"
fi

MAX_CLEAN=$((COUNT + 500))

for p in $(ip rule show | awk -F: '{print $1+0}' | sort -un); do
    if [ "$p" -ge 9000 ] && [ "$p" -lt $((9000 + MAX_CLEAN)) ]; then
        while ip rule del priority "$p" >/dev/null 2>&1; do :; done
        ip route flush table $((TABLE_BASE + p - 9000)) >/dev/null 2>&1 || true
    fi
done

for ifc in $(ip -o link show type macvlan 2>/dev/null | awk -F': ' '{print $2}' | cut -d@ -f1 | grep '^macvlan' || true); do
    ip link delete "$ifc" >/dev/null 2>&1 || true
done

: > "$PROXY_LIST_RAW"
rm -f /var/log/pppoe_*.log

############################################
# 5. PPP secrets
############################################

for f in /etc/ppp/chap-secrets /etc/ppp/pap-secrets; do
    if [ -f "$f" ]; then
        if ! grep -q "^${PPP_USER}[[:space:]]" "$f" 2>/dev/null; then
            echo "${PPP_USER} * ${PPP_PASS} *" >>"$f"
        fi
    fi
done

mkdir -p /etc/ppp/peers
mkdir -p "$(dirname "$THREEPROXY_CFG1")"
mkdir -p /var/log/3proxy

# Options PADI plus patientes si la version de pppd les supporte
# (sinon on ne les met pas, pour ne rien casser)
PADI_OPTS=""
if pppd plugin rp-pppoe.so "$WAN_IF" pppoe-padi-timeout 10 pppoe-padi-attempts 4 dryrun >/dev/null 2>&1; then
    PADI_OPTS="pppoe-padi-timeout 10
pppoe-padi-attempts 4"
fi

############################################
# 6. Configs 3proxy (deux instances)
############################################

for n in 1 2; do
    CFG_VAR="THREEPROXY_CFG$n"
    cat >"${!CFG_VAR}" <<EOF
daemon
maxconn 15000
nserver 81.192.17.62
nserver 8.8.8.8
nscache 65536
log /var/log/3proxy/log$n.log D
logformat "L%Y-%m-%d %H:%M:%S %E %U %C:%c %R:%r %O %I %h %T"
timeouts 1 5 30 60 180 1000 15 60
auth none
allow *
EOF
done

############################################
# 7. Phase 1 - Création des sessions PPPoE
############################################

echo "Starting service..."
echo
echo "Phase 1: creating PPPoE sessions..."
echo

PH1_DONE=0
CUR_PAUSE="$BATCH_PAUSE"
LAST_TO=0

for i in $(seq 0 $((COUNT - 1))); do
    MACVLAN_IF="macvlan$i"

    ADD_OK=0
    if [ "$USE_FIXED_MAC" -eq 1 ]; then
        MAC=$(printf "02:4d:54:%02x:%02x:%02x" $(( (i >> 16) & 255 )) $(( (i >> 8) & 255 )) $(( i & 255 )))
        ip link add link "$WAN_IF" name "$MACVLAN_IF" address "$MAC" type macvlan mode bridge 2>/dev/null && ADD_OK=1
    else
        ip link add link "$WAN_IF" name "$MACVLAN_IF" type macvlan mode bridge 2>/dev/null && ADD_OK=1
    fi

    if [ "$ADD_OK" -ne 1 ]; then
        echo
        echo "!!! Failed to create ${MACVLAN_IF}"
        continue
    fi

    ip link set "$MACVLAN_IF" up

    # holdoff étalé (30..59s) pour que les re-tentatives ne partent pas
    # toutes en même temps vers le BRAS
    HOLDOFF=$((30 + (i % 30)))

    cat >"/etc/ppp/peers/pppoe$i" <<EOF
plugin rp-pppoe.so
$MACVLAN_IF
$PADI_OPTS
noauth
nodefaultroute
usepeerdns
mtu 1492
mru 1492

lcp-echo-interval 30
lcp-echo-failure 10
persist
maxfail 0
holdoff $HOLDOFF
noipdefault
ipcp-accept-local
ipcp-accept-remote
noccp
user "$PPP_USER"
password "$PPP_PASS"
unit $i
logfile /var/log/pppoe_$i.log
EOF

    pppd call "pppoe$i" >/dev/null 2>&1 &

    PH1_DONE=$((PH1_DONE + 1))
    progress_bar "$PH1_DONE" "$COUNT" "Phase 1" "$GREEN" "$GREEN_BG"

    # Pause adaptative : si le BRAS ne répond plus (PADO timeout), on ralentit
    if (((i + 1) % BATCH_SIZE == 0)); then
        TO_NOW=$(count_pado_timeouts)
        if [ "$TO_NOW" -gt "$LAST_TO" ]; then
            CUR_PAUSE=$((CUR_PAUSE * 2))
            [ "$CUR_PAUSE" -gt "$MAX_BATCH_PAUSE" ] && CUR_PAUSE="$MAX_BATCH_PAUSE"
            printf " %b(ISP busy, pause %ss)%b   " "$YELLOW" "$CUR_PAUSE" "$RESET"
        elif [ "$CUR_PAUSE" -gt "$BATCH_PAUSE" ]; then
            CUR_PAUSE=$((CUR_PAUSE / 2))
            [ "$CUR_PAUSE" -lt "$BATCH_PAUSE" ] && CUR_PAUSE="$BATCH_PAUSE"
            printf "                        "
        fi
        LAST_TO="$TO_NOW"
        sleep "$CUR_PAUSE"
    else
        sleep "$START_DELAY"
    fi
done

echo
echo

############################################
# 8. Phase 2 - PPP + routes + 3proxy
############################################

PH2_OK=0
FAILED_IDX=()
PENDING=()

# Configure routage + 3proxy pour une session qui a une vraie IP
configure_session() {
    local i="$1"
    local IP_PPP="$2"
    local PPP_IF="ppp$i"
    local TABLE_ID=$((TABLE_BASE + i))
    local PRIO=$((9000 + i))
    local PORT

    if command -v ping >/dev/null 2>&1; then
        if ! ping -I "$PPP_IF" -c 2 -W 3 8.8.8.8 >/dev/null 2>&1; then
            echo
            echo "!!! Warning: connectivity test FAILED on ${PPP_IF} (${IP_PPP})"
            echo "    -> Keeping this session anyway (it will be tested as proxy later)."
        fi
    fi

    ip rule del priority "$PRIO" >/dev/null 2>&1 || true
    ip route flush table "$TABLE_ID" >/dev/null 2>&1 || true

    if ! ip route add "$IP_PPP"/32 dev "$PPP_IF" table "$TABLE_ID" >/dev/null 2>&1; then
        echo; echo "!!! Failed to add host route ${IP_PPP}/32 via ${PPP_IF}"
        return 1
    fi
    if ! ip route add default dev "$PPP_IF" table "$TABLE_ID" >/dev/null 2>&1; then
        echo; echo "!!! Failed to add default route via ${PPP_IF}"
        return 1
    fi
    if ! ip rule add from "$IP_PPP" table "$TABLE_ID" priority "$PRIO" >/dev/null 2>&1; then
        echo; echo "!!! Failed to add ip rule from ${IP_PPP} for table ${TABLE_ID}"
        return 1
    fi

    if [ "$i" -lt "$MAX_PER_INSTANCE" ]; then
        PORT=$((BASE_PORT1 + i))
        echo "proxy -a -p${PORT} -i0.0.0.0 -e${IP_PPP}" >>"$THREEPROXY_CFG1"
    else
        PORT=$((BASE_PORT2 + i - MAX_PER_INSTANCE))
        echo "proxy -a -p${PORT} -i0.0.0.0 -e${IP_PPP}" >>"$THREEPROXY_CFG2"
    fi

    if command -v iptables >/dev/null 2>&1; then
        iptables -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || \
        iptables -A INPUT -p tcp --dport "$PORT" -j ACCEPT
    fi

    echo "${IP_PPP}:${PORT}:fibre123:fibrebe123" >>"$PROXY_LIST_RAW"
    PH2_OK=$((PH2_OK + 1))
    return 0
}

echo "Phase 2: configuring routes and proxies..."
echo

PH2_DONE=0

for i in $(seq 0 $((COUNT - 1))); do
    IP_PPP=""
    T=0
    while [ "$T" -lt "$WAIT_IP" ]; do
        IP_PPP=$(get_ppp_ip "ppp$i")
        is_valid_ppp_ip "$IP_PPP" && break
        IP_PPP=""
        sleep 1
        T=$((T + 1))
    done

    if [ -n "$IP_PPP" ]; then
        configure_session "$i" "$IP_PPP" || FAILED_IDX+=("$i")
    else
        # Pas d'IP pour l'instant : pppd continue d'essayer tout seul,
        # on revérifiera pendant les tours de rattrapage
        PENDING+=("$i")
    fi

    PH2_DONE=$((PH2_DONE + 1))
    progress_bar "$PH2_DONE" "$COUNT" "Phase 2" "$PINK" "$PINK_BG"
done

echo
echo
echo -e "First pass: ${GREEN}${PH2_OK}${RESET} up, ${YELLOW}${#PENDING[@]}${RESET} pending"

############################################
# 8a. Tours de rattrapage des sessions ratées
############################################

ROUND=1
while [ "${#PENDING[@]}" -gt 0 ] && [ "$ROUND" -le "$RETRY_ROUNDS" ]; do
    echo -e "${YELLOW}Retry round ${ROUND}/${RETRY_ROUNDS}: ${#PENDING[@]} sessions pending, waiting ${RETRY_WAIT}s...${RESET}"
    sleep "$RETRY_WAIT"

    STILL=()
    RECOVERED=0
    for i in "${PENDING[@]}"; do
        IP_PPP=$(get_ppp_ip "ppp$i")
        if is_valid_ppp_ip "$IP_PPP"; then
            if configure_session "$i" "$IP_PPP"; then
                RECOVERED=$((RECOVERED + 1))
            else
                FAILED_IDX+=("$i")
            fi
        else
            # pppd mort ? on le relance (une session à la fois, doucement)
            if ! ppp_session_running "$i"; then
                pppd call "pppoe$i" >/dev/null 2>&1 &
                sleep "$START_DELAY"
            fi
            STILL+=("$i")
        fi
    done

    echo -e "  -> recovered: ${GREEN}${RECOVERED}${RESET}, still pending: ${YELLOW}${#STILL[@]}${RESET}"
    PENDING=("${STILL[@]}")
    ROUND=$((ROUND + 1))
done

# Celles qui n'ont jamais marché : on arrête pppd (pas de spam vers le FAI)
for i in "${PENDING[@]}"; do
    stop_ppp_session "$i"
    FAILED_IDX+=("$i")
done

echo
echo -e "PPPoE sessions established: ${GREEN}${PH2_OK}${RESET} / ${COUNT}"

############################################
# 8b. Diagnostic des sessions échouées
############################################

if [ "${#FAILED_IDX[@]}" -gt 0 ]; then
    echo -e "${RED}Failed PPPoE sessions: ${#FAILED_IDX[@]}${RESET}"
    echo -e "${YELLOW}Reasons found in pppd logs:${RESET}"
    for i in "${FAILED_IDX[@]}"; do
        grep -hoiE "Timeout waiting for PAD[OS] packets|PAP authentication failed|CHAP authentication failed|Generic-Error.*|AC-System-Error.*|Service-Name-Error.*|No response to [0-9]+ echo-requests|LCP: timeout.*|Connection terminated|Modem hangup" \
            "/var/log/pppoe_${i}.log" 2>/dev/null | tail -n1 || echo "(no clear reason in log)"
    done | sort | uniq -c | sort -rn
    echo
fi

############################################
# 9. Route par défaut via ppp0 (seulement si ppp0 a une vraie IP)
############################################

if is_valid_ppp_ip "$(get_ppp_ip ppp0)"; then
    ip route del default dev "$WAN_IF" >/dev/null 2>&1 || true
    ip route add default dev ppp0 >/dev/null 2>&1 || true
fi

############################################
# 10. Mini serveur HTTP pour proxies.txt
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
# 11. Démarrage des instances 3proxy
############################################

echo
echo "Starting 3proxy with generated configurations..."

if grep -q '^proxy ' "$THREEPROXY_CFG1"; then
    "$THREEPROXY_BIN" "$THREEPROXY_CFG1" &
    echo " -> 3proxy instance 1 started (ports from ${BASE_PORT1})"
fi

if grep -q '^proxy ' "$THREEPROXY_CFG2"; then
    "$THREEPROXY_BIN" "$THREEPROXY_CFG2" &
    echo " -> 3proxy instance 2 started (ports from ${BASE_PORT2})"
fi

sleep 2
echo
echo "Done."

############################################
# 12. Vérification initiale des proxies
############################################

echo -e "Running initial proxy verification (keeping only ${GREEN}STATUS OK${RESET} proxies)..."

TMP_FILE=$(mktemp)
EXPORT_OK=0
EXPORT_FAIL=0

while IFS=':' read -r HOST PORT USER PASS; do
    [ -z "$HOST" ] && continue

    if [ -n "$USER" ] && [ -n "$PASS" ]; then
        PROXY_URL="http://${USER}:${PASS}@${HOST}:${PORT}"
    else
        PROXY_URL="http://${HOST}:${PORT}"
    fi

    PUBLIC_IP=$(curl -sS --max-time 10 -x "$PROXY_URL" https://ipv4.icanhazip.com 2>/dev/null | tr -d '\r\n' || true)

    if [ -n "$PUBLIC_IP" ] && [ "$PUBLIC_IP" = "$HOST" ]; then
        if [ -n "$USER" ] && [ -n "$PASS" ]; then
            echo "${HOST}:${PORT}:${USER}:${PASS}" >>"$TMP_FILE"
        else
            echo "${HOST}:${PORT}" >>"$TMP_FILE"
        fi
        EXPORT_OK=$((EXPORT_OK+1))
        echo -e "${HOST}:${PORT} -> ${PUBLIC_IP} ${GREEN}STATUS OK (KEPT)${RESET}"
    else
        EXPORT_FAIL=$((EXPORT_FAIL+1))
        IDX=$(get_ppp_index_from_port "$PORT" || true)
        NOW_IP=$(get_ppp_ip "ppp${IDX}")
        if [ -z "$PUBLIC_IP" ]; then
            echo -e "${HOST}:${PORT} -> ${RED}STATUS FAIL (no response, REMOVED)${RESET} [ppp${IDX} now: ${NOW_IP:-down}]"
        else
            echo -e "${HOST}:${PORT} -> ${PUBLIC_IP} ${RED}STATUS MISMATCH (REMOVED)${RESET}"
        fi
    fi
done < "$PROXY_LIST_RAW"

mv "$TMP_FILE" "$PROXY_LIST_FILE"
chmod 644 "$PROXY_LIST_FILE"

echo "Initial export filter summary:"
echo -e "  ${GREEN}OK proxies kept${RESET} : ${EXPORT_OK}"
echo -e "  ${RED}Removed (bad)${RESET}    : ${EXPORT_FAIL}"

echo "Proxy list available in: ${PROXY_LIST_FILE}"

echo
echo "Starting live proxy health check (Ctrl+C to stop)..."

############################################
# 13. Boucle de health-check live
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

    while IFS=':' read -r HOST PORT USER PASS; do
        [ -z "$HOST" ] && continue

        if [ -n "$USER" ] && [ -n "$PASS" ]; then
            PROXY_URL="http://${USER}:${PASS}@${HOST}:${PORT}"
        else
            PROXY_URL="http://${HOST}:${PORT}"
        fi

        if curl -sS --max-time 20 -x "$PROXY_URL" https://www.google.com >/dev/null 2>&1; then
            echo -e "${HOST}:${PORT} -> ${GREEN}STATUS OK !${RESET}"
            OK_COUNT=$((OK_COUNT+1))
        else
            echo -e "${HOST}:${PORT} -> ${RED}STATUS FAIL${RESET}"
            FAIL_COUNT=$((FAIL_COUNT+1))
            FAILED_LIST+="${HOST}:${PORT}\n"
        fi
    done < "$PROXY_LIST_FILE"

    TOTAL=$((OK_COUNT + FAIL_COUNT))

    echo "----------------------------------------------"
    echo -e " ${YELLOW}Summary for this check:${RESET}"
    echo -e "  ${ORANGE}Total proxies tested${RESET} : ${TOTAL}"
    echo -e "  ${GREEN}STATUS OK${RESET}            : ${GREEN}${OK_COUNT}${RESET}"
    echo -e "  ${RED}Failed${RESET}               : ${RED}${FAIL_COUNT}${RESET}"

    if [ "$FAIL_COUNT" -gt 0 ]; then
        echo
        echo -e "${RED}Failed proxies list:${RESET}"
        printf '%b' "$FAILED_LIST"
        echo
    fi

    echo -e " ${BLUE}Next check in 60 Sec... (Press Ctrl+C to stop)${RESET}"
    sleep 60
done
