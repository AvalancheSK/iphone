#!/usr/bin/env bash
# Spustí všetko potrebné na pozadí: tunel do iPhonu, presmerovanie portov,
# WebDriverAgent na iPhone a živý náhľad obrazovky v prehliadači.
# Dá sa spustiť opakovane – čo už beží, preskočí.
#
#   ./scripts/start.sh            spustí všetko a otvorí náhľad v prehliadači
#   ./scripts/start.sh --no-open  neotvára prehliadač

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
load_config
mkdir -p "$LOG_DIR"

open_browser=1
[[ "${1:-}" == "--no-open" ]] && open_browser=0

command -v ios >/dev/null 2>&1 || die "Chýba go-ios – spusti ./scripts/setup.sh"

# --- 1. iPhone ----------------------------------------------------------------
device_connected || die "iPhone ($DEVICE_UDID) nie je pripojený. Pripoj ho USB káblom, odomkni a skús znova."
ok "iPhone je pripojený"

# --- 2. Tunel (iOS 17+ ho potrebuje na komunikáciu s go-ios / mobile-mcp) -------
if port_open "$TUNNEL_INFO_PORT"; then
  ok "Tunel už beží"
else
  info "Spúšťam tunel"
  mkdir -p "$RUN_DIR/pair-records"
  start_bg tunnel ios tunnel start --userspace --pair-record-path="$RUN_DIR/pair-records"
  wait_until 30 port_open "$TUNNEL_INFO_PORT" || die "Tunel sa nespustil, pozri $LOG_DIR/tunnel.log"
  ok "Tunel beží"
fi

# --- 3. Presmerovanie portov 8100 (ovládanie) a 9100 (obraz) --------------------
if is_running forward; then
  ok "Presmerovanie portov už beží"
elif port_open "$WDA_PORT"; then
  warn "Port $WDA_PORT už používa iný proces – predpokladám, že je to presmerovanie do iPhonu."
else
  info "Presmerovávam porty $WDA_PORT a $MJPEG_PORT do iPhonu"
  start_bg forward ios forward --udid="$DEVICE_UDID" --port="$WDA_PORT:$WDA_PORT" --port="$MJPEG_PORT:$MJPEG_PORT"
  wait_until 15 port_open "$WDA_PORT" || die "Presmerovanie portov zlyhalo, pozri $LOG_DIR/forward.log"
  ok "Porty sú presmerované"
fi

# --- 4. WebDriverAgent na iPhone -----------------------------------------------
if wda_ready; then
  ok "WebDriverAgent už beží"
else
  stop_bg wda >/dev/null
  info "Spúšťam WebDriverAgent na iPhone (nechaj iPhone odomknutý, môže to trvať 1–2 minúty)…"
  wda_args
  start_bg wda xcodebuild build-for-testing test-without-building "${WDA_ARGS[@]}"
  waited=0
  until wda_ready; do
    if ! is_running wda; then
      explain_xcode_failure "$LOG_DIR/wda.log"
      die "WebDriverAgent sa nespustil."
    fi
    if ((waited >= 240)); then
      explain_xcode_failure "$LOG_DIR/wda.log"
      die "WebDriverAgent neodpovedá ani po 4 minútach."
    fi
    sleep 2
    waited=$((waited + 2))
  done
  ok "WebDriverAgent beží"
fi

# --- 5. Náhľad obrazovky -------------------------------------------------------
if is_running viewer; then
  ok "Náhľad už beží"
else
  start_bg viewer python3 "$ROOT_DIR/viewer/server.py" --port "$VIEWER_PORT"
  wait_until 10 port_open "$VIEWER_PORT" || die "Náhľad sa nespustil, pozri $LOG_DIR/viewer.log"
  ok "Náhľad beží"
fi

viewer_url="http://127.0.0.1:$VIEWER_PORT"
if ((open_browser)); then
  open "$viewer_url" 2>/dev/null || true
fi

cat <<DONE

Všetko beží.
  Náhľad iPhonu:   $viewer_url
  Claude Code:     v tomto priečinku spusti  claude  a napíš napr. „Odfoť obrazovku iPhonu“
  Zastavenie:      ./scripts/stop.sh
DONE
