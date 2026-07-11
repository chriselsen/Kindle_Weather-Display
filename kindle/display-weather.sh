#!/bin/sh

trap "msg 'Trap'" SIGHUP SIGINT SIGTERM

# -------------------------------
# START: FIRST BLOCK: FUNCTIONS

send_log () {
	BATT=`gasgauge-info -s`
	VOLT=`gasgauge-info -v`
	LOAD=`gasgauge-info -l`
	TEMP=`gasgauge-info -k`
	CAPA=`gasgauge-info -m`
	JSON="'{\"battery\":\"${BATT}\",\"voltage\":\"${VOLT}\",\"load\":\"${LOAD}\",\"temp\":\"${TEMP}\",\"capacity\":\"${CAPA}\"}'"
	echo "curl -k -H `echo ${TELE_API_KEY}` -d `echo ${JSON}` ${TELE_URL}" | sh
	if [ $? -eq 0 ]; then
		msg "Telemetry send!"
	else
		msg "Could not send Telemetry..."
	fi
}

is_charging () {
	# Returns 0 (true) if the charger is connected, 1 (false) if not.
	# lipc-get-prop com.lab126.powerd isCharging returns "1" when charging.
	[ "`lipc-get-prop com.lab126.powerd isCharging`" = "1" ]
}

wait_while_charging () {
	# When the Kindle is on a charger, powerd will not enter deep suspend
	# and rtcWakeup will not fire, leaving the device in a limbo state.
	# While charging we keep WiFi up (for SSH access) and still service
	# scheduled downloads. Once the charger is disconnected we turn WiFi
	# off and let the normal sleep path proceed to deep suspend.
	if is_charging; then
		msg "Charger connected — keeping WiFi on. Waiting for unplug."
		lipc-set-prop com.lab126.cmd wirelessEnable 1

		while is_charging; do
			# Check every 60 s whether a scheduled download is due
			calc_wakeup
			if [ "$DOWNLOAD_IMG" = "YES" ]; then
				msg "Charging: scheduled download triggered."
				download_llb keep_wifi
				display_image $FN
				DOWNLOAD_IMG="NO"
				DEFER_STAY_AWAKE="NO"
			fi
			sleep 60
		done

		msg "Charger disconnected — turning WiFi off, resuming sleep cycle."
		lipc-set-prop com.lab126.cmd wirelessEnable 0
	fi
}

wait_for_ss () {
	# Wait for "Screen Saver" state
	msg "Waiting for Screen Saver: `powerd_test -s | grep Remaining | awk '{print $6}'` s left in '`powerd_test -s | grep Power | awk '{print $3 $4}'`'"
	PSTATE=`powerd_test -s | grep Screen`
	while [ "$PSTATE" = "" ]; do
		sleep 1
		PSTATE=`powerd_test -s | grep Screen`
		msg "Waiting for Screen Saver!"
	done
}

wait_for_ready () {
	# Wait for "Ready to Suspend" state
	msg "Waiting for Ready: `powerd_test -s | grep Remaining | awk '{print $6}'` s left in '`powerd_test -s | grep Power | awk '{print $3 $4}'`'"
	PSTATE=`powerd_test -s | grep Ready`
	# AWAKE_AGAIN tracks whether we entered the loop (i.e. we had to wait)
	AWAKE_AGAIN="NO"
	while [ "$PSTATE" = "" ]; do
		sleep 1
		PSTATE=`powerd_test -s | grep Ready`
		AWAKE_AGAIN="YES"
	done
	msg "In state Ready: `powerd_test -s | grep Remaining | awk '{print $6}'` s left in '`powerd_test -s | grep Power | awk '{print $3 $4}'`'"
	# If we had to wait, the device woke up from suspend — recalculate.
	if [ "$AWAKE_AGAIN" = "YES" ]; then
		msg "------------------------------------------"
		msg "Recalculate and set next wakeup or action!"
		DOWNLOAD_IMG="YES"

		# output: WAKE_TIME and DOWNLOAD_IMG
		calc_wakeup

		WAKEUP_S=$WAKE_TIME

		# Do not set the RTC wakeup while charging — powerd will not
		# suspend properly on a charger, so wait for unplug first.
		wait_while_charging

		write_wakeup
		AWAKE_AGAIN="NO"
	fi
}

msg () {
	echo "`date`: $1" >> $LOG_FILE
	if [ "$DEBUG" = "YES" ]; then
		echo "`date`: $1"
		eips 1 $EIPSROW "$1"
		if [ $EIPSROW -le 39 ]; then
			EIPSROW=`expr $EIPSROW + 1`
		else
			EIPSROW=1
			eips -c
		fi
	fi
}

