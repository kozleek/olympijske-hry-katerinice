#!/usr/bin/env bash
set -euo pipefail

# ==============================================
# Watcher pro nové fotky v KOŘENI projektu (ne podsložky)
# - po změně počká DELAY sekund a spustí overlay-10x13.sh
# - ignoruje _output/, _processed/, frames/ atd.
# - kompatibilní s Bash 3 (macOS)
# ==============================================

DELAY="${1:-10}"                          # čekání v sekundách (default 10)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OVERLAY_SCRIPT="$SCRIPT_DIR/overlay-10x13.sh"
LOCK_FILE="$SCRIPT_DIR/.watch.lock"

# Kontroly závislostí
command -v fswatch >/dev/null 2>&1 || { echo "Chyba: fswatch není nainstalován. Spusť: brew install fswatch"; exit 1; }
[[ -f "$OVERLAY_SCRIPT" ]] || { echo "Chyba: nenalezen $OVERLAY_SCRIPT"; exit 1; }

echo "Sleduji pouze soubory v kořenové složce: $PWD"
echo "Delay: ${DELAY}s"
echo "Přípony: jpg, jpeg, png, heic, heif, tif, tiff"
echo "--------------------------------------------------------"

trigger_job() {
  # Debounce: když už je naplánovaný běh, jen to oznám a neplánuj další
  if [[ -e "$LOCK_FILE" ]]; then
    echo "  (debounce – běh už je naplánován)"
    return
  fi

  : > "$LOCK_FILE"
  (
    sleep "$DELAY"
    echo ">>> Spouštím overlay-10x13.sh"
    bash "$OVERLAY_SCRIPT" --name watch-$(date +%Y-%m-%d)
    echo ">>> Hotovo"
    rm -f "$LOCK_FILE"
  ) &
}

# Pozn.: fswatch bude emitovat JEN události pro soubory v KOŘENI,
# díky include regexu '^\./[^/]+\.(přípony)$' a globálnímu exclude '.*'
# (tj. žádná podsložka).
fswatch -0 -E \
  --event Created --event Renamed --event Updated \
  -i '^\./[^/]+\.(jpg|jpeg|png|heic|heif|tif|tiff)$' \
  -e '.*' \
  . \
| while IFS= read -r -d "" file; do
    # Bezpečnostní filtr navíc: pokud by se sem něco procpalo z podsložek, přeskoč
    rel="${file#./}"
    case "$rel" in
      */*) continue ;;  # obsahuje lomítko => je to v podsložce
    esac

    ext="${file##*.}"
    ext_lc="$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')"
    case "$ext_lc" in
      jpg|jpeg|png|heic|heif|tif|tiff)
        echo "Nový soubor: $file"
        trigger_job
        ;;
    esac
  done
