#!/bin/sh

/etc/init.d/framework stop

# Allow inbound SSH through the Kindle's firewall
iptables -I INPUT -p tcp --dport 22 -j ACCEPT

/mnt/us/weather/display-weather.sh >/dev/null 2>&1 &
