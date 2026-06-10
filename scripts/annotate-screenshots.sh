#!/bin/bash
# Regenerate the annotated README screenshots in assets/ from the raw captures in
# assets/raw/. Adds numbered yellow badges (right-gutter, with leader lines) + a
# bottom legend, matching the project's screenshot style.
#
# Repeatable: drop a fresh capture into assets/raw/screenshot-<name>.png (or tweak
# the per-image config below) and re-run from the repo root:
#
#   ./scripts/annotate-screenshots.sh
#
# Requires ImageMagick v7 (`magick`) and the referenced macOS system fonts.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # repo root
RAW="$DIR/assets/raw"
OUT="$DIR/assets"
BADGE_DIR="$(mktemp -d)"
trap 'rm -rf "$BADGE_DIR"' EXIT

YELLOW="#FFD60A"
LIGHT="#EAEAEA"
NUMFONT="/System/Library/Fonts/Supplemental/Arial Bold.ttf"   # badge + legend numbers
TEXTFONT="/System/Library/Fonts/SFNS.ttf"                     # legend body (San Francisco)

# annotate NAME BG CROP_H RPAD BADGE_R BADGE_X LEG_X LEG_Y0 LEG_DY PT BADGES LEGEND
#   reads $RAW/NAME.png, writes $OUT/NAME.png
#   CROP_H : crop the window to this height first (0 = keep full) — trims empty space
#   RPAD   : right gutter (px) added for the badges
#   BADGES : newline "num target_x target_y" — badge sits at (BADGE_X, target_y),
#            a leader runs horizontally from (target_x, target_y) to it
#   LEGEND : newline "num|text" (blank num => unnumbered continuation line)
annotate() {
  local name="$1" bg="$2" croph="$3" rpad="$4" br="$5" bx="$6" lx="$7" ly0="$8" dy="$9" pt="${10}" badges="${11}" legend="${12}"
  local input="$RAW/$name.png" output="$OUT/$name.png"
  local W H; read W H < <(magick identify -format "%w %h\n" "$input")
  [ "$croph" -eq 0 ] && croph="$H"
  local nleg; nleg=$(grep -c . <<< "$legend")
  local NW=$((W + rpad)) NH=$((ly0 + nleg * dy + 24))

  local args=( "$input" -gravity NorthWest -crop "${W}x${croph}+0+0" +repage
               -background "$bg" -extent "${NW}x${NH}" )

  # Leader lines first (the badge circle is drawn on top, hiding the stub).
  args+=( -stroke "$YELLOW" -strokewidth 3 -fill none )
  while IFS= read -r b; do
    [ -z "$b" ] && continue
    set -- $b; args+=( -draw "line $2,$3 $bx,$3" )
  done <<< "$badges"

  # Badges: pre-render each glyph (circle + centered number), composite on top.
  args+=( -stroke none )
  local d=$((br * 2))
  while IFS= read -r b; do
    [ -z "$b" ] && continue
    set -- $b
    local bf="$BADGE_DIR/${name}_$1.png"
    [ -f "$bf" ] || magick -size "${d}x${d}" xc:none \
      -fill "$YELLOW" -draw "circle $br,$br $br,1" \
      -gravity center -font "$NUMFONT" -pointsize $((br * 6 / 5)) -fill black -annotate +0+0 "$1" \
      "$bf"
    args+=( "(" "$bf" ")" -geometry "+$((bx - br))+$(($3 - br))" -composite )
  done <<< "$badges"

  # Legend (yellow number + light body text), one line per entry.
  local i=0
  while IFS= read -r l; do
    [ -z "$l" ] && continue
    local num="${l%%|*}" text="${l#*|}" y=$((ly0 + i * dy))
    args+=( -font "$NUMFONT" -pointsize "$pt" -fill "$YELLOW" -annotate "+${lx}+${y}" "$num" )
    args+=( -font "$TEXTFONT" -pointsize "$pt" -fill "$LIGHT" -annotate "+$((lx + 38))+${y}" "$text" )
    i=$((i + 1))
  done <<< "$legend"

  args+=( "$output" )
  magick "${args[@]}"
  echo "wrote $output ($(magick identify -format '%wx%h' "$output"))"
}

# ---- Menu-bar dropdown (RGB) ----
annotate screenshot-dropdown "#1F1F1F" 0 58 18 731 40 372 46 25 \
"1 690 55
2 668 148
3 658 213
4 658 280" \
"1|Open the full controls, or close the popover
2|Power, and the mode: RGB / White / Warm Glow / Scenes
3|Brightness — drag to 0 to turn off
4|Colour — drag the hue"

# ---- Controls — colour (RGB) ----
annotate screenshot-rgb "#1E1E1E" 1530 70 24 1257 50 1574 56 30 \
"1 1155 222
2 980 347
3 890 700
4 1020 1175
5 1170 1465" \
"1|Pick a saved light and Connect / Disconnect; Discover scans the LAN
2|Power, and the colour mode (RGB / White / Warm Glow / Scenes)
3|Colour wheel — drag to set hue and saturation
4|RGB / HSV / hex entry — fine-tune the exact colour
5|\"Brighter colours\" mixes in the white LEDs — brighter, a little less saturated"

# ---- Controls — white & presets ----
annotate screenshot-white "#1E1E1E" 970 70 24 1273 50 1014 56 30 \
"1 980 347
2 1190 480
3 1190 600
4 595 800" \
"1|Mode — here White (tunable colour temperature)
2|Brightness
3|Temperature — warm ↔ cool
4|Presets — tap to apply; \"Save current…\" adds one"

# ---- Controls — Warm Glow ----
annotate screenshot-warmglow "#1E1E1E" 860 70 24 1265 50 904 56 30 \
"1 980 347
2 1190 480
3 1190 560
4 595 750" \
"1|Mode — Warm Glow (an overlay on white)
2|Brightness — the only control you set
3|Temperature follows brightness automatically — warmer as you dim
4|Warm Glow presets — one-tap cosy levels"

# ---- Controls — Scenes ----
annotate screenshot-scenes "#1E1E1E" 1530 70 24 1267 50 1574 56 30 \
"1 980 347
2 885 500" \
"1|Mode — Scenes (shown only for bulbs that support them)
2|Tap a scene to run it; the active one is ringed (brightness + speed sit below)"

# ---- Discover ----
annotate screenshot-discover "#1E1E1E" 0 70 18 993 40 520 46 25 \
"1 905 52
2 875 242
3 470 400" \
"1|Scan the LAN for bulbs; Done closes the sheet
2|A saved light shows its status — Disconnect, or its row menu to Rename / Remove
3|Newly found bulbs appear here — Save one to keep it"

# ---- Settings ----
annotate screenshot-settings "#1E1E1E" 1300 70 24 1259 50 1344 56 30 \
"1 1180 366
2 1180 729
3 1180 843
4 1180 957
5 1180 1142" \
"1|Device — signal, MAC, firmware, model and its capabilities
2|Auto-sync from the light when the app launches
3|When the Mac sleeps / shuts down — turn the light off, and optionally restore it
4|Open at login (needed to restore the light after a shutdown)
5|Updates — automatic, or check now"

echo "done."
