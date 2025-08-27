#!/usr/bin/env bash
set -euo pipefail

# --- cesty ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FRAME_P="$SCRIPT_DIR/frames/frame_portrait.png"
FRAME_L="$SCRIPT_DIR/frames/frame_landscape.png"

# timestamp pro tento běh
BATCH_ID="$(date +"%Y-%m-%d_%H-%M-%S")"

OUT_DIR="./_output/$BATCH_ID"
DONE_ROOT="./_processed/$BATCH_ID"

mkdir -p "$OUT_DIR" "$DONE_ROOT"

# --- nastavení tisku ---
DPI=300
BLEED_MM=0

# --- pomocné převody ---
cm_to_px() { awk -v cm="$1" -v dpi="$2" 'BEGIN{printf "%d", (cm/2.54)*dpi + 0.5}'; }
mm_to_px() { awk -v mm="$1" -v dpi="$2" 'BEGIN{printf "%d", (mm/25.4)*dpi + 0.5}'; }

BLEED_PX="$(mm_to_px "$BLEED_MM" "$DPI")"
W_PX="$(cm_to_px 10 "$DPI")"; H_PX="$(cm_to_px 13 "$DPI")"
TW_P="$(( W_PX + 2*BLEED_PX ))"; TH_P="$(( H_PX + 2*BLEED_PX ))"
TW_L="$(( H_PX + 2*BLEED_PX ))"; TH_L="$(( W_PX + 2*BLEED_PX ))"

AR_P="0.76923077"  # 10/13
AR_L="1.3"         # 13/10

export MAGICK_THREAD_LIMIT=2

# --- helper: bezpečný přesun se suffixem, když existuje cíl ---
move_safely() {
  local src="$1" dst_dir="$2" base dst
  base="$(basename "$src")"
  mkdir -p "$dst_dir"
  dst="$dst_dir/$base"
  if [[ -e "$dst" ]]; then
    local name="${base%.*}" ext="${base##*.}" n=1
    while [[ -e "$dst_dir/${name} (${n}).${ext}" ]]; do n=$((n+1)); done
    dst="$dst_dir/${name} (${n}).${ext}"
  fi
  mv "$src" "$dst"
}

# --- projdi jen soubory v aktuální složce ---
shopt -s nullglob
for SRC in ./*; do
  [[ -f "$SRC" ]] || continue
  case "$SRC" in
    ./output-print/*|./_processed/*|./frames/*|./.DS_Store) continue ;;
  esac

  ext_lc="$(echo "${SRC##*.}" | tr '[:upper:]' '[:lower:]')"
  case "$ext_lc" in
    jpg|jpeg|png|heic|heif|tif|tiff) ;;
    *) continue ;;
  esac

  base="$(basename "$SRC")"
  name="${base%.*}"
  OUT="$OUT_DIR/$name.jpg"
  if [[ -e "$OUT" ]]; then
    echo "Přeskočeno (existuje výstup): $base"
    continue
  fi

  # --- SPOLEHLIVÉ ČTENÍ ROZMĚRŮ ---
  # Použij výstupní driver "info:" – funguje i s -auto-orient
  # U vícestránkových formátů (HEIC/TIFF) vezmi první snímek: [0]
  dims="$(magick "$SRC[0]" -auto-orient -format "%w %h" info: 2>/dev/null || true)"
  if [[ -z "${dims:-}" ]]; then
    echo "Chyba: nelze načíst rozměry (chybí podpora formátu? HEIC → libheif?): $base"
    continue
  fi
  read -r W H <<<"$dims"

  # výběr orientace a cíle
  if (( W >= H )); then
    AR="$AR_L"; TW="$TW_L"; TH="$TH_L"; FRAME="$FRAME_L"
  else
    AR="$AR_P"; TW="$TW_P"; TH="$TH_P"; FRAME="$FRAME_P"
  fi

  # výpočet ořezu
  cur_ar=$(awk -v w="$W" -v h="$H" 'BEGIN{printf "%.8f", w/h}')
  if awk -v a="$cur_ar" -v b="$AR" 'BEGIN{exit !(a > b)}'; then
    newW=$(awk -v h="$H" -v ar="$AR" 'BEGIN{printf "%d", h*ar}')
    newH="$H"
  else
    newW="$W"
    newH=$(awk -v w="$W" -v ar="$AR" 'BEGIN{printf "%d", w/ar}')
  fi

  TMP="$(mktemp -t 10x13_XXXX).png"

  # 1) ořez na střed (auto-orient už tady)
  magick "$SRC[0]" -auto-orient -gravity center -crop "${newW}x${newH}+0+0" +repage "$TMP"

  # 2) resize na tiskový rozměr (se spadávkou)
  magick "$TMP" -resize "${TW}x${TH}^" -gravity center -extent "${TW}x${TH}" -density "$DPI" -units PixelsPerInch "$TMP"

  # 3) overlay rámečku
  if [[ ! -f "$FRAME" ]]; then
    echo "Chyba: chybí rámeček: $FRAME"
    rm -f "$TMP"
    continue
  fi

  magick \
    "$TMP" \
    \( "$FRAME" -resize "${TW}x${TH}!" \) \
    -gravity center -compose over -composite \
    -quality 92 -density "$DPI" -units PixelsPerInch \
    "$OUT"

  # 4) metadata (best effort)
#   exiftool -overwrite_original \
#     -TagsFromFile "$SRC" "-all:all>all:all" \
#     -XResolution="$DPI" -YResolution="$DPI" -ResolutionUnit=inches \
#     "$OUT" >/dev/null 2>&1 || true

    # 4) metadata: zkopíruj vše, ale přepiš Orientation -> 1 (žádná rotace)
    exiftool -overwrite_original \
    -TagsFromFile "$SRC" "-all:all>all:all" \
    -XResolution="$DPI" -YResolution="$DPI" -ResolutionUnit=inches \
    -IFD0:Orientation#=1 -ExifIFD:Orientation#=1 -Orientation#=1 -XMP:Orientation= \
    "$OUT" >/dev/null 2>&1 || true

  rm -f "$TMP"

  # 5) přesun originálu do _processed/<BATCH_ID>/
  move_safely "$SRC" "$DONE_ROOT"

  echo "Hotovo: $OUT"
done
