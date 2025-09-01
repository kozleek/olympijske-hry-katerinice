#!/usr/bin/env bash
set -euo pipefail

# ===================== Nastavení =====================
DPI=300         # tiskové DPI
BLEED_MM=0      # spadávka (mm) na každé straně; 0 = bez spadávky

# ===================== Cesty =====================
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FRAME_P="$SCRIPT_DIR/frames/frame_portrait.png"   # 10x15
FRAME_L="$SCRIPT_DIR/frames/frame_landscape.png"  # 15x10

# Batch timestamp (jedna složka pro celý běh)
BATCH_ID="$(date +"%Y-%m-%d_%H-%M-%S")"
OUT_DIR="./_output/$BATCH_ID"
DONE_DIR="./_processed/$BATCH_ID"
SOCIAL_DIR="./_social-sites/$BATCH_ID"
mkdir -p "$OUT_DIR" "$DONE_DIR" "$SOCIAL_DIR"

# ===================== Helpers =====================
cm_to_px() { awk -v cm="$1" -v dpi="$2" 'BEGIN{printf "%d", (cm/2.54)*dpi + 0.5}'; }
mm_to_px() { awk -v mm="$1" -v dpi="$2" 'BEGIN{printf "%d", (mm/25.4)*dpi + 0.5}'; }

# Bezpečný přesun se suffixem při kolizi
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

# ===================== Výpočty rozměrů =====================
BLEED_PX="$(mm_to_px "$BLEED_MM" "$DPI")"
W_PX="$(cm_to_px 10 "$DPI")"      # 10 cm
H_PX="$(cm_to_px 15 "$DPI")"      # 15 cm
TW_P="$(( W_PX + 2*BLEED_PX ))"   # target portrait width
TH_P="$(( H_PX + 2*BLEED_PX ))"   # target portrait height
TW_L="$(( H_PX + 2*BLEED_PX ))"   # target landscape width (15)
TH_L="$(( W_PX + 2*BLEED_PX ))"   # target landscape height (10)

AR_P="0.66666667"  # 10/15
AR_L="1.5"         # 15/10

export MAGICK_THREAD_LIMIT=2

# ===================== Progress bar =====================
START_TS="$(date +%s)"
render_progress() {
  local cur="$1" total="$2" label="$3"
  local cols="$(tput cols 2>/dev/null || echo 80)"
  local barw=$(( cols - 20 ))
  (( barw < 10 )) && barw=10
  local perc=0
  (( total > 0 )) && perc=$(( 100 * cur / total ))
  local done=$(( barw * perc / 100 ))
  local rest=$(( barw - done ))
  local elapsed=$(( $(date +%s) - START_TS ))
  local eta=0
  (( cur > 0 )) && eta=$(( elapsed * (total - cur) / cur ))
  printf "\r[%.*s%*s] %3d%% %d/%d ETA:%02d:%02d %-30.30s" \
    "$done" "========================================================================================================================" \
    "$rest" "" \
    "$perc" "$cur" "$total" \
    "$((eta/60))" "$((eta%60))" \
    "$label"
}
finish_progress() { echo; }

