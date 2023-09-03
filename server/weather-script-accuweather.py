import json

print('Loading function')


def lambda_handler(event, context):
    from xml.dom import minidom
    import json
    import datetime
    import time
    import pytz
    import codecs
    import boto3
    import os
    import subprocess
    from shutil import copyfile
    from urllib.request import urlopen
    from PIL import Image
    
    #
    # AccuWether API Key
    #
    AccuWeatherAPIKey = os.environ.get('AccuWeatherAPIKey')

    #
    # Geographic location
    #
    AccuWetherLocation = os.environ.get('AccuWetherLocation')
    
    #
    # Download and parse weather data
    #

    # Fetch data (change lat and lon to desired location)
    weather_AccuWeather = urlopen('http://dataservice.accuweather.com/forecasts/v1/daily/5day/' + AccuWetherLocation + '?apikey=' + AccuWeatherAPIKey + '&metric=true')
    weather_json = json.loads(weather_AccuWeather.read())

    # Parse dates
    today = datetime.datetime.now(pytz.timezone("America/Los_Angeles"))
    print('Current time: ' + str(today))

    # Determine if report for today or tomorrow
    cutoffTime = datetime.datetime.strptime('16:59','%H:%M')
    if (today.time() >= cutoffTime.time()):
        lookupDay = 1
    else:
        lookupDay = 0
    day_one = today + datetime.timedelta(days=lookupDay)

    days_of_week = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday']

    # convert icons
    def icon_conv(argument):
        return {
            1: "skc",
            2: "skc",
            3: "few",
            4: "sct",
            5: "skc",
            6: "bkn",
            7: "bkn",
            8: "ovc",
            11: "fg",
            12: "shra",
            13: "hi_shwrs",
            14: "hi_shwrs",
            15: "tsra",
            16: "scttsra",
            17: "scttsra",
            18: "ra",
            19: "ip",
            20: "raip",
            21: "raip",
            22: "sn",
            23: "sn",
            24: "fzra",
            25: "ip",
            26: "fzra",
            29: "rasn",
            30: "hot",
            31: "cold",
            32: "wind"
        }.get(argument, "hot")

    # Parse temperatures & icons & temperatures
    highs = [None]*4
    lows = [None]*4
    icons = [None]*4
    for i in range(0, 4):
        highs[i] = int(round(weather_json["DailyForecasts"][(i+lookupDay)]["Temperature"]["Maximum"]["Value"]))
        lows[i] = int(round(weather_json["DailyForecasts"][(i+lookupDay)]["Temperature"]["Minimum"]["Value"]))
        icons[i] = icon_conv(weather_json["DailyForecasts"][(i+lookupDay)]["Day"]["Icon"])
    
	#
	# Preprocess SVG
	#

    # Open SVG to process
    output = codecs.open('weather-script-preprocess.svg', 'r', encoding='utf-8').read()
    output = output.replace('UPDATE', "AccuW: " + today.strftime("%H:%M"))
    output = output.replace('DATE', days_of_week[(day_one).weekday()] + ", " + day_one.strftime("%d.%m.%Y"))

    # Insert icons and temperatures
    output = output.replace('ICON_ONE',icons[0]).replace('ICON_TWO',icons[1]).replace('ICON_THREE',icons[2]).replace('ICON_FOUR',icons[3])
    output = output.replace('HIGH_ONE',str(highs[0])).replace('HIGH_TWO',str(highs[1])).replace('HIGH_THREE',str(highs[2])).replace('HIGH_FOUR',str(highs[3]))
    output = output.replace('LOW_ONE',str(lows[0])).replace('LOW_TWO',str(lows[1])).replace('LOW_THREE',str(lows[2])).replace('LOW_FOUR',str(lows[3]))

    # Insert days of week
    one_day = datetime.timedelta(days=1)
    output = output.replace('DAY_TWO',days_of_week[(day_one + 1*one_day).weekday()])
    output = output.replace('DAY_THREE',days_of_week[(day_one + 2*one_day).weekday()])
    output = output.replace('DAY_FOUR',days_of_week[(day_one + 3*one_day).weekday()])

    # Write output to temp directory
    codecs.open('/tmp/weather-script-output.svg', 'w', encoding='utf-8').write(output)

    # Convert SVG to PNG
    cmd1 = '/opt/bin/rsvg-convert --background-color=white -o /tmp/weather-script-output.png /tmp/weather-script-output.svg'
    try:
        subprocess.check_output(cmd1,shell=True,stderr=subprocess.STDOUT)
    except subprocess.CalledProcessError as e:
        raise RuntimeError("command '{}' return with error (code {}): {}".format(e.cmd, e.returncode, e.output))
    
    img = Image.open('/tmp/weather-script-output.png').convert('L')
    img.save('/tmp/weather-grayscale.png')
    
    # Upload file to S3
    S3BucketName = os.environ.get('S3BucketName')
    S3FileName = os.environ.get('S3FileName')
    s3 = boto3.client("s3")
    s3.upload_file('/tmp/weather-grayscale.png', S3BucketName, S3FileName, ExtraArgs={'ContentType': "image/png"})
