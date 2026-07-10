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

    # Get environment variables
    S3BucketName = os.environ.get('S3BucketName')
    S3FileName = os.environ.get('S3FileName')

    #
    # Geographic location
    #
    latitude = 37.774049
    longitude = -122.395889

    #
    # Download and parse weather data
    #

    # Fetch data (change lat and lon to desired location)
    weather_xml = urlopen('http://graphical.weather.gov/xml/SOAP_server/ndfdSOAPclientByDay.php?whichClient=NDFDgenByDay&lat=' + str(latitude) + '&lon=' + str(longitude) + '&format=24+hourly&numDays=4&Unit=m').read()
    dom = minidom.parseString(weather_xml)
    print('Raw weather data: ' + str(dom.getElementsByTagName('temperature')))
   
    # Parse temperatures
    xml_temperatures = dom.getElementsByTagName('temperature')
    highs = [None]*4
    lows = [None]*4
    for item in xml_temperatures:
        if item.getAttribute('type') == 'maximum':
            values = item.getElementsByTagName('value')
            for i in range(len(values)):
                highs[i] = int(values[i].firstChild.nodeValue)
        if item.getAttribute('type') == 'minimum':
            values = item.getElementsByTagName('value')
            for i in range(len(values)):
                lows[i] = int(values[i].firstChild.nodeValue)

    # Parse icons
    xml_icons = dom.getElementsByTagName('icon-link')
    icons = [None]*4
    for i in range(len(xml_icons)):
        icons[i] = xml_icons[i].firstChild.nodeValue.split('/')[-1].split('.')[0].rstrip('0123456789')

    # Parse dates
    xml_day_one = dom.getElementsByTagName('start-valid-time')[0].firstChild.nodeValue[0:10]
    day_one = datetime.datetime.strptime(xml_day_one, '%Y-%m-%d')
    today = datetime.datetime.now(pytz.timezone("America/Los_Angeles"))
    print('Current time: ' + str(today))
    days_of_week = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday']

    #
    # Preprocess SVG
    #

    # Open SVG to process
    output = codecs.open('weather-script-preprocess.svg', 'r', encoding='utf-8').read()
    output = output.replace('UPDATE', "NOAA: " + today.strftime("%H:%M"))
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

    # Convert to grayscale
    img = Image.open('/tmp/weather-script-output.png').convert('L')
    img.save('/tmp/weather-grayscale.png')

    # Upload file to S3
    s3 = boto3.client("s3")
    s3.upload_file('/tmp/weather-grayscale.png', S3BucketName, S3FileName, 
                   ExtraArgs={'ContentType': "image/png"})