#!/bin/zsh
# Builds the geometry-only three.js slice that OpenClicky's 3D kernel runs in JavaScriptCore.
#
#   scripts/build-three-kernel.sh
#
# Output (both committed):
#   Sources/OpenClickyKit/Resources/js/three-slice.js        (generated; do not edit)
#   Sources/OpenClickyKit/Resources/js/three-LICENSE.txt     (three.js MIT license, copied from the tarball)
#
# The slice comes from the upstream npm tarball of three.js (pinned version, checked against the registry's
# sha1), bundled and tree-shaken with esbuild so only geometry classes are left: no renderer, no DOM, no WebGL.
# Our own part builders live in Resources/js/three-kernel.js and use the slice through globalThis.OCThree.
#
# Needs node + npx (esbuild is fetched by npx at the pinned version). Network access to registry.npmjs.org.
set -euo pipefail

THREE_VERSION="0.187.0"
THREE_SHA1="face29ee2de9bcc31a1b573a76f224e35e0b2894"
ESBUILD_VERSION="0.28.2"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT/Sources/OpenClickyKit/Resources/js"

command -v node >/dev/null || { echo "node is required (brew install node, or nvm)" >&2; exit 1; }
command -v npx >/dev/null || { echo "npx is required (ships with npm)" >&2; exit 1; }

# Downloads go to their own empty directory; the generated entry file goes to a separate one.
WORK="$(mktemp -d -t oc-three-kernel)"
trap '/bin/rm -rf "$WORK"' EXIT
mkdir -p "$WORK/download" "$WORK/build/node_modules"

echo "Fetching three@$THREE_VERSION from the npm registry…"
( cd "$WORK/download" && npm pack "three@$THREE_VERSION" --silent >/dev/null )
TARBALL="$WORK/download/three-$THREE_VERSION.tgz"
ACTUAL_SHA1="$(shasum -a 1 "$TARBALL" | awk '{print $1}')"
if [[ "$ACTUAL_SHA1" != "$THREE_SHA1" ]]; then
  echo "three tarball sha1 mismatch: expected $THREE_SHA1, got $ACTUAL_SHA1" >&2
  exit 1
fi
mkdir -p "$WORK/download/three"
tar -xzf "$TARBALL" -C "$WORK/download/three"
ln -s "$WORK/download/three/package" "$WORK/build/node_modules/three"

# The entry lists exactly what three-kernel.js uses (surfaces of revolution, extrusions and blobs are our own
# builders). Core classes are imported from three's sources by path (not the prebuilt module, which drags in
# renderers); the two addons import 'three', which is aliased to the core entry.
cat > "$WORK/build/entry.js" <<'EOF'
import { REVISION } from './node_modules/three/src/constants.js';
import { BufferGeometry } from './node_modules/three/src/core/BufferGeometry.js';
import { BufferAttribute, Float32BufferAttribute } from './node_modules/three/src/core/BufferAttribute.js';
import { Vector2 } from './node_modules/three/src/math/Vector2.js';
import { Vector3 } from './node_modules/three/src/math/Vector3.js';
import { Quaternion } from './node_modules/three/src/math/Quaternion.js';
import { BoxGeometry } from './node_modules/three/src/geometries/BoxGeometry.js';
import { ConeGeometry } from './node_modules/three/src/geometries/ConeGeometry.js';
import { SphereGeometry } from './node_modules/three/src/geometries/SphereGeometry.js';
import { TubeGeometry } from './node_modules/three/src/geometries/TubeGeometry.js';
import { TetrahedronGeometry } from './node_modules/three/src/geometries/TetrahedronGeometry.js';
import { OctahedronGeometry } from './node_modules/three/src/geometries/OctahedronGeometry.js';
import { DodecahedronGeometry } from './node_modules/three/src/geometries/DodecahedronGeometry.js';
import { IcosahedronGeometry } from './node_modules/three/src/geometries/IcosahedronGeometry.js';
import { Shape } from './node_modules/three/src/extras/core/Shape.js';
import { Path } from './node_modules/three/src/extras/core/Path.js';
import { ShapePath } from './node_modules/three/src/extras/core/ShapePath.js';
import { Curve } from './node_modules/three/src/extras/core/Curve.js';
import { CatmullRomCurve3 } from './node_modules/three/src/extras/curves/CatmullRomCurve3.js';
import { LineCurve3 } from './node_modules/three/src/extras/curves/LineCurve3.js';
import { ShapeUtils } from './node_modules/three/src/extras/ShapeUtils.js';
import { RoundedBoxGeometry } from './node_modules/three/examples/jsm/geometries/RoundedBoxGeometry.js';
import { mergeGeometries, mergeVertices } from './node_modules/three/examples/jsm/utils/BufferGeometryUtils.js';

globalThis.OCThree = {
  REVISION, BufferGeometry, BufferAttribute, Float32BufferAttribute, Vector2, Vector3, Quaternion,
  BoxGeometry, ConeGeometry, SphereGeometry, TubeGeometry, TetrahedronGeometry, OctahedronGeometry,
  DodecahedronGeometry, IcosahedronGeometry, RoundedBoxGeometry,
  Shape, Path, ShapePath, Curve, CatmullRomCurve3, LineCurve3, ShapeUtils,
  mergeGeometries, mergeVertices,
};
EOF

echo "Bundling with esbuild@$ESBUILD_VERSION…"
BODY="$WORK/build/three-slice.body.js"
( cd "$WORK/build" && npx --yes "esbuild@$ESBUILD_VERSION" entry.js \
    --bundle --format=iife --platform=neutral --target=es2020 \
    --alias:three=./node_modules/three/src/Three.Core.js \
    --tree-shaking=true --minify-syntax --minify-whitespace --legal-comments=inline \
    --log-level=warning --outfile="$BODY" )

{
  echo "// three.js r${${THREE_VERSION#0.}%.0} geometry slice for OpenClicky's 3D kernel."
  echo "// Generated by scripts/build-three-kernel.sh from the npm tarball three@$THREE_VERSION (sha1 $THREE_SHA1)"
  echo "// with esbuild $ESBUILD_VERSION. Do not edit; rerun the script."
  echo "// three.js is Copyright © 2010-2026 three.js authors, MIT license: see three-LICENSE.txt next to this file."
  cat "$BODY"
} > "$OUT_DIR/three-slice.js"
/bin/cp -f "$WORK/download/three/package/LICENSE" "$OUT_DIR/three-LICENSE.txt"

echo "Wrote $OUT_DIR/three-slice.js ($(wc -c < "$OUT_DIR/three-slice.js" | tr -d ' ') bytes) and three-LICENSE.txt"
