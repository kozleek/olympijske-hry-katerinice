#!/usr/bin/env bash
set -euo pipefail

# ==============================================
# Watcher pro složku s fotkami
# - spouští overlay-10x13.sh při nových souborech
# - implicitní delay = 10s, lze změnit parametrem
# ==============================================

DELAY="${1:-10}"   # 1. parametr = čekání v sekundách, default 10
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Spouštím watcher ve složce: $PWD"
echo "Delay před spuštěním: ${DELAY}s"
echo "Sledované přípony: jpg, jpeg, png, heic, heif, tif, tiff"
echo "--------------------------------------------------------"

pending=0

trigger_job() {
  if (( pending == 0 )); then
    pending=1
    (
      sleep "$DELAY"
      echo
      echo ">>> Změna detekována – spouštím overlay-10x13.sh"
      bash "$SCRIPT_DIR/overlay-10x13.sh" --name watch-$(date +%Y-%m-%d)
      echo ">>> Hotovo"
      echo
      pending=0
    ) &
  fi
}

brew list fswatch &>/dev/null || {
  echo "Chyba: fswatch není nainstalován. Spusť: brew install fswatch"
  exit 1
}

fswatch -0 --event Created . | while IFS= read -r -d "" file; do
  ext="${file##*.}"
  ext_lower=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
  case "$ext_lower" in
    jpg|jpeg|png|heic|heif|tif|tiff)
      echo "Nový soubor: $file"
      trigger_job
      ;;
  esac
done
