#!/usr/bin/env bash
# build_all_layers.sh
# Builds all four Lambda layers required by the Kindle Weather Display.
# Run this script from the Lambda/layers/ directory.
#
# Layers built (in dependency order):
#   1. requests_314_layer    — HTTP library
#   2. pytz_314_layer        — Timezone data
#   3. Pillow_314_layer      — Image processing (C extension)
#   4. librsvg_lambda_layer  — rsvg-convert binary (SVG → PNG)
#
# Prerequisites:
#   - Docker running and accessible (Linux/amd64 images)
#   - aws CLI configured (optional — only needed for the upload step)
#
# Usage:
#   cd Lambda/layers
#   chmod +x *.sh
#   ./build_all_layers.sh [--upload]
#
# Pass --upload to automatically publish each layer to AWS Lambda after
# building. Requires the aws CLI to be configured with appropriate permissions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPLOAD=false

# Parse flags
for arg in "$@"; do
  case "${arg}" in
    --upload) UPLOAD=true ;;
    --help|-h)
      sed -n '/^# Usage/,/^[^#]/p' "$0" | head -n -1 | sed 's/^# \?//'
      exit 0
      ;;
    *)
      echo "Unknown argument: ${arg}" >&2
      exit 1
      ;;
  esac
done

cd "${SCRIPT_DIR}"

# Verify Docker is available
if ! docker info > /dev/null 2>&1; then
  echo "ERROR: Docker is not running or not accessible." >&2
  exit 1
fi

echo "========================================"
echo " Kindle Weather Display — Lambda Layers"
echo " Target runtime: python3.14 / x86_64"
echo "========================================"
echo

LAYERS=(
  "build_requests_layer.sh:requests_314_layer.zip:requests_314_layer"
  "build_pytz_layer.sh:pytz_314_layer.zip:pytz_314_layer"
  "build_pillow_layer.sh:Pillow_314_layer.zip:Pillow_314_layer"
  "build_librsvg_layer.sh:librsvg_lambda_layer.zip:librsvg_lambda_layer"
)

BUILT=()
FAILED=()

for entry in "${LAYERS[@]}"; do
  IFS=':' read -r script zip_file layer_name <<< "${entry}"

  echo "----------------------------------------"
  echo "Building: ${layer_name}"
  echo "----------------------------------------"

  if bash "${script}"; then
    BUILT+=("${zip_file}")
    echo "[OK] ${layer_name} -> ${zip_file}"
  else
    FAILED+=("${layer_name}")
    echo "[FAILED] ${layer_name}" >&2
  fi
  echo
done

# Summary
echo "========================================"
echo " Build Summary"
echo "========================================"
echo "Built  : ${#BUILT[@]} layer(s)"
for z in "${BUILT[@]}"; do
  SIZE=$(du -sh "${z}" 2>/dev/null | cut -f1 || echo "?")
  echo "  [OK] ${z}  (${SIZE})"
done

if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "Failed : ${#FAILED[@]} layer(s)"
  for f in "${FAILED[@]}"; do
    echo "  [FAIL] ${f}"
  done
fi
echo

# Optional upload step
if [[ "${UPLOAD}" == "true" ]]; then
  echo "========================================"
  echo " Uploading layers to AWS Lambda"
  echo "========================================"

  if ! aws sts get-caller-identity > /dev/null 2>&1; then
    echo "ERROR: aws CLI is not configured or lacks permissions." >&2
    exit 1
  fi

  declare -A LAYER_ARGS=(
    ["requests_314_layer.zip"]="--layer-name requests_314_layer --compatible-runtimes python3.14 --compatible-architectures x86_64"
    ["pytz_314_layer.zip"]="--layer-name pytz_314_layer --compatible-runtimes python3.14 --compatible-architectures x86_64"
    ["Pillow_314_layer.zip"]="--layer-name Pillow_314_layer --compatible-runtimes python3.14 --compatible-architectures x86_64"
    ["librsvg_lambda_layer.zip"]="--layer-name librsvg_lambda_layer --compatible-runtimes python3.14 --compatible-architectures x86_64"
  )

  for zip_file in "${BUILT[@]}"; do
    args="${LAYER_ARGS[${zip_file}]:-}"
    if [[ -z "${args}" ]]; then
      echo "WARNING: No upload args defined for ${zip_file}, skipping." >&2
      continue
    fi

    echo "Uploading: ${zip_file}"
    # shellcheck disable=SC2086
    VERSION=$(aws lambda publish-layer-version \
      --zip-file "fileb://${zip_file}" \
      ${args} \
      --query 'Version' \
      --output text)
    echo "[OK] Uploaded ${zip_file} -> version ${VERSION}"
  done

  echo
  echo "All layers uploaded. Attach them to your Lambda function in the"
  echo "console or with:"
  echo "  aws lambda update-function-configuration \\"
  echo "    --function-name <your-function-name> \\"
  echo "    --layers <layer-arn-1> <layer-arn-2> ..."
fi

if [[ ${#FAILED[@]} -gt 0 ]]; then
  exit 1
fi
