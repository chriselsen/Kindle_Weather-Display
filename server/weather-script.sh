#!/bin/sh

cd "$(dirname "$0")"

python2 weather-script.py && \
rsvg-convert --background-color=white -o weather-script-output.png weather-script-output.svg && \
pngcrush -c 0 -ow weather-script-output.png && \
/usr/bin/aws s3 cp weather-script-output.png s3://<bucket name>/sf-weather.png
