#!/usr/bin/env bash
# build_librsvg_layer.sh
# Builds the librsvg / rsvg-convert Lambda layer for x86_64.
#
# rsvg-convert is a native binary — it has no Python runtime dependency and
# the same layer zip works for any Python version. The binary is placed at
# bin/rsvg-convert so Lambda can find it at /opt/bin/rsvg-convert.
#
# Strategy: compile rsvg-convert and bundle every shared library it needs
# inside an Amazon Linux 2023 container (the OS Lambda python3.14 runs on).
#
# Output: librsvg_lambda_layer.zip
# Layer zip layout:
#   bin/rsvg-convert          <- the executable
#   lib/                      <- shared libraries rsvg-convert depends on
#   fonts/                    <- DejaVu Sans TTF files
#   fonts/fonts.conf          <- fontconfig config pointing at /opt/fonts
#
# Prerequisites: Docker (with access to pull public.ecr.aws images)

set -euo pipefail

LAYER_NAME="librsvg_lambda_layer"
OUTPUT_ZIP="${LAYER_NAME}.zip"
BUILD_DIR="$(pwd)/build_${LAYER_NAME}"

echo "==> Building Lambda layer: ${LAYER_NAME}"
echo "    Output: ${OUTPUT_ZIP}"
echo

# Clean previous build artefacts
rm -rf "${BUILD_DIR}" "${OUTPUT_ZIP}"
mkdir -p "${BUILD_DIR}"

echo "==> Pulling Amazon Linux 2023 image (matches Lambda python3.14 OS)"
docker pull --platform linux/amd64 amazonlinux:2023

echo "==> Compiling rsvg-convert and collecting shared libraries"
# We install librsvg2-tools (provides rsvg-convert) plus all runtime libs,
# then use ldd to walk the dependency tree and copy every .so into lib/.
docker run --rm \
  --platform linux/amd64 \
  -v "${BUILD_DIR}:/layer" \
  amazonlinux:2023 \
  bash -c '
    set -eu

    # Install rsvg-convert, its runtime dependencies, and DejaVu Sans fonts
    # (the SVG template uses font-family="DejaVu Sans"; without the font files
    # rsvg-convert silently renders all text as invisible/missing)
    dnf install -y librsvg2-tools dejavu-sans-fonts

    # Resolve the actual rsvg-convert binary path (use command -v; "which" is not
    # available in the minimal Amazon Linux 2023 container)
    RSVG_BIN="$(command -v rsvg-convert)"
    echo "rsvg-convert found at: ${RSVG_BIN}"

    # Create output directories
    mkdir -p /layer/bin /layer/lib /layer/fonts

    # Copy the binary
    cp "${RSVG_BIN}" /layer/bin/rsvg-convert
    chmod 755 /layer/bin/rsvg-convert

    # Walk shared library dependencies with ldd and copy each one.
    # We skip linux-vdso and ld-linux (kernel-provided / loader) which are
    # not real files on disk.
    # The "|| true" prevents set -e from aborting if grep finds no matches.
    ldd "${RSVG_BIN}" | awk "NF==4{print \$3}" | sort -u | \
    while IFS= read -r lib; do
      [ -n "${lib}" ] || continue
      if [ -f "${lib}" ]; then
        echo "  Copying: ${lib}"
        cp -L "${lib}" /layer/lib/
      fi
    done || true

    # Also recurse one level for indirect dependencies (e.g. pango -> fontconfig)
    for lib in /layer/lib/*.so*; do
      [ -f "${lib}" ] || continue
      ldd "${lib}" 2>/dev/null | awk "NF==4{print \$3}" | \
      while IFS= read -r dep; do
        [ -n "${dep}" ] || continue
        if [ -f "${dep}" ] && [ ! -f "/layer/lib/$(basename "${dep}")" ]; then
          echo "  Copying indirect dep: ${dep}"
          cp -L "${dep}" /layer/lib/
        fi
      done || true
    done

    echo "Binary and libraries collected."
    echo "rsvg-convert size: $(ls -lh /layer/bin/rsvg-convert | awk "{print \$5}")"
    echo "Shared libs:  $(ls /layer/lib | wc -l) files"

    # Bundle DejaVu Sans font files so rsvg-convert can render text in SVGs
    # that use font-family="DejaVu Sans".
    cp /usr/share/fonts/dejavu-sans-fonts/DejaVuSans.ttf        /layer/fonts/
    cp /usr/share/fonts/dejavu-sans-fonts/DejaVuSans-Bold.ttf   /layer/fonts/
    cp /usr/share/fonts/dejavu-sans-fonts/DejaVuSans-Oblique.ttf /layer/fonts/

    # Write a minimal fontconfig config that tells fontconfig to look only in
    # /opt/fonts (where Lambda mounts this layer). The FONTCONFIG_PATH env var
    # must point at the directory containing this fonts.conf when rsvg-convert runs.
    cat > /layer/fonts/fonts.conf << EOF
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <dir>/opt/fonts</dir>
  <cachedir>/tmp/fontconfig-cache</cachedir>
</fontconfig>
EOF

    echo "Fonts bundled: $(ls /layer/fonts/*.ttf | wc -l) TTF file(s)"

    # Make all output files world-readable/writable so the host (non-root)
    # user can zip and clean up the build directory after the container exits.
    chmod -R a+rwX /layer
  '

echo "==> Zipping layer"
cd "${BUILD_DIR}"
zip -r9 "../${OUTPUT_ZIP}" bin lib fonts
cd ..

echo "==> Cleaning up build directory"
rm -rf "${BUILD_DIR}"

# Quick sanity check — the zip must contain the binary
# (Use grep without pipefail to avoid SIGPIPE from grep -q exiting early)
if ! (set +o pipefail; unzip -l "${OUTPUT_ZIP}" | grep -q "bin/rsvg-convert"); then
  echo "ERROR: bin/rsvg-convert not found in ${OUTPUT_ZIP}" >&2
  exit 1
fi

echo
echo "Done. Layer archive: $(pwd)/${OUTPUT_ZIP}"
echo "Upload to AWS with:"
echo "  aws lambda publish-layer-version \\"
echo "    --layer-name ${LAYER_NAME} \\"
echo "    --zip-file fileb://${OUTPUT_ZIP} \\"
echo "    --compatible-runtimes python3.14 \\"
echo "    --compatible-architectures x86_64"
echo
echo "The binary is available inside Lambda at: /opt/bin/rsvg-convert"
