#!/bin/sh

/etc/init.d/framework stop
/mnt/us/weather/display-weather.sh & >/dev/null 2>&1
