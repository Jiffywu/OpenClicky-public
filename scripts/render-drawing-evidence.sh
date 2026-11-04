#!/bin/zsh
# Renders the drawing programs recorded in earlier live runs (feat-brain-runtime, feat-voice-loop) with one occtl
# build, for before/after comparisons of drawing layout and look. No network, no keys.
#
#   scripts/render-drawing-evidence.sh [occtl-binary] [out-dir]
#
# Defaults: .build/debug/occtl and .build/evidence/drawing.
set -euo pipefail
cd "$(dirname "$0")/.."
occtl=${1:-.build/debug/occtl}
out=${2:-.build/evidence/drawing}
mkdir -p "$out"
br=Tests/Fixtures/Drawing/brain
vl=Tests/Fixtures/Drawing/voice
page=$br/inputs/bridge-page.jpg
blank=$br/inputs/blank-canvas.png

render() {   # name program size background
  local name=$1 program=$2 size=$3 bg=$4
  "$occtl" draw "$program" "$out/$name.png" --size "$size" --bg "$bg" --media off > "$out/$name.txt" 2>&1 || {
    echo "failed: $name (see $out/$name.txt)"; return 1; }
}
render3d() {  # name program size background
  local name=$1 program=$2 size=$3 bg=$4
  "$occtl" brain render "$program" "$out/$name.png" --size "$size" --bg "$bg" > "$out/$name.txt" 2>&1 || {
    echo "failed: $name (see $out/$name.txt)"; return 1; }
}

render   br-1-bridge-page            $br/1-bridge-page.js            1200x661 $page
render   br-1-bridge-page-first-try  $br/1-bridge-page-first-try.js  1200x661 $page
render   br-2-hash-table             $br/2-hash-table.js             1280x832 $blank
render   br-3-hash-collisions        $br/3-hash-collisions.js        1280x832 $blank
render3d br-5-gyroscope-3d           $br/5-gyroscope-3d.js           1280x832 $blank
render   br-6-growth-graph           $br/6-growth-graph.js           1280x832 $blank
render   vl-1-voice-bridge-page      $vl/1-voice-bridge-page/program.js          1200x661 $page
render   vl-2-voice-diagram          $vl/2-voice-diagram-blank-canvas/program.js 1280x800 $blank
render   vl-3-typed-read-aloud       $vl/3-typed-read-aloud/program.js           1200x661 $page
render   vl-r1-password-field        $vl/review/R1-voice-password-field/program.js 1200x661 $page
render   vl-i2-draw-to-ask           $vl/integration/2-draw-to-ask-bridge-page/program.js 1200x661 $page
echo "rendered into $out"
