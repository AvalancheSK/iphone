#!/usr/bin/env bash
# Jednorazová príprava: skontroluje nástroje, stiahne a podpíše WebDriverAgent
# a uloží nastavenia do config.env. Dá sa bezpečne spustiť opakovane.
#
# Voliteľné premenné prostredia:
#   DEVICE_UDID=...   vyber konkrétny iPhone (ak ich je pripojených viac)
#   TEAM_ID=...       vyber konkrétny Apple vývojársky tím (10 znakov)

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

[[ "$(uname)" == "Darwin" ]] || die "Tento skript beží iba na macOS (na MacBooku)."

# Predvolené hodnoty z predchádzajúceho behu (premenné prostredia majú prednosť).
if [[ -f "$CONFIG_FILE" ]]; then
  prev_udid="$(sed -n 's/^DEVICE_UDID=//p' "$CONFIG_FILE")"
  prev_team="$(sed -n 's/^TEAM_ID=//p' "$CONFIG_FILE")"
  prev_bundle="$(sed -n 's/^WDA_BUNDLE_ID=//p' "$CONFIG_FILE")"
fi
DEVICE_UDID="${DEVICE_UDID:-${prev_udid:-}}"
TEAM_ID="${TEAM_ID:-${prev_team:-}}"
WDA_BUNDLE_ID="${WDA_BUNDLE_ID:-${prev_bundle:-}}"

# --- 1. Xcode -----------------------------------------------------------------
info "Kontrolujem Xcode"
if ! xcode_out="$(xcodebuild -version 2>&1)"; then
  die "Xcode nie je pripravený: $xcode_out
      Nainštaluj Xcode z App Store, raz ho spusti (licencia a komponenty) a potom:
      sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
fi
ok "$(xcodebuild -version | head -n 1)"

# --- 2. Node.js 20+ -----------------------------------------------------------
info "Kontrolujem Node.js"
if ! command -v node >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    brew install node
  else
    die "Chýba Node.js 20+. Nainštaluj ho z https://nodejs.org alebo cez Homebrew (https://brew.sh)."
  fi
fi
node_major="$(node -p 'process.versions.node.split(".")[0]')"
((node_major >= 20)) || die "Potrebujem Node.js 20 alebo novší (máš $(node -v))."
ok "Node.js $(node -v)"

# --- 3. go-ios (tunel a presmerovanie portov do iPhonu) -----------------------
info "Kontrolujem go-ios"
if ! command -v ios >/dev/null 2>&1; then
  npm install -g go-ios || die "Inštalácia go-ios zlyhala. Skús: sudo npm install -g go-ios"
fi
ok "go-ios: $(command -v ios)"

# --- 4. WebDriverAgent ---------------------------------------------------------
info "Pripravujem WebDriverAgent ($WDA_REF)"
if [[ ! -d "$WDA_DIR/.git" ]]; then
  mkdir -p "$(dirname "$WDA_DIR")"
  git clone --quiet --depth 1 --branch "$WDA_REF" https://github.com/appium/WebDriverAgent.git "$WDA_DIR"
fi
ok "WebDriverAgent: $WDA_DIR"

# --- 5. iPhone -----------------------------------------------------------------
info "Hľadám pripojený iPhone"
list_devices() {
  local json
  json="$(ios list --details 2>/dev/null | grep '^{' | tail -n 1)" \
    || json="$(ios list 2>/dev/null | grep '^{' | tail -n 1)" \
    || json='{"deviceList":[]}'
  printf '%s' "$json" | python3 -c '
import json, sys
seen = set()
for d in json.load(sys.stdin).get("deviceList") or []:
    if isinstance(d, str):
        d = {"Udid": d}
    udid = d.get("Udid")
    if not udid or udid in seen:
        continue
    seen.add(udid)
    print("\t".join([udid, d.get("ProductName") or "iPhone", d.get("ProductVersion") or "?"]))
'
}

devices=()
while IFS= read -r line; do
  if [[ -n "$line" ]]; then devices+=("$line"); fi
done < <(list_devices)

