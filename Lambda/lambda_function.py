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

    #
    # DarkSky API Key
    #
    DarkSkyAPIKey = "< Fill me out >"

    #
    # Geographic location
    #

    latitude = 37.776229
    longitude = -122.393518

	#
	# Download and parse weather data
	#

    # Fetch data (change lat and lon to desired location)
    weather_darksky = urlopen('https://api.darksky.net/forecast/' + DarkSkyAPIKey + '/' + str(latitude) + ',' + str(longitude) + '?exclude=currently,minutely,hourly,alerts,flags&units=si')
    weather_json = json.loads(weather_darksky.read())

    # Parse dates
    #day_one = datetime.datetime.strptime(xml_day_one, '%Y-%m-%d')
    #today = datetime.datetime.now(pytz.timezone('US/Pacific'))
    today = datetime.datetime.now(pytz.timezone(weather_json["timezone"]))
    print('Current time: ' + str(today))

    # Determine if report for today or tomorrow
    cutoffTime = datetime.datetime.strptime('17:59','%H:%M')
    if (today.time() > cutoffTime.time()):
        lookupDay = 1
    else:
        lookupDay = 0
    day_one = today + datetime.timedelta(days=lookupDay)

    days_of_week = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday']

    # convert icons
    def icon_conv(argument):
        return {
            'clear-day': "skc",
            'clear-night': "skc",
            'rain': "ra",
            'snow': "sn",
            'sleet': "ip",
            'wind': "wind",
            'fog': "fg",
            'cloudy': "bkn",
            'partly-cloudy-day': "sct",
            'partly-cloudy-night': "sct",
            'hail': "frza",
            'thunderstorm': "tsra",
            'tornado': "tornado"
        }.get(argument, "hot")

    # Parse temperatures & icons & temperatures
    highs = [None]*4
    lows = [None]*4
    icons = [None]*4
    for i in range(0, 4):
        highs[i] = int(round(weather_json["daily"]["data"][(i+lookupDay)]["temperatureHigh"], 0))
        lows[i] = int(round(weather_json["daily"]["data"][(i+lookupDay)]["temperatureLow"], 0))
        icons[i] = icon_conv(weather_json["daily"]["data"][(i+lookupDay)]["icon"])

	#
	# Preprocess SVG
	#

    # Open SVG to process
    output = codecs.open('weather-script-preprocess.svg', 'r', encoding='utf-8').read()

    output = output.replace('UPDATE', "DarkSky: " + today.strftime("%H:%M"))
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
    copyfile('rsvg-convert', '/tmp/rsvg-convert')
    os.chmod('/tmp/rsvg-convert', 0o775)
    cmd = '/tmp/rsvg-convert --background-color=white -o /tmp/weather-script-output.png /tmp/weather-script-output.svg'
    subprocess.check_output(cmd, shell=True)

    # Upload file to S3
    s3 = boto3.resource('s3')
    s3.meta.client.upload_file('/tmp/weather-script-output.png', 'cdn.kangaroonet.de', 'sf-weather.png', ExtraArgs={'ContentType': "image/png", 'ACL': "public-read"})
