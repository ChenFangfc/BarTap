#!/bin/zsh
# Renders the BarTap promo film and its README preview.
#
#   promo/build.sh          # English  -> promo/out/bartap-promo.mp4
#   promo/build.sh zh       # Chinese  -> promo/out/bartap-promo-zh.mp4
#
# Needs: swiftc (Command Line Tools), python3 with numpy/scipy, ffmpeg, and img2webp/cwebp (libwebp)
# for the README media in docs/media/.
set -euo pipefail
cd "$(dirname "$0")/.."
LANG_CODE=${1:-en}
SUFFIX=$([[ $LANG_CODE == en ]] && echo "" || echo "-$LANG_CODE")
mkdir -p .build promo/out docs/media

# 1. Real BarTap renderings of sample data (no personal data).
if [[ ! -f promo/assets/panel_cpu_light.png ]]; then
  swift build --product BarTap >/dev/null
  .build/debug/BarTap --export-promo-assets "$PWD/promo/assets"
fi

# 2. The compositor, its sound cues, and the soundtrack.
swiftc -O promo/film.swift -o .build/film
.build/film "$PWD" cues > promo/out/cues.json
python3 promo/music.py

# 3. Frames -> H.264 + AAC.
OUT=promo/out/bartap-promo$SUFFIX.mp4
FILM_LANG=$LANG_CODE .build/film "$PWD" \
  | ffmpeg -y -loglevel error -f rawvideo -pix_fmt rgba -s 1920x1080 -r 30 -i - -i promo/out/soundtrack.wav \
      -c:v libx264 -preset slow -crf 20 -tune animation -pix_fmt yuv420p \
      -c:a aac -b:a 160k -shortest -movflags +faststart "$OUT"
echo "wrote $OUT ($(du -h "$OUT" | cut -f1))"

# 4. Silent animated preview for the README: the compositor's own frames at full size and 15 fps,
#    lossless. Lossy WebP re-encodes only the changed region of each frame and leaves visible
#    blotches on these flat colors; downscaling adds soft edges that compress worse than 1920 px.
if command -v img2webp >/dev/null; then
  FRAMES=promo/out/preview-frames$SUFFIX
  rm -rf "$FRAMES" && mkdir -p "$FRAMES"
  FILM_LANG=$LANG_CODE .build/film "$PWD" \
    | ffmpeg -y -loglevel error -f rawvideo -pix_fmt rgba -s 1920x1080 -r 30 -i - -vf fps=15 "$FRAMES/f%04d.png"
  img2webp -loop 0 -lossless -m 4 -d 67 "$FRAMES"/f*.png -o "promo/out/bartap-preview$SUFFIX.webp" >/dev/null 2>&1
  rm -rf "$FRAMES"
  echo "wrote promo/out/bartap-preview$SUFFIX.webp ($(du -h promo/out/bartap-preview$SUFFIX.webp | cut -f1))"
  cp "promo/out/bartap-preview$SUFFIX.webp" docs/media/
fi

# 5. README media: the film, and (English run) the screenshots as lossless WebP.
cp "$OUT" "docs/media/bartap-film-$LANG_CODE.mp4"
if [[ $LANG_CODE == en ]]; then
  swiftc -O promo/shots.swift -o .build/shots
  .build/shots "$PWD" >/dev/null
  for f in docs/media/{bar,panels,layouts}-{light,dark}.png; do
    cwebp -quiet -lossless -m 6 "$f" -o "${f%.png}.webp" && rm "$f"
  done
fi
echo "updated docs/media"
