#!/usr/bin/env bash
# wifi-monitor.sh — real-time WiFi signal monitor for macOS

# ── colors ───────────────────────────────────────────────────────────────────
RED=$'\033[0;31m'   YEL=$'\033[0;33m'   GRN=$'\033[0;32m'
BLU=$'\033[0;34m'   CYN=$'\033[0;36m'   WHT=$'\033[1;37m'
BOLD=$'\033[1m'     DIM=$'\033[2m'       RST=$'\033[0m'

SPARK_CHARS=('▁' '▂' '▃' '▄' '▅' '▆' '▇' '█')
declare -a HISTORY
MAX_HIST=60

# ── helpers ───────────────────────────────────────────────────────────────────

bar() {               # bar <pct 0-100> <width> <color>
    local pct=$1 width=$2 color=$3
    local filled=$(( pct * width / 100 ))
    (( filled > width )) && filled=$width
    local empty=$(( width - filled ))
    printf '%s' "$color"
    for (( i=0; i<filled; i++ )); do printf '█'; done
    printf '%s' "$DIM"
    for (( i=0; i<empty;  i++ )); do printf '░'; done
    printf '%s' "$RST"
}

spark_char() {        # RSSI → one spark glyph (−95 dBm = ▁, −30 dBm = ▇)
    local v=$1
    local idx=$(( (v + 95) * 7 / 65 ))
    (( idx < 0 )) && idx=0
    (( idx > 7 )) && idx=7
    printf '%s' "${SPARK_CHARS[$idx]}"
}

rssi_col() {
    local v=$1
    (( v >= -60 )) && { printf '%s' "$GRN"; return; }
    (( v >= -70 )) && { printf '%s' "$YEL"; return; }
    printf '%s' "$RED"
}

rssi_label() {
    local v=$1
    (( v >= -50 )) && { printf 'Excellent'; return; }
    (( v >= -60 )) && { printf 'Good     '; return; }
    (( v >= -70 )) && { printf 'Fair     '; return; }
    printf 'Poor     '
}

snr_col() {
    local v=$1
    (( v >= 25 )) && { printf '%s' "$GRN"; return; }
    (( v >= 15 )) && { printf '%s' "$YEL"; return; }
    printf '%s' "$RED"
}

snr_label() {
    local v=$1
    (( v >= 40 )) && { printf 'Excellent'; return; }
    (( v >= 25 )) && { printf 'Good     '; return; }
    (( v >= 15 )) && { printf 'Fair     '; return; }
    printf 'Poor     '
}

thick() { printf "${CYN}${BOLD}  %s${RST}\n" "══════════════════════════════════════════════════════════════"; }
thin()  { printf "${DIM}${CYN}  %s${RST}\n"  "──────────────────────────────────────────────────────────────"; }
lf()    { printf '\n'; }

# ── compile Swift helper ──────────────────────────────────────────────────────
# Uses CoreWLAN directly — runs in ~20ms vs system_profiler's ~4s.

HELPER=/tmp/wifi_monitor_helper_$$
HELPER_SRC="${HELPER}.swift"

cat > "$HELPER_SRC" << 'SWIFT'
import CoreWLAN
import Foundation

guard let iface = CWWiFiClient.shared().interface() else { exit(1) }

let rssi   = iface.rssiValue()
let noise  = iface.noiseMeasurement()
let txrate = iface.transmitRate()
let ssid   = iface.ssid() ?? "<redacted>"
let ch     = iface.wlanChannel()
let chNum  = ch?.channelNumber ?? 0
let chBand = ch?.channelBand == .band5GHz ? "5GHz" :
             ch?.channelBand == .band2GHz ? "2GHz" :
             ch?.channelBand == .band6GHz ? "6GHz" : "?"
let chWidth = ch?.channelWidth == .width20MHz  ? "20MHz"  :
              ch?.channelWidth == .width40MHz  ? "40MHz"  :
              ch?.channelWidth == .width80MHz  ? "80MHz"  :
              ch?.channelWidth == .width160MHz ? "160MHz" : "?"
let phy    = iface.activePHYMode()
let phyStr = phy == .mode11ax ? "802.11ax" :
             phy == .mode11ac ? "802.11ac" :
             phy == .mode11n  ? "802.11n"  :
             phy == .mode11a  ? "802.11a"  :
             phy == .mode11b  ? "802.11b"  :
             phy == .mode11g  ? "802.11g"  : "unknown"
let sec    = iface.security()
let secStr = sec == .wpa2Personal   ? "WPA2 Personal"   :
             sec == .wpa2Enterprise ? "WPA2 Enterprise" :
             sec == .wpa3Personal   ? "WPA3 Personal"   :
             sec == .wpa3Enterprise ? "WPA3 Enterprise" :
             sec == .wpaPersonal    ? "WPA Personal"    :
             sec == .none           ? "Open"            : "WPA"

