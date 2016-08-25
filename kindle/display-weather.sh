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
	echo "curl -H `echo ${TELE_API_KEY}` -d `echo ${JSON}` ${TELE_URL}" | sh
	if [ $? ]; then
		msg "Telemetry send!"
	else
		msg "Could not send Telemetry..."
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
	# Only first call after Suspend/screensaver should enter the loop
	while [ "$PSTATE" = "" ]; do
		sleep 1
		PSTATE=`powerd_test -s | grep Ready`
		AWAKE_AGAIN="YES"
	done
	msg "In state Ready: `powerd_test -s | grep Remaining | awk '{print $6}'` s left in '`powerd_test -s | grep Power | awk '{print $3 $4}'`'"
	# if that was the first call, we write the default wakeup to always wake up again.
	if [ "$AWAKE_AGAIN" = "YES" ]; then
		# We are awake again! Check only once the ACTIONS
		msg "------------------------------------------"
		msg "Recalculate and set next wakeup or action!"
		DOWNLOAD_IMG="YES"

		# output: WAKE_TIME and DOWLOAD_IMG
		calc_wakeup

		WAKEUP_S=$WAKE_TIME
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
	# this function returns WAKE_TIME and set DOWNLOAD_IMG
	# CHECK TIME, and recalc sleep timer
	CURRENT_TIME=`date +%s`

	# daily basis
	D_TIME=`expr $CURRENT_TIME % "86400"`
	# initialize WAKE_TIME_set (internal of output WAKE_TIME)
	WAKE_TIME_set=$WAKEUP_CHECK_DEFAULT

	if [ "$DL_FAILED" == "YES" ]; then
		# We could not load image last time - FAIL mode
		msg_str_d="Fail Mode, retry in $WAKEUP_CHECK_DEFAULT_FAIL s."
		CURR_ACTION="Fail mode"
		WAKE_TIME_set=$WAKEUP_CHECK_DEFAULT_FAIL
		DEFER_STAY_AWAKE="NO"
	else
		# see if there is an action coming close, if so, manipulate WAKE_TIME_set
	        # get closest action
		WAKE_TIME_set=$WAKEUP_CHECK_DEFAULT
		CURR_ACTION="Default wakeup"
		for ACTION in `echo $ACTION_TIME | awk '{ s = ""; for (i = 1; i <= NF; i++) print $i }'`; do
			# convert hh:ss into seconds since 00:00
			DESIRED=`echo $ACTION | sed 's/:/ /g' | awk '{print ($1*3600)+($2*60)}'`
			DIFF_TIME_V=`expr $DESIRED - $D_TIME`;
			DIFF_TIME=$DIFF_TIME_V
			
			# Determine if the time refers to tomorrow
			if [ $DIFF_TIME_V -le -120 ]; then
				DIFF_TIME=`expr 86400 + $DIFF_TIME_V`;
			else				
				DIFF_TIME=$DIFF_TIME_V
			fi

			if [ $DIFF_TIME -lt $WAKE_TIME_set ]; then
				if [ $DIFF_TIME -ge 120 ]; then
					# we remove some time, to not wake up to late.
					WAKE_TIME_set=`expr $DIFF_TIME - 120`
					CURR_ACTION=$ACTION
				elif [ $DIFF_TIME -gt -120 ] && [ $DIFF_TIME -lt 120 ]; then
					# ok, download!
					WAKE_TIME_set=0
					CURR_ACTION=$ACTION
				else
					# action past
					msg "$ACTION: $DIFF_TIME s since the action - sleep again!"
				fi
			else
				msg "$ACTION: $DIFF_TIME is larger than $WAKE_TIME_set - sleep again!"
			fi
		done
		# charaterize action
		if [ $WAKE_TIME_set -lt $WAKEUP_CHECK_DEFAULT ]; then
			# We are really close to the event, trigger download.
			if [ $WAKE_TIME_set  -lt $STAY_AWAKE ] && [ "$DEFER_STAY_AWAKE" == "NO" ]; then
				DOWNLOAD_IMG="YES"
				msg_str_d="only $WAKE_TIME_set s away from ' $CURR_ACTION ' action, trigger Download."
				DEFER_STAY_AWAKE="YES"
				# We are close, but its worse going into sleep again
			else
				msg_str_d="$WAKE_TIME_set s from ' $CURR_ACTION ' away, will sleep again"
				DOWNLOAD_IMG="NO"
				DEFER_STAY_AWAKE="NO"
			fi
		# We are hours away, we will sleep for WAKEUP_CHECK_DEFAULT
		else
			msg_str_d="More than $WAKEUP_CHECK_DEFAULT s from next action away, will sleep again"
			DOWNLOAD_IMG="NO"
			DEFER_STAY_AWAKE="NO"
		fi
	fi
	msg "$msg_str_d"
	msg "Next ACTION='$CURR_ACTION', will Suspend for $WAKE_TIME_set s ..."
	WAKE_TIME=$WAKE_TIME_set
}

download_llb () {
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

		# if we can't, checkout timeout or sleep for 1s
		if [ 0 -eq $CONNECTED ]; then
			TIMER=$(($TIMER-1))
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

		#wget -O $FN_TEMP $IMG_URL
		curl -o $FN_TEMP $IMG_URL
		if [ $? -eq 0 ]; then
			# Sucess
			msg "Download image successfull"
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
			msg "Time sync successfull"
			hwclock -w
		fi

		# send log
		send_log

	else
		msg "Failed to connect, trigger fail_mode"
		DL_FAILED="YES"
		set_retries
	fi

	# Stop WIFI
	lipc-set-prop com.lab126.cmd wirelessEnable 0
	CONNECTED=0

	msg "WIFI OFF: `powerd_test -s | grep Remaining | awk '{print $6}'` s in '`powerd_test -s | grep Power | awk '{print $3 $4}'`'"
}

