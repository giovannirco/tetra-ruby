#!/bin/sh
# Vendors three.js into web/vendor/three so the UI loads nothing from a CDN.
#
# The examples/jsm add-ons import the bare specifier 'three'. Browsers need an
# import map for that, and an import map is an inline script, which the
# Content-Security-Policy forbids. So the specifier is rewritten to a relative
# path here, once, instead of loosening the policy.
set -eu

VERSION="${THREE_VERSION:-0.160.1}"
DEST="$(cd "$(dirname "$0")/.." && pwd)/web/vendor/three"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

(cd "$WORK" && npm pack "three@$VERSION" --silent >/dev/null && tar xzf "three-$VERSION.tgz")
PKG="$WORK/package"

rm -rf "$DEST"
mkdir -p "$DEST/build" "$DEST/examples/jsm/postprocessing" "$DEST/examples/jsm/shaders"
cp "$PKG/LICENSE" "$DEST/"
cp "$PKG/build/three.module.min.js" "$DEST/build/"
for f in EffectComposer RenderPass UnrealBloomPass OutputPass ShaderPass MaskPass Pass; do
  sed "s#from 'three'#from '../../../build/three.module.min.js'#" \
    "$PKG/examples/jsm/postprocessing/$f.js" > "$DEST/examples/jsm/postprocessing/$f.js"
done
for f in CopyShader LuminosityHighPassShader OutputShader; do
  sed "s#from 'three'#from '../../../build/three.module.min.js'#" \
    "$PKG/examples/jsm/shaders/$f.js" > "$DEST/examples/jsm/shaders/$f.js"
done
echo "$VERSION" > "$DEST/VERSION"

if grep -rq "from 'three'" "$DEST"; then
  echo "bare 'three' import left in $DEST" >&2
  exit 1
fi
echo "vendored three.js $VERSION into $DEST"