# ===================== Sběr souborů =====================
shopt -s nullglob
FILES=()
for SRC in ./*; do
  [[ -f "$SRC" ]] || continue
  case "$SRC" in
    ./_output/*|./_processed/*|./frames/*|./.DS_Store) continue ;;
  esac
  ext_lc="$(echo "${SRC##*.}" | tr '[:upper:]' '[:lower:]')"
  case "$ext_lc" in
    jpg|jpeg|png|heic|heif|tif|tiff) FILES+=("$SRC") ;;
  esac
done

TOTAL="${#FILES[@]}"
CUR=0
if (( TOTAL == 0 )); then
  echo "Nenalezeny žádné vstupní fotky (jpg/jpeg/png/heic/heif/tif/tiff) v aktuální složce."
  exit 0
fi

# ===================== Kontroly rámů =====================
if [[ ! -f "$FRAME_P" ]]; then
  echo "Chybí portrait rámeček: $FRAME_P"
  exit 1
fi
if [[ ! -f "$FRAME_L" ]]; then
  echo "Chybí landscape rámeček: $FRAME_L"
  exit 1
fi

# ===================== Hlavní smyčka =====================
for SRC in "${FILES[@]}"; do
  CUR=$((CUR + 1))
  base="$(basename "$SRC")"
  name="${base%.*}"
  OUT="$OUT_DIR/$name.jpg"

  # Už hotovo? (nepřegenerovávat)
  if [[ -e "$OUT" ]]; then
    render_progress "$CUR" "$TOTAL" "skip: $base"
    continue
  fi

  # Načtení rozměrů spolehlivě (i HEIC/TIFF), s auto-orient
  dims="$(magick "$SRC[0]" -auto-orient -format "%w %h" info: 2>/dev/null || true)"
  if [[ -z "${dims:-}" ]]; then
    render_progress "$CUR" "$TOTAL" "ERR dims: $base"
    continue
  fi
  read -r W H <<<"$dims"

  # Výběr orientace a cíle
  if (( W >= H )); then
    AR="$AR_L"; TW="$TW_L"; TH="$TH_L"; FRAME="$FRAME_L"
  else
    AR="$AR_P"; TW="$TW_P"; TH="$TH_P"; FRAME="$FRAME_P"
  fi

  # Výpočet ořezu na poměr (zachovat střed)
  cur_ar=$(awk -v w="$W" -v h="$H" 'BEGIN{printf "%.8f", w/h}')
  if awk -v a="$cur_ar" -v b="$AR" 'BEGIN{exit !(a > b)}'; then
    newW=$(awk -v h="$H" -v ar="$AR" 'BEGIN{printf "%d", h*ar}')
    newH="$H"
  else
    newW="$W"
    newH=$(awk -v w="$W" -v ar="$AR" 'BEGIN{printf "%d", w/ar}')
  fi

  TMP="$(mktemp -t 10x15_XXXX).png"

  # 1) Ořez na střed (s auto-orient)
  magick "$SRC[0]" -auto-orient -gravity center -crop "${newW}x${newH}+0+0" +repage "$TMP"

  # 2) Resize na tiskový rozměr (se spadávkou) + nastavit DPI + jemné doostření
  magick "$TMP" \
    -filter LanczosSharp -define filter:blur=0.95 \
    -resize "${TW}x${TH}^" -gravity center -extent "${TW}x${TH}" \
    -unsharp 0x0.6+0.8+0.02 \
    -density "$DPI" -units PixelsPerInch \
    "$TMP"

  # 2b) Sociální varianty (z TMP, tedy bez rámu)
  # SOCIAL_SQ="$SOCIAL_DIR/${name}_sq.jpg"
  # if [[ ! -e "$SOCIAL_SQ" ]]; then
  #   magick "$TMP" \
  #     -filter LanczosSharp -define filter:blur=0.95 \
  #     -resize "1080x1080^" \
  #     -gravity center -extent 1080x1080 \
  #     -unsharp 0x0.5+0.7+0.01 \
  #     -quality 85 \
  #     "$SOCIAL_SQ"
  # fi

  # SOCIAL_PT="$SOCIAL_DIR/${name}_pt.jpg"
  # if [[ ! -e "$SOCIAL_PT" ]]; then
  #   magick "$TMP" \
  #     -filter LanczosSharp -define filter:blur=0.95 \
  #     -resize "1080x1350^" \
  #     -gravity center -extent 1080x1350 \
  #     -unsharp 0x0.5+0.7+0.01 \
  #     -quality 85 \
  #     "$SOCIAL_PT"
  # fi


  # 3) Overlay rámečku (případně otoč si v souborech frames sami)
  if [[ ! -f "$FRAME" ]]; then
    rm -f "$TMP"
    render_progress "$CUR" "$TOTAL" "ERR frame: $base"
    continue
  fi
  magick \
    "$TMP" \
    \( "$FRAME" -resize "${TW}x${TH}!" \) \
    -gravity center -compose over -composite \
    +set exif:Orientation \
    -quality 92 -density "$DPI" -units PixelsPerInch \
    "$OUT"

  # 4) Metadata – zkopírovat, ale Orientation normalizovat na 1
  exiftool -overwrite_original \
    -TagsFromFile "$SRC" "-all:all>all:all" \
    -XResolution="$DPI" -YResolution="$DPI" -ResolutionUnit=inches \
    -IFD0:Orientation#=1 -ExifIFD:Orientation#=1 -Orientation#=1 -XMP:Orientation= \
    "$OUT" >/dev/null 2>&1 || true

  rm -f "$TMP"

  # 5) Přesun originálu do _processed/<BATCH_ID>/
  move_safely "$SRC" "$DONE_DIR"

  render_progress "$CUR" "$TOTAL" "ok: $base"

done
finish_progress

#echo "Výstupy:   $OUT_DIR"
#echo "Originály: $DONE_DIR"