print("RSSI=\(rssi)")
print("NOISE=\(noise)")
print("TXRATE=\(Int(txrate))")
print("SSID=\(ssid)")
print("CHANNEL=\(chNum)")
print("BAND=\(chBand)")
print("WIDTH=\(chWidth)")
print("PHY=\(phyStr)")
print("SECURITY=\(secStr)")
SWIFT

printf "\n  ${DIM}Compiling WiFi helper (one-time, ~1s)…${RST} "
if ! swiftc "$HELPER_SRC" -o "$HELPER" 2>/dev/null; then
    printf "${RED}failed.${RST}\n  Falling back to system_profiler.\n"
    USE_HELPER=0
else
    printf "${GRN}done.${RST}\n"
    USE_HELPER=1
fi
rm -f "$HELPER_SRC"

# ── background slow-field refresh (MCS index via system_profiler) ─────────────
# system_profiler takes ~4s; run it in background and update a cache file.

SP_CACHE=/tmp/wifi_monitor_sp_$$
mcs=""; nettype="Infrastructure"; country="?"

sp_refresh() {
    while true; do
        local raw cur
        raw=$(system_profiler SPAirPortDataType 2>/dev/null)
        cur=$(echo "$raw" | awk '/Current Network Information:/{f=1;next} f&&/Other Local Wi-Fi/{exit} f{print}')
        {
            echo "MCS=$(echo "$cur"     | awk -F'MCS Index: '    '/MCS Index:/{print $2;exit}' | xargs)"
            echo "NETTYPE=$(echo "$cur" | awk -F'Network Type: ' '/Network Type:/{print $2;exit}' | xargs)"
            echo "COUNTRY=$(echo "$cur" | awk -F'Country Code: ' '/Country Code:/{print $2;exit}' | xargs)"
        } > "$SP_CACHE"
    done
}
sp_refresh &
SP_PID=$!

# ── cleanup ───────────────────────────────────────────────────────────────────

cleanup() {
    kill "$SP_PID" 2>/dev/null
    rm -f "$HELPER" "$SP_CACHE"
    tput cnorm
    printf '%s\n' "$RST"
    exit 0
}
trap cleanup INT TERM
tput civis

# ── main loop ────────────────────────────────────────────────────────────────

