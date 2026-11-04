#!/bin/zsh
# Copy the model-facing sections of the drawing-language docs into OpenClickyKit's resources, where the brain's
# prompt assembler loads them. Run after editing the text between `<!-- prompt:start -->` and `<!-- prompt:end -->`
# in docs/dsl.md, docs/dsl-3d.md, docs/dsl-guided.md or docs/dsl-media.md; `swift test` fails
# (BrainSessionTests.theDrawingLanguageCopiesMatchTheDocs) while the copies differ.
#   scripts/sync-prompts.sh
set -euo pipefail
root=${0:A:h:h}
out="$root/Sources/OpenClickyKit/Resources/prompts"
mkdir -p "$out"

extract() {
  local source=$1 target=$2
  if ! grep -q '<!-- prompt:start -->' "$source" || ! grep -q '<!-- prompt:end -->' "$source"; then
    print -u2 "$source has no prompt markers"
    exit 1
  fi
  # Everything strictly between the markers, without leading or trailing blank lines.
  awk '/<!-- prompt:end -->/{inside=0} inside{print} /<!-- prompt:start -->/{inside=1}' "$source" \
    | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' \
    | awk 'NF{started=1} started' > "$target.tmp"
  /bin/mv -f "$target.tmp" "$target"
  print "wrote ${target#$root/} ($(wc -l < "$target" | tr -d ' ') lines)"
}

extract "$root/docs/dsl.md" "$out/draw-2d.md"
extract "$root/docs/dsl-3d.md" "$out/draw-3d.md"
extract "$root/docs/dsl-guided.md" "$out/draw-guided.md"
extract "$root/docs/dsl-media.md" "$out/draw-media.md"