calc_wakeup () {
	# this function returns WAKE_TIME and sets DOWNLOAD_IMG
	# CHECK TIME, and recalc sleep timer
	CURRENT_TIME=`date +%s`

	# seconds elapsed since midnight
	D_TIME=`expr $CURRENT_TIME % 86400`
	# initialize WAKE_TIME_set (internal; output is WAKE_TIME)
	WAKE_TIME_set=$WAKEUP_CHECK_DEFAULT

	if [ "$DL_FAILED" = "YES" ]; then
		# We could not load image last time - FAIL mode
		msg_str_d="Fail Mode, retry in $WAKEUP_CHECK_DEFAULT_FAIL s."
		CURR_ACTION="Fail mode"
		WAKE_TIME_set=$WAKEUP_CHECK_DEFAULT_FAIL
		DEFER_STAY_AWAKE="NO"
	else
		# find the closest upcoming action
		WAKE_TIME_set=$WAKEUP_CHECK_DEFAULT
		CURR_ACTION="Default wakeup"
		for ACTION in `echo $ACTION_TIME | awk '{ for (i = 1; i <= NF; i++) print $i }'`; do
			# convert hh:mm into seconds since 00:00
			DESIRED=`echo $ACTION | sed 's/:/ /g' | awk '{print ($1*3600)+($2*60)}'`
			DIFF_TIME_V=`expr $DESIRED - $D_TIME`

			# If the action is more than 2 minutes in the past, treat it as tomorrow
			if [ $DIFF_TIME_V -le -120 ]; then
				DIFF_TIME=`expr 86400 + $DIFF_TIME_V`
			else
				DIFF_TIME=$DIFF_TIME_V
			fi

			if [ $DIFF_TIME -lt $WAKE_TIME_set ]; then
				if [ $DIFF_TIME -ge 120 ]; then
					# Wake up 2 min early so we don't miss the window
					WAKE_TIME_set=`expr $DIFF_TIME - 120`
					CURR_ACTION=$ACTION
				elif [ $DIFF_TIME -gt -120 ] && [ $DIFF_TIME -lt 120 ]; then
					# We are right on time — download now
					WAKE_TIME_set=0
					CURR_ACTION=$ACTION
				else
					# action is past
					msg "$ACTION: $DIFF_TIME s since the action - sleep again!"
				fi
			else
				msg "$ACTION: $DIFF_TIME is larger than $WAKE_TIME_set - sleep again!"
			fi
		done

		# characterize action
		if [ $WAKE_TIME_set -lt $WAKEUP_CHECK_DEFAULT ]; then
			# We are close to the event
			if [ $WAKE_TIME_set -lt $STAY_AWAKE ] && [ "$DEFER_STAY_AWAKE" = "NO" ]; then
				DOWNLOAD_IMG="YES"
				msg_str_d="only $WAKE_TIME_set s away from '$CURR_ACTION', trigger Download."
				DEFER_STAY_AWAKE="YES"
			else
				msg_str_d="$WAKE_TIME_set s from '$CURR_ACTION' away, will sleep again"
				DOWNLOAD_IMG="NO"
				DEFER_STAY_AWAKE="NO"
			fi
		else
			msg_str_d="More than $WAKEUP_CHECK_DEFAULT s from next action, will sleep again"
			DOWNLOAD_IMG="NO"
			DEFER_STAY_AWAKE="NO"
		fi
	fi
	msg "$msg_str_d"
	msg "Next ACTION='$CURR_ACTION', will Suspend for $WAKE_TIME_set s ..."
	WAKE_TIME=$WAKE_TIME_set
}

