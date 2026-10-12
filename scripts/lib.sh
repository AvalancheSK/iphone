#!/usr/bin/env bash
# shellcheck disable=SC2034 # premenné tu len definujem, používajú ich skripty, ktoré lib.sh načítajú
# Spoločné premenné a pomocné funkcie pre skripty v tomto repozitári.
# Píšem kompatibilne s bash 3.2, ktorý je predvolený na macOS.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$ROOT_DIR/config.env"
RUN_DIR="$ROOT_DIR/.run"
LOG_DIR="$RUN_DIR/logs"
WDA_DIR="$ROOT_DIR/vendor/WebDriverAgent"
DERIVED_DATA="$ROOT_DIR/.build/DerivedData"

# Verzia WebDriverAgentu, ktorú setup.sh stiahne (dá sa prepísať premennou prostredia).
WDA_REF="${WDA_REF:-v16.15.0}"

WDA_PORT=8100          # HTTP API WebDriverAgentu (ťuknutia, screenshoty, ...)
MJPEG_PORT=9100        # živý obraz obrazovky (MJPEG)
TUNNEL_INFO_PORT=60105 # HTTP API tunela go-ios (iOS 17+), kontroluje ho aj mobile-mcp
VIEWER_PORT="${VIEWER_PORT:-8200}"
TAB=$'\t'

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m !\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m ✗\033[0m %s\n' "$*" >&2; exit 1; }

load_config() {
  [[ -f "$CONFIG_FILE" ]] || die "Chýba config.env – najprv spusti ./scripts/setup.sh"
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
  [[ -n "${DEVICE_UDID:-}" && -n "${TEAM_ID:-}" && -n "${WDA_BUNDLE_ID:-}" ]] \
    || die "config.env je neúplný – spusti znova ./scripts/setup.sh"
}

port_open() {
  (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

wda_ready() {
  curl -fsS -m 3 "http://127.0.0.1:$WDA_PORT/status" >/dev/null 2>&1
}

pid_file() { echo "$RUN_DIR/$1.pid"; }

is_running() {
  local f
  f="$(pid_file "$1")"
  [[ -f "$f" ]] && kill -0 "$(cat "$f")" 2>/dev/null
}

# start_bg <meno> <príkaz...> – spustí proces na pozadí, log ide do .run/logs/<meno>.log
start_bg() {
  local name="$1"
  shift
  mkdir -p "$LOG_DIR"
  nohup "$@" >"$LOG_DIR/$name.log" 2>&1 &
  echo $! >"$(pid_file "$name")"
}

kill_tree() {
  local pid="$1" child
  for child in $(pgrep -P "$pid" 2>/dev/null || true); do
    kill_tree "$child"
  done
  kill "$pid" 2>/dev/null || true
}

stop_bg() {
  local name="$1" f pid
  f="$(pid_file "$name")"
  if is_running "$name"; then
    pid="$(cat "$f")"
    kill_tree "$pid"
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.5
    done
    kill -9 "$pid" 2>/dev/null || true
    ok "Zastavené: $name"
  fi
  rm -f "$f"
}

# wait_until <timeout_s> <príkaz...> – čaká, kým príkaz neuspeje
wait_until() {
  local timeout="$1" waited=0
  shift
  until "$@"; do
    if ((waited >= timeout)); then
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
}

device_connected() {
  local out
  out="$(ios list 2>/dev/null)" || return 1
  [[ "$out" == *"$DEVICE_UDID"* ]]
}

# Naplní pole WDA_ARGS spoločnými argumentmi pre xcodebuild (build aj spustenie WDA).
wda_args() {
  WDA_ARGS=(
    -project "$WDA_DIR/WebDriverAgent.xcodeproj"
    -scheme WebDriverAgentRunner
    -destination "id=$DEVICE_UDID"
    -derivedDataPath "$DERIVED_DATA"
    -allowProvisioningUpdates
    -allowProvisioningDeviceRegistration
    DEVELOPMENT_TEAM="$TEAM_ID"
    CODE_SIGN_IDENTITY="Apple Development"
    PRODUCT_BUNDLE_IDENTIFIER="$WDA_BUNDLE_ID"
    GCC_TREAT_WARNINGS_AS_ERRORS=0
    COMPILER_INDEX_STORE_ENABLE=NO
  )
}

# Prečíta log z xcodebuild a vysvetlí najčastejšie príčiny zlyhania.
explain_xcode_failure() {
  local log="$1" hinted=0
  [[ -f "$log" ]] || return 0
  echo
  warn "Posledné riadky z $log:"
  grep -E "error|Error|failed|Failed" "$log" | tail -n 8 >&2 || tail -n 15 "$log" >&2
  echo
  if grep -qiE "developer mode" "$log"; then
    warn "Zapni Režim vývojára: iPhone → Nastavenia → Súkromie a bezpečnosť → Režim vývojára. iPhone sa reštartuje."
    hinted=1
  fi
  if grep -qiE "No Account for Team|No Accounts|requires a development team|No signing certificate" "$log"; then
    warn "Xcode nemá prihlásený Apple ID: Xcode → Settings → Accounts → + → Apple ID, potom spusti znova ./scripts/setup.sh"
    hinted=1
  fi
  if grep -qiE "Failed Registering Bundle Identifier|cannot be registered to your development team|No profiles for" "$log"; then
    warn "Bundle ID je obsadené. Zmaž riadok WDA_BUNDLE_ID v config.env a spusti znova ./scripts/setup.sh"
    hinted=1
  fi
  if grep -qiE "Unable to find a destination|is not available because|preparing" "$log"; then
    warn "Xcode iPhone ešte nepripravil: otvor Xcode → Window → Devices and Simulators, nechaj iPhone odomknutý, kým príprava neskončí, a skús znova."
    hinted=1
  fi
  if grep -qiE "maximum number of apps" "$log"; then
    warn "Bezplatný Apple ID dovolí max. 3 vlastné vývojárske appky naraz. Vymaž z iPhonu iné testovacie appky."
    hinted=1
  fi
  if grep -qiE "not been explicitly trusted|untrusted|invalid code signature|inadequate entitlements|Unable to launch" "$log"; then
    warn "Dôveruj vývojárovi na iPhone: Nastavenia → Všeobecné → Správa VPN a zariadení → Apple Development → Dôverovať."
    hinted=1
  fi
  if grep -qiE "UI Automation|automation mode" "$log"; then
    warn "Zapni na iPhone: Nastavenia → Vývojár (Developer) → Enable UI Automation. A iPhone odomkni."
    hinted=1
  fi
  if grep -qiE "locked|passcode" "$log"; then
    warn "iPhone je zamknutý – odomkni ho a skús znova."
    hinted=1
  fi
  if ((hinted == 0)); then
    warn "Pozri celý log: $log (sekcia Riešenie problémov v README.md)."
  fi
}
