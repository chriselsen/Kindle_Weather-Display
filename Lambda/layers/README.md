# Lambda Layer Build Scripts — Python 3.14

Build scripts for the four Lambda layers required by the Kindle Weather Display functions.

| # | Layer name | Script | Output zip | Runtime | Arch |
|---|-----------|--------|-----------|---------|------|
| 1 | `requests_314_layer` | `build_requests_layer.sh` | `requests_314_layer.zip` | python3.14 | x86_64 |
| 2 | `pytz_314_layer` | `build_pytz_layer.sh` | `pytz_314_layer.zip` | python3.14 | x86_64 |
| 3 | `Pillow_314_layer` | `build_pillow_layer.sh` | `Pillow_314_layer.zip` | python3.14 | x86_64 |
| 4 | `librsvg_lambda_layer` | `build_librsvg_layer.sh` | `librsvg_lambda_layer.zip` | python3.14 | x86_64 |

## Prerequisites

- **Docker** — running and accessible. The scripts pull official AWS Lambda and Amazon Linux 2023 images to ensure the compiled output matches the Lambda execution environment exactly.
- **aws CLI** — only required if you use the `--upload` flag. Must be configured with permissions for `lambda:PublishLayerVersion`.

## Quick start

```bash
cd Lambda/layers
chmod +x *.sh

# Build all four layers
./build_all_layers.sh

# Build all and upload directly to AWS Lambda
./build_all_layers.sh --upload

# Build a single layer
./build_requests_layer.sh
```

## What each script does

### `build_requests_layer.sh` / `build_pytz_layer.sh`

Pure-Python packages. The script:
1. Pulls `public.ecr.aws/lambda/python:3.14` (official AWS Lambda image).
2. Runs `pip install --target` inside the container to get Linux-native files.
3. Zips the result under `python/lib/python3.14/site-packages/`.

### `build_pillow_layer.sh`

Pillow has C extensions. The script uses `--platform manylinux2014_x86_64 --only-binary=:all:` to pull the pre-compiled manylinux wheel that is compatible with the Lambda Amazon Linux 2023 environment.

### `build_librsvg_layer.sh`

`rsvg-convert` is a native binary — no Python dependency. The script:
1. Pulls `amazonlinux:2023` (matches Lambda python3.14 OS).
2. Installs `librsvg2-tools` via `dnf`.
3. Copies `rsvg-convert` to `bin/` and walks `ldd` to bundle all required shared libraries into `lib/`.

Inside Lambda the binary is available at `/opt/bin/rsvg-convert`.

## Layer zip layouts

```
# Python package layers (requests, pytz, Pillow)
python/
└── lib/
    └── python3.14/
        └── site-packages/
            └── <package files>

# librsvg layer
bin/
└── rsvg-convert
lib/
└── *.so*   (shared libraries)
```

## Attaching layers to your Lambda function

After uploading, attach the layers in the **same order** shown in the table above. In the AWS Console go to your function → **Layers** → **Add a layer** → **Custom layers**.

Using the CLI:

```bash
aws lambda update-function-configuration \
  --function-name <your-function-name> \
  --layers \
    arn:aws:lambda:<region>:<account-id>:layer:requests_314_layer:<version> \
    arn:aws:lambda:<region>:<account-id>:layer:pytz_314_layer:<version> \
    arn:aws:lambda:<region>:<account-id>:layer:Pillow_314_layer:<version> \
    arn:aws:lambda:<region>:<account-id>:layer:librsvg_lambda_layer:<version>
```

## Lambda function environment variables

| Variable | Description |
|----------|-------------|
| `TOMORROW_API_KEY` | tomorrow.io API key (for `lambda_function-tomorrow.io.py`) |
| `OPENWEATHER_API_KEY` | OpenWeatherMap API key (for `lambda_function-open-weather.py`) |
| `S3BucketName` | S3 bucket to upload the generated PNG |
| `S3FileName` | Key/filename for the PNG in S3 |
| `LATITUDE` | Location latitude |
| `LONGITUDE` | Location longitude |
