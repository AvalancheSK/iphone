#!/usr/bin/env bash
# Vypíše stav jednotlivých vrstiev spojenia s iPhonom.
# Návratový kód 0 = všetko pripravené, Claude Code môže iPhone ovládať.

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

problems=0
check() {
  local label="$1"
  shift
  if "$@"; then
    ok "$label"
  else
    warn "$label – NEBEŽÍ"
    problems=$((problems + 1))
  fi
}

[[ -f "$CONFIG_FILE" ]] || die "Chýba config.env – spusti ./scripts/setup.sh"
load_config
command -v ios >/dev/null 2>&1 || die "Chýba go-ios – spusti ./scripts/setup.sh"

check "iPhone pripojený ($DEVICE_UDID)" device_connected
check "Tunel (port $TUNNEL_INFO_PORT)" port_open "$TUNNEL_INFO_PORT"
check "Presmerovanie portov ($WDA_PORT, $MJPEG_PORT)" port_open "$WDA_PORT"
check "WebDriverAgent odpovedá" wda_ready
check "Náhľad http://127.0.0.1:$VIEWER_PORT" port_open "$VIEWER_PORT"

if ((problems > 0)); then
  echo
  warn "Niečo nebeží – spusti ./scripts/start.sh (logy sú v .run/logs/)."
  exit 1
fi