download_llb () {
	# Pass "keep_wifi" as first argument to leave WiFi on after download
	# (used when charging so SSH stays connected).
	KEEP_WIFI="${1:-}"

	# turn on WIFI
	msg "turn WIFI ON: `powerd_test -s | grep Remaining | awk '{print $6}'` s in '`powerd_test -s | grep Power | awk '{print $3 $4}'`'"
	lipc-set-prop com.lab126.cmd wirelessEnable 1

	# wait before continue evaluating the connection
	sleep $PRE_SLEEP

	TIMER=${NETWORK_TIMEOUT}     # number of seconds to attempt a connection
	CONNECTED=0                  # whether we are currently connected
	while [ 0 -eq $CONNECTED ]; do
		# test whether we are connected to Wifi
		WIFI_STATE=`/usr/bin/lipc-get-prop com.lab126.wifid cmState | grep CONNECTED`
		if [ "$WIFI_STATE" = "CONNECTED" ]; then
			CONNECTED=1
		fi

		# if not connected, check timeout or sleep 1s
		if [ 0 -eq $CONNECTED ]; then
			TIMER=`expr $TIMER - 1`
			if [ 0 -eq $TIMER ]; then
				msg "No internet connection after ${NETWORK_TIMEOUT} seconds, aborting."
				break
			else
				sleep 1
			fi
		fi
	done

	sleep $PRE_SLEEP

	# download
	if [ 1 -eq $CONNECTED ]; then
		msg "WIFI connected, start download ..."

		if [ -f $FN_TEMP ]; then
			rm $FN_TEMP
			msg "Removing old temp file"
		fi

		curl -k -o $FN_TEMP $IMG_URL
		if [ $? -eq 0 ]; then
			# Success
			msg "Download image successful"
			if [ -f $FN ]; then
				rm $FN
			fi
			# rename temporary image to recent bulletin
			mv $FN_TEMP $FN
			DEFER_STAY_AWAKE="YES"
			DL_FAILED="NO"
			RETRIES=0
		else
			# Failed
			msg "Could not download recent image, trigger fail_mode"
			DL_FAILED="YES"
			set_retries
			if [ -f $FN ]; then
				rm $FN
			fi
			cp $FN_ERROR $FN
		fi
		DOWNLOAD_IMG="NO"

		# sync the time
		ntpdate $NTP_SERVER
		if [ $? -ne 0 ]; then
			msg "Could not receive current time!"
		else
			msg "Time sync successful"
			hwclock -w
		fi

		# send log
		send_log

	else
		msg "Failed to connect, trigger fail_mode"
		DL_FAILED="YES"
		set_retries
	fi

	# Stop WIFI — unless caller asked to keep it on (e.g. when charging)
	if [ "$KEEP_WIFI" != "keep_wifi" ]; then
		lipc-set-prop com.lab126.cmd wirelessEnable 0
		msg "WIFI OFF: `powerd_test -s | grep Remaining | awk '{print $6}'` s in '`powerd_test -s | grep Power | awk '{print $3 $4}'`'"
	else
		msg "WIFI kept on (charging mode)"
	fi
	CONNECTED=0
}

set_retries () {
	# Retries failed beyond retries limit
	if [ $RETRIES -gt $DL_RETRIES ]; then
		msg "$RETRIES times failed to download. Switch to normal wake up intervals!"
		DOWNLOAD_IMG="YES"
		DL_FAILED="NO"
		DEFER_STAY_AWAKE="NO"
		RETRIES=0
	fi
	RETRIES=`expr $RETRIES + 1`
}

write_wakeup () {
	# Write the RTC wake up timer while in readyToSuspend state
	if [ $WAKEUP_S -lt $WAKEUP_MINIMAL ]; then
		msg "Desired wakeup '$WAKEUP_S' smaller than WAKEUP_MINIMAL, reset to $WAKEUP_MINIMAL"
		WAKEUP_S=$WAKEUP_MINIMAL
	fi
	TIME_LEFT=`powerd_test -s | grep Remaining | awk '{print int($6)}'`

	if [ "$DEFER_STAY_AWAKE" = "NO" ]; then
		# Make sure we have enough time left in readyToSuspend to set the wakeup
		if [ $TIME_LEFT -gt $LATEST_WAKEUP_SET ]; then
			while [ "`lipc-get-prop com.lab126.powerd state`" = "readyToSuspend" ]; do
				lipc-set-prop -i com.lab126.powerd rtcWakeup $WAKEUP_S
				SUCCESS_SET_WAKEUP=$?
				if [ $SUCCESS_SET_WAKEUP -eq 0 ]; then
					msg "Set rtcWakeup to $WAKEUP_S s"
				else
					msg "Could not set wakeup to '$WAKEUP_S'. Error '$SUCCESS_SET_WAKEUP'"
				fi
				sleep 1
			done
		else
			msg "Too late to set wakeup (only ${TIME_LEFT}s left, need >${LATEST_WAKEUP_SET}s)"
		fi
	else
		# next round is a download — stay awake
		DOWNLOAD_IMG="YES"
		# hit once to transition from readyToSuspend back to active
		powerd_test -p
		msg "Will download soon — staying awake!"
		sleep 10
		# hit a second time to go to screensaver
		powerd_test -p
	fi
}

display_image () {
	# display most recent image
	msg "Display image!"

	if [ "$DEBUG" != "YES" ]; then
		eips -c
		eips -c
		eips -g $1
	fi
}

# END: FIRST BLOCK: FUNCTIONS
# -------------------------------



# -------------------------------
# START: SECOND BLOCK: VARIABLES

# Define ACTIONs (hh:mm, space-separated)
ACTION_TIME="01:01 13:01"