set_retries () {
	# Retries failed beyond retries limit
	if [ $RETRIES -gt $DL_RETRIES ]; then
		msg "$RETRIES times failed to download llb. Switch to normal wake up intervals!"
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
		msg "Desired wakeup in '$WAKEUP_S' smaller than 'WAKEUP_MINIMAL', reset to $WAKEUP_MINIMAL"
		WAKEUP_S=$WAKEUP_MINIMAL
	fi
	TIME_LEFT=`powerd_test -s | grep Remaining | awk '{print int($6)}'`

	# go to sleep.
	if [ $DEFER_STAY_AWAKE == "NO" ]; then
		# make sure that we have enough time to process 'write_wakeup'
		if [ $TIME_LEFT -gt $LATEST_WAKEUP_SET ]; then
			while [ `lipc-get-prop com.lab126.powerd state` = "readyToSuspend" ]; do
				lipc-set-prop -i com.lab126.powerd rtcWakeup $WAKEUP_S 
				SUCESS_SET_WAKEUP=$?
				if [ $SUCESS_SET_WAKEUP -eq 0 ]; then
					echo "set rtcWakeup to $WAKEUP_S" 
				else
					msg "Huch? Could not set wake up to '$WAKEUP_S'. Error '$SUCESS_SET_WAKEUP'"
				fi
				sleep 1
			done
		else
			msg "We are to late, to set wakeup ..."
		fi
		# next round is download, stay awake!
	else
		DOWNLOAD_IMG="YES"
		# we are in ready to suspend, hit it once to get to active
		powerd_test -p
		msg "Oh, we will download soon !"
		sleep 10
		# hit a second time to go screensaver
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
# START: SECOND BLOCK: VARIABELS

# Define ACTIONs
ACTION_TIME="01:01 13:01"

# Debug 
DEBUG="NO"

# Dont sleep 4 min before action
STAY_AWAKE="240"
# wake and check time every 24 hour
WAKEUP_CHECK_DEFAULT=86400
# if fail, retry to DL every 10 min
WAKEUP_CHECK_DEFAULT_FAIL=600
# retries after failure, before switch to normal WAKEUP_CHECK_DEFAULT
DL_RETRIES=3
# Minimal sleep time in seconds
WAKEUP_MINIMAL=60
# rtcWakeup should not be set less than X second before sleep
LATEST_WAKEUP_SET=0

# WIFI
NETWORK_TIMEOUT=60
# time to wait after switching WIFI on
#+wait this time again, after detecting WIFI connecting
PRE_SLEEP=1;
NTP_SERVER="us.pool.ntp.org"
IMG_URL="https://<bucketname>.s3.dualstack.us-west-2.amazonaws.com/weather.png"

# Telemetry
TELE_URL="https://<apiname>.execute-api.us-west-2.amazonaws.com/prod/KindleTelemetry"
TELE_API_KEY="'x-api-key: 12345678'"

# Image file and folder
FOLDER="/mnt/us/weather"
FN_TEMP=$FOLDER/llb_temp.png
FN_ERROR=$FOLDER/weather-image-error.png
FN=$FOLDER/weather.png

# Display standard image
cp $FN_ERROR $FN

#Log File
LOG_FILE="/mnt/us/weather/display-weather.log"
# initialize empty Log-File
if [ -f "$LOG_FILE" ]; then
	rm $LOG_FILE
fi
touch $LOG_FILE

# Set internal start values:
# Set EIPS debug output start row
EIPSROW=1
# load the image in first round
DOWNLOAD_IMG="YES"
# we do not wake up accurately on time, do the action in a timespan
DEFER_STAY_AWAKE="NO"
WAKEUP_S=$WAKEUP_CHECK_DEFAULT
RETRIES=1
DL_FAILED="NO"
NO_WAKEUP_DEAMON=0

# END: SECOND BLOCK: VARIABELS
# -------------------------------
#
#################################
#
# -------------------------------
# START: THIRD BLOCK: INFINITE LOOP


# initial wait until user pressed power button to start the main loop
wait_for_ss

# Start never ending loop...
# -------------------------------
while [ 1 -eq 1 ]; do
	# DOWNLOAD_IMG
	if [ "$DOWNLOAD_IMG" = "YES" ]; then
		# Download will be performed in 'active'-mode:
		# we need to wait for screen save: never simulate the power
		# button in 'active' and bring the kindle into never ending sleep
		wait_for_ss
		# turn into active:
		powerd_test -p
		#returns DL_FAILED="NO" if succesfull download
		download_llb
		# switch back to screensave
		powerd_test -p
		# display most recent image, or if failed display the last image...
		display_image $FN
	fi

	# SET WAKE UP
	# this wait statement does check if we need to sleep again,
	# AND recalc the wakeup time and set the rtcWakeup as well
	wait_for_ready
	sleep 1
	msg "Mainloop: `powerd_test -s | grep Remaining | awk '{print $6}'` s in '`powerd_test -s | grep Power | awk '{print $3 $4}'`'"
done

# END: THIRD BLOCK: INFINITE LOOP
# -------------------------------
