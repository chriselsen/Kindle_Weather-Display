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
    set -euo pipefail

    # Install rsvg-convert and its runtime dependencies
    dnf install -y librsvg2-tools 2>/dev/null

    # Resolve the actual rsvg-convert binary path
    RSVG_BIN="$(which rsvg-convert)"
    echo "rsvg-convert found at: ${RSVG_BIN}"

    # Create output directories
    mkdir -p /layer/bin /layer/lib

    # Copy the binary
    cp "${RSVG_BIN}" /layer/bin/rsvg-convert
    chmod 755 /layer/bin/rsvg-convert

    # Walk shared library dependencies with ldd and copy each one.
    # We skip linux-vdso and ld-linux (kernel-provided / loader) which are
    # not real files on disk.
    ldd "${RSVG_BIN}" | awk "NF==4{print \$3}" | grep -v "^$" | sort -u | \
    while read -r lib; do
      if [[ -f "${lib}" ]]; then
        echo "  Copying: ${lib}"
        cp -L "${lib}" /layer/lib/
      fi
    done

    # Also recurse one level for indirect dependencies (e.g. pango → fontconfig)
    for lib in /layer/lib/*.so*; do
      ldd "${lib}" 2>/dev/null | awk "NF==4{print \$3}" | grep -v "^$" | \
      while read -r dep; do
        if [[ -f "${dep}" ]] && [[ ! -f "/layer/lib/$(basename "${dep}")" ]]; then
          echo "  Copying indirect dep: ${dep}"
          cp -L "${dep}" /layer/lib/
        fi
      done
    done

    echo "Binary and libraries collected."
    echo "rsvg-convert: $(ls -lh /layer/bin/rsvg-convert)"
    echo "Shared libs:  $(ls /layer/lib | wc -l) files"
  '

echo "==> Zipping layer"
cd "${BUILD_DIR}"
zip -r9 "../${OUTPUT_ZIP}" bin lib
cd ..

echo "==> Cleaning up build directory"
rm -rf "${BUILD_DIR}"

# Quick sanity check — the zip must contain the binary
if ! unzip -l "${OUTPUT_ZIP}" | grep -q "bin/rsvg-convert"; then
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