# Debug
DEBUG="NO"

# Don't sleep within this many seconds of an action
STAY_AWAKE="240"
# Default wake-and-check interval: 12 h (capped below max action gap of ~13 h)
WAKEUP_CHECK_DEFAULT=43200
# If download failed, retry every 10 min
WAKEUP_CHECK_DEFAULT_FAIL=600
# Retries after failure before switching back to normal intervals
DL_RETRIES=3
# Minimum sleep time in seconds
WAKEUP_MINIMAL=60
# Do not attempt to set rtcWakeup if fewer than this many seconds remain
# in the readyToSuspend window (0 = always try, 5 is a safer value)
LATEST_WAKEUP_SET=5

# WIFI
NETWORK_TIMEOUT=60
# Time to wait after switching WIFI on before checking connection
PRE_SLEEP=1
NTP_SERVER="0.pool.ntp.org"

# Load secrets (IMG_URL, TELE_URL, TELE_API_KEY)
SECRETS_FILE="$(dirname $0)/weather-secrets.sh"
if [ ! -f "$SECRETS_FILE" ]; then
	echo "ERROR: secrets file not found: $SECRETS_FILE" >&2
	echo "Copy kindle/weather-secrets.sh.example to kindle/weather-secrets.sh and fill in your values." >&2
	exit 1
fi
. "$SECRETS_FILE"

# Image file and folder
FOLDER="/mnt/us/weather"
FN_TEMP=$FOLDER/llb_temp.png
FN_ERROR=$FOLDER/weather-image-error.png
FN=$FOLDER/sf-weather.png

# Display error image on startup
cp $FN_ERROR $FN

# Log File
LOG_FILE="/mnt/us/weather/display-weather.log"
# Start with a fresh log on each run
if [ -f "$LOG_FILE" ]; then
	rm $LOG_FILE
fi
touch $LOG_FILE

# Internal start values
EIPSROW=1
DOWNLOAD_IMG="YES"
DEFER_STAY_AWAKE="NO"
AWAKE_AGAIN="NO"
WAKEUP_S=$WAKEUP_CHECK_DEFAULT
RETRIES=1
DL_FAILED="NO"

# END: SECOND BLOCK: VARIABLES
# -------------------------------
#
#################################
#
# -------------------------------
# START: THIRD BLOCK: INFINITE LOOP

# Startup: wait for powerd to fully initialize, then check if externally
# powered before entering the main loop.
sleep 10
if is_charging; then
	msg "Startup: external power detected — enabling WiFi."
	lipc-set-prop com.lab126.cmd wirelessEnable 1
	# Do an immediate download on startup while already in active state
	download_llb keep_wifi
	display_image $FN
	DOWNLOAD_IMG="NO"
	DEFER_STAY_AWAKE="NO"
	# Enter the charging loop — keeps WiFi up, services scheduled
	# downloads every 60s, and exits when the charger is disconnected.
	msg "Entering charging loop — WiFi stays on until unplugged."
	while is_charging; do
		calc_wakeup
		if [ "$DOWNLOAD_IMG" = "YES" ]; then
			msg "Charging: scheduled download triggered."
			download_llb keep_wifi
			display_image $FN
			DOWNLOAD_IMG="NO"
			DEFER_STAY_AWAKE="NO"
		fi
		sleep 60
	done
	msg "Charger disconnected — turning WiFi off, resuming normal sleep cycle."
	lipc-set-prop com.lab126.cmd wirelessEnable 0
else
	# Not charging — wait for the user to press the power button
	# (entering screensaver) before starting the main loop.
	wait_for_ss
fi

# Never-ending main loop
while [ 1 -eq 1 ]; do

	if [ "$DOWNLOAD_IMG" = "YES" ]; then
		# Download is performed in 'active' mode.
		# First enter screensaver so we can safely simulate a power button
		# press without sending the device into an unrecoverable sleep.
		wait_for_ss
		# Transition to active
		powerd_test -p
		# Download (sets DL_FAILED, DEFER_STAY_AWAKE, DOWNLOAD_IMG)
		download_llb
		# Return to screensaver
		powerd_test -p
		# Display the freshly downloaded image (or error image on failure)
		display_image $FN
	fi

	# Wait for readyToSuspend, recalculate wakeup time, and set rtcWakeup.
	# Also handles the charging-aware sleep path via wait_while_charging.
	wait_for_ready
	sleep 1
	msg "Mainloop: `powerd_test -s | grep Remaining | awk '{print $6}'` s in '`powerd_test -s | grep Power | awk '{print $3 $4}'`'"

done

# END: THIRD BLOCK: INFINITE LOOP
# -------------------------------