while true; do
    # Fast path: Swift binary (~20ms) or slow path: system_profiler (~4s)
    if (( USE_HELPER )); then
        raw=$("$HELPER" 2>/dev/null)
        if [[ -z "$raw" ]]; then
            clear; lf
            printf "  ${RED}${BOLD}Not connected to WiFi${RST}\n"
            printf "  ${DIM}%s — retrying…${RST}\n" "$(date '+%H:%M:%S')"
            sleep 1; continue
        fi
        rssi=$(echo    "$raw" | awk -F= '/^RSSI=/{print $2}')
        noise=$(echo   "$raw" | awk -F= '/^NOISE=/{print $2}')
        tx_rate=$(echo "$raw" | awk -F= '/^TXRATE=/{print $2}')
        ssid=$(echo    "$raw" | awk -F= '/^SSID=/{print $2}')
        chnum=$(echo   "$raw" | awk -F= '/^CHANNEL=/{print $2}')
        band=$(echo    "$raw" | awk -F= '/^BAND=/{print $2}')
        width=$(echo   "$raw" | awk -F= '/^WIDTH=/{print $2}')
        phy=$(echo     "$raw" | awk -F= '/^PHY=/{print $2}')
        security=$(echo "$raw" | awk -F= '/^SECURITY=/{print $2}')
        channel="$chnum ($band, $width)"
    else
        sp_raw=$(system_profiler SPAirPortDataType 2>/dev/null)
        status=$(echo "$sp_raw" | awk '/Status:/{print $2; exit}')
        if [[ "$status" != "Connected" ]]; then
            clear; lf
            printf "  ${RED}${BOLD}Not connected to WiFi${RST}\n"
            printf "  ${DIM}%s — retrying…${RST}\n" "$(date '+%H:%M:%S')"
            sleep 1; continue
        fi
        cur=$(echo "$sp_raw" | awk '/Current Network Information:/{f=1;next} f&&/Other Local Wi-Fi/{exit} f{print}')
        sig=$(echo "$cur" | grep "Signal / Noise:")
        rssi=$(echo  "$sig" | grep -oE '\-[0-9]+' | sed -n '1p')
        noise=$(echo "$sig" | grep -oE '\-[0-9]+' | sed -n '2p')
        [[ -z "$rssi" ]] && rssi=-80; [[ -z "$noise" ]] && noise=-90
        tx_rate=$(echo "$cur" | awk -F'Transmit Rate: ' '/Transmit Rate:/{print $2;exit}' | xargs)
        ssid=$(echo    "$cur" | awk 'NF&&/:$/{gsub(/^[[:space:]]+/,"");gsub(/:$/,"");print;exit}')
        channel=$(echo "$cur" | awk -F'Channel: '  '/Channel:/{print $2;exit}' | xargs)
        phy=$(echo     "$cur" | awk -F'PHY Mode: ' '/PHY Mode:/{print $2;exit}' | xargs)
        security=$(echo "$cur"| awk -F'Security: ' '/Security:/{print $2;exit}' | xargs)
    fi

    # Read slow-path cache (MCS, net type, country) if available
    if [[ -s "$SP_CACHE" ]]; then
        mcs=$(     awk -F= '/^MCS=/{print $2}'     "$SP_CACHE")
        nettype=$( awk -F= '/^NETTYPE=/{print $2}' "$SP_CACHE")
        country=$( awk -F= '/^COUNTRY=/{print $2}' "$SP_CACHE")
    fi

    [[ -z "$ssid"    ]] && ssid="<redacted>"
    [[ -z "$mcs"     ]] && mcs="—"
    [[ -z "$country" ]] && country="—"
    [[ -z "$nettype" ]] && nettype="—"

    snr=$(( rssi - noise ))

    # WiFi generation
    case "$phy" in
        *ax*) wifi_gen="WiFi 6/6E" ;;
        *ac*) wifi_gen="WiFi 5"    ;;
        *n*)  wifi_gen="WiFi 4"    ;;
        *)    wifi_gen=""          ;;
    esac

    # Rolling history
    HISTORY+=("$rssi")
    (( ${#HISTORY[@]} > MAX_HIST )) && HISTORY=("${HISTORY[@]:1}")

    # Bar percentages
    rssi_pct=$(( (rssi + 95) * 100 / 65 ))
    (( rssi_pct < 0   )) && rssi_pct=0
    (( rssi_pct > 100 )) && rssi_pct=100

    noise_inv=$(( 100 - (noise + 100) * 100 / 30 ))
    (( noise_inv < 0   )) && noise_inv=0
    (( noise_inv > 100 )) && noise_inv=100

    snr_pct=$(( snr * 100 / 60 ))
    (( snr_pct < 0   )) && snr_pct=0
    (( snr_pct > 100 )) && snr_pct=100

    # Sparkline
    spark=""
    for v in "${HISTORY[@]}"; do spark+=$(spark_char "$v"); done

    # ── render ───────────────────────────────────────────────────────────────

    clear

    thick
    printf "  ${CYN}${BOLD}║${RST}       ${BOLD}WiFi Signal Monitor${RST}  •  ${DIM}%s${RST}             ${CYN}${BOLD}║${RST}\n" \
           "$(date '+%H:%M:%S')"
    thick

    lf
    printf "  ${BOLD}%-12s${RST} ${WHT}%s${RST}\n" "SSID:" "$ssid"
    printf "  ${BOLD}%-12s${RST} ${WHT}%-26s${RST}${BOLD}%-10s${RST} ${WHT}%s${RST}\n" \
           "PHY Mode:" "$phy  ($wifi_gen)" "Security:" "$security"
    printf "  ${BOLD}%-12s${RST} ${WHT}%-26s${RST}${BOLD}%-10s${RST} ${WHT}%s${RST}\n" \
           "Channel:" "$channel" "Country:" "$country"
    [[ -n "$tx_rate" ]] && \
    printf "  ${BOLD}%-12s${RST} ${WHT}%-26s${RST}${BOLD}%-10s${RST} ${WHT}%s${RST}\n" \
           "TX Rate:" "${tx_rate} Mbps" "MCS Index:" "$mcs"
    printf "  ${BOLD}%-12s${RST} ${WHT}%s${RST}\n" "Net Type:" "$nettype"
    lf

    thin
    printf "  ${BOLD}SIGNAL QUALITY${RST}\n"
    thin
    lf

    rc=$(rssi_col "$rssi")
    sc=$(snr_col  "$snr")

    printf "  ${BOLD}RSSI   ${RST}${rc}${BOLD}%5d dBm${RST}  " "$rssi"
    bar "$rssi_pct" 28 "$rc"
    printf "  ${rc}$(rssi_label "$rssi")${RST}\n"

    printf "  ${BOLD}Noise  ${RST}${DIM}%5d dBm${RST}  " "$noise"
    bar "$noise_inv" 28 "${DIM}${BLU}"
    printf "  ${DIM}noise floor${RST}\n"

    printf "  ${BOLD}SNR    ${RST}${sc}${BOLD}%5d dB ${RST}   " "$snr"
    bar "$snr_pct"  28 "$sc"
    printf "  ${sc}$(snr_label "$snr")${RST}\n"

    lf
    printf "  ${DIM}SNR: <15 dB poor  •  15–24 fair  •  ≥25 good  •  ≥40 excellent${RST}\n"
    lf

    thin
    printf "  ${BOLD}RSSI HISTORY${RST}  ${DIM}(%d/%d samples  ▁ = −95 dBm  →  ▇ = −30 dBm)${RST}\n" \
           "${#HISTORY[@]}" "$MAX_HIST"
    thin
    lf
    printf "  ${GRN}%s${RST}\n" "$spark"
    lf

    thin
    printf "  ${DIM}Refreshing every 1s  •  Ctrl+C to quit${RST}\n"
    thin

    sleep 1
done
