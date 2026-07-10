#!/usr/bin/env bash
# build_pillow_layer.sh
# Builds the Pillow Lambda layer for Python 3.14 (x86_64).
#
# Pillow has C extensions, so it must be compiled against the exact Amazon
# Linux environment that Lambda runs. We use the official Lambda base image
# and request the manylinux wheel so pip picks the right binary.
#
# Output: Pillow_314_layer.zip
# Layer zip layout: python/lib/python3.14/site-packages/
#
# Prerequisites: Docker (with access to pull public.ecr.aws images)

set -euo pipefail

LAYER_NAME="Pillow_314_layer"
PYTHON_VERSION="3.14"
RUNTIME="python${PYTHON_VERSION}"
IMAGE="public.ecr.aws/lambda/python:${PYTHON_VERSION}"
PACKAGES="Pillow"
OUTPUT_ZIP="${LAYER_NAME}.zip"
BUILD_DIR="$(pwd)/build_${LAYER_NAME}"

echo "==> Building Lambda layer: ${LAYER_NAME}"
echo "    Runtime : ${RUNTIME}"
echo "    Packages: ${PACKAGES}"
echo "    Output  : ${OUTPUT_ZIP}"
echo

# Clean previous build artefacts
rm -rf "${BUILD_DIR}" "${OUTPUT_ZIP}"
mkdir -p "${BUILD_DIR}/python/lib/${RUNTIME}/site-packages"

echo "==> Pulling Lambda base image: ${IMAGE}"
docker pull --platform linux/amd64 "${IMAGE}"

echo "==> Installing packages inside container"
# Use --platform to ensure we get the manylinux x86_64 wheel compiled for
# the Lambda execution environment (Amazon Linux 2023).
docker run --rm \
  --platform linux/amd64 \
  -v "${BUILD_DIR}:/layer" \
  "${IMAGE}" \
  pip install \
    --no-cache-dir \
    --upgrade \
    --platform manylinux2014_x86_64 \
    --only-binary=:all: \
    --target "/layer/python/lib/${RUNTIME}/site-packages" \
    ${PACKAGES}

echo "==> Zipping layer"
cd "${BUILD_DIR}"
zip -r9 "../${OUTPUT_ZIP}" python
cd ..

echo "==> Cleaning up build directory"
rm -rf "${BUILD_DIR}"

echo
echo "Done. Layer archive: $(pwd)/${OUTPUT_ZIP}"
echo "Upload to AWS with:"
echo "  aws lambda publish-layer-version \\"
echo "    --layer-name ${LAYER_NAME} \\"
echo "    --zip-file fileb://${OUTPUT_ZIP} \\"
echo "    --compatible-runtimes ${RUNTIME} \\"
echo "    --compatible-architectures x86_64"
