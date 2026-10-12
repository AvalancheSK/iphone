#!/usr/bin/env bash
# Zastaví všetko, čo spustil ./scripts/start.sh.

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

info "Zastavujem"
for name in viewer wda forward tunnel; do
  stop_bg "$name"
done
ok "Hotovo"
