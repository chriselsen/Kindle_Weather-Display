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
    # Geographic location (San Francisco coordinates as example)
    #
    latitude = 37.774049
    longitude = -122.395889

    #
    # Download and parse weather data from Open-Meteo
    #
    weather_url = f'https://api.open-meteo.com/v1/forecast?latitude={latitude}&longitude={longitude}&daily=temperature_2m_max,temperature_2m_min,weathercode&timezone=America%2FLos_Angeles'
    weather_response = urlopen(weather_url)
    weather_json = json.loads(weather_response.read())

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

    # Convert Open-Meteo weather codes to icons
    def weather_code_to_icon(code):
        weather_codes = {
            0: "skc",  # Clear sky
            1: "few",  # Mainly clear
            2: "sct",  # Partly cloudy
            3: "bkn",  # Overcast
            45: "fg",  # Foggy
            48: "fg",  # Depositing rime fog
            51: "hi_shwrs",  # Light drizzle
            53: "shra",  # Moderate drizzle
            55: "ra",  # Dense drizzle
            61: "shra",  # Slight rain
            63: "ra",  # Moderate rain
            65: "ra",  # Heavy rain
            71: "sn",  # Slight snow
            73: "sn",  # Moderate snow
            75: "sn",  # Heavy snow
            77: "ip",  # Snow grains
            80: "shra",  # Slight rain showers
            81: "shra",  # Moderate rain showers
            82: "shra",  # Violent rain showers
            85: "sn",  # Slight snow showers
            86: "sn",  # Heavy snow showers
            95: "tsra",  # Thunderstorm
            96: "tsra",  # Thunderstorm with slight hail
            99: "tsra",  # Thunderstorm with heavy hail
        }
        return weather_codes.get(code, "skc")

    # Parse temperatures & icons
    highs = []
    lows = []
    icons = []
    
    for i in range(4):
        day_index = i + lookupDay
        highs.append(int(round(weather_json["daily"]["temperature_2m_max"][day_index])))
        lows.append(int(round(weather_json["daily"]["temperature_2m_min"][day_index])))
        icons.append(weather_code_to_icon(weather_json["daily"]["weathercode"][day_index]))

    #
    # Preprocess SVG
    #

    # Open SVG to process
    output = codecs.open('weather-script-preprocess.svg', 'r', encoding='utf-8').read()
    output = output.replace('UPDATE', "OpenMeteo: " + today.strftime("%H:%M"))
    output = output.replace('DATE', days_of_week[(day_one).weekday()] + ", " + day_one.strftime("%d.%m.%Y"))

    # Insert icons and temperatures
    output = output.replace('ICON_ONE', icons[0])
    output = output.replace('ICON_TWO', icons[1])
    output = output.replace('ICON_THREE', icons[2])
    output = output.replace('ICON_FOUR', icons[3])
    
    output = output.replace('HIGH_ONE', str(highs[0]))
    output = output.replace('HIGH_TWO', str(highs[1]))
    output = output.replace('HIGH_THREE', str(highs[2]))
    output = output.replace('HIGH_FOUR', str(highs[3]))
    
    output = output.replace('LOW_ONE', str(lows[0]))
    output = output.replace('LOW_TWO', str(lows[1]))
    output = output.replace('LOW_THREE', str(lows[2]))
    output = output.replace('LOW_FOUR', str(lows[3]))

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

    # Convert to grayscale
    img = Image.open('/tmp/weather-script-output.png').convert('L')
    img.save('/tmp/weather-grayscale.png')

    # Upload file to S3
    S3BucketName = os.environ.get('S3BucketName')
    S3FileName = os.environ.get('S3FileName')
    s3 = boto3.client("s3")
    s3.upload_file('/tmp/weather-grayscale.png', S3BucketName, S3FileName, 
                   ExtraArgs={'ContentType': "image/png"})