if ((${#devices[@]} == 0)); then
  die "Nevidím žiadny iPhone. Skontroluj:
      1. iPhone je pripojený USB káblom k MacBooku a je odomknutý,
      2. na iPhone si potvrdil „Dôverovať tomuto počítaču“,
      3. potom spusti tento skript znova."
fi

chosen=""
if [[ -n "$DEVICE_UDID" ]]; then
  for d in "${devices[@]}"; do
    if [[ "${d%%"$TAB"*}" == "$DEVICE_UDID" ]]; then chosen="$d"; fi
  done
  [[ -n "$chosen" ]] || warn "Uložený iPhone $DEVICE_UDID nie je pripojený, vyberám znova."
fi
if [[ -z "$chosen" ]]; then
  if ((${#devices[@]} == 1)); then
    chosen="${devices[0]}"
  else
    echo "Pripojené zariadenia:"
    i=1
    for d in "${devices[@]}"; do
      echo "  $i) $(echo "$d" | tr '\t' ' ')"
      i=$((i + 1))
    done
    read -r -p "Ktoré použiť? [1-${#devices[@]}] " n || die "Spusti znova s DEVICE_UDID=<udid> ./scripts/setup.sh"
    [[ "$n" =~ ^[0-9]+$ ]] && ((n >= 1 && n <= ${#devices[@]})) || die "Neplatná voľba."
    chosen="${devices[$((n - 1))]}"
  fi
fi
DEVICE_UDID="${chosen%%"$TAB"*}"
ok "iPhone: $(echo "$chosen" | tr '\t' ' ')"

devmode="$(ios devmode get --udid="$DEVICE_UDID" 2>/dev/null || true)"
if [[ "$devmode" =~ \"DeveloperModeEnabled\":\ ?false ]]; then
  ios devmode reveal --udid="$DEVICE_UDID" >/dev/null 2>&1 || true
  die "Na iPhone treba zapnúť Režim vývojára:
      Nastavenia → Súkromie a bezpečnosť → Režim vývojára → zapnúť → reštartovať → potvrdiť.
      Potom spusti tento skript znova."
fi

# --- 6. Apple vývojársky tím (podpisovanie) ------------------------------------
info "Hľadám Apple Development certifikát"
detect_teams() {
  local tmp f subj team cn
  tmp="$(mktemp -d)"
  security find-certificate -a -c "Apple Development" -p >"$tmp/all.pem" 2>/dev/null || true
  awk -v dir="$tmp" '/-----BEGIN CERTIFICATE-----/ { n++ } n { print > (dir "/c" n ".pem") }' "$tmp/all.pem"
  for f in "$tmp"/c*.pem; do
    [[ -f "$f" ]] || continue
    openssl x509 -noout -checkend 0 -in "$f" >/dev/null 2>&1 || continue # preskoč expirované
    subj="$(openssl x509 -noout -subject -in "$f" 2>/dev/null)" || continue
    team="$(printf '%s' "$subj" | grep -oE 'OU ?= ?[A-Z0-9]{10}' | grep -oE '[A-Z0-9]{10}$' || true)"
    cn="$(printf '%s' "$subj" | grep -oE 'CN ?= ?[^,/]+' | sed -E 's/^CN ?= ?//' || true)"
    if [[ -n "$team" ]]; then
      printf '%s\t%s\n' "$team" "$cn"
    fi
  done | sort -u -t "$TAB" -k1,1
  rm -rf "$tmp"
}

if [[ -z "$TEAM_ID" ]]; then
  teams=()
  while IFS= read -r line; do
    if [[ -n "$line" ]]; then teams+=("$line"); fi
  done < <(detect_teams)

  if ((${#teams[@]} == 0)); then
    die "Nenašiel som Apple Development certifikát. Urob v Xcode (stačí bezplatný Apple ID):
      1. Xcode → Settings → Accounts → + → Apple ID → prihlás sa,
      2. vyber svoj tím (Personal Team) → Manage Certificates… → + → Apple Development,
      3. spusti tento skript znova."
  elif ((${#teams[@]} == 1)); then
    TEAM_ID="${teams[0]%%"$TAB"*}"
  else
    echo "Našiel som viac tímov:"
    i=1
    for t in "${teams[@]}"; do
      echo "  $i) $(echo "$t" | tr '\t' ' ')"
      i=$((i + 1))
    done
    read -r -p "Ktorý použiť? [1-${#teams[@]}] " n || die "Spusti znova s TEAM_ID=<tím> ./scripts/setup.sh"
    [[ "$n" =~ ^[0-9]+$ ]] && ((n >= 1 && n <= ${#teams[@]})) || die "Neplatná voľba."
    TEAM_ID="${teams[$((n - 1))]%%"$TAB"*}"
  fi
fi
ok "Tím: $TEAM_ID"

if [[ -z "$WDA_BUNDLE_ID" ]]; then
  user_part="$(id -un | LC_ALL=C tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]')"
  WDA_BUNDLE_ID="com.${user_part:-user}.wda$(openssl rand -hex 3)"
fi
ok "Bundle ID: $WDA_BUNDLE_ID"

cat >"$CONFIG_FILE" <<CONF
# Vygenerované skriptom scripts/setup.sh – môžeš upraviť ručne.
DEVICE_UDID=$DEVICE_UDID
TEAM_ID=$TEAM_ID
WDA_BUNDLE_ID=$WDA_BUNDLE_ID
CONF
ok "Uložené do config.env"

# --- 7. Build a podpísanie WebDriverAgentu -------------------------------------
info "Kompilujem a podpisujem WebDriverAgent (prvýkrát to trvá pár minút)…"
mkdir -p "$LOG_DIR"
wda_args
if ! xcodebuild build-for-testing "${WDA_ARGS[@]}" >"$LOG_DIR/build.log" 2>&1; then
  explain_xcode_failure "$LOG_DIR/build.log"
  die "Kompilácia WebDriverAgentu zlyhala."
fi
ok "WebDriverAgent je pripravený"

# --- 8. MCP server pre Claude Code (predstiahnutie, aby prvý štart nebol pomalý) --
info "Sťahujem mobile-mcp pre Claude Code"
mcp_pkg="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["mcpServers"]["mobile-mcp"]["args"][1])' "$ROOT_DIR/.mcp.json")"
if npm exec --yes --package="$mcp_pkg" -- true >/dev/null 2>&1; then
  ok "$mcp_pkg"
else
  warn "Predstiahnutie $mcp_pkg zlyhalo – Claude Code ho stiahne pri prvom štarte."
fi

cat <<'DONE'

Hotovo. Ešte dve veci na iPhone (iba raz):
  1. Nastavenia → Všeobecné → Správa VPN a zariadení → Apple Development → Dôverovať
     (táto položka sa objaví až po prvom spustení ./scripts/start.sh)
  2. Nastavenia → Vývojár → Enable UI Automation → zapnúť

Potom spusti:  ./scripts/start.sh
DONE
