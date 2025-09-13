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
    from urllib.request import urlopen, Request
    from urllib.parse import quote
    from PIL import Image

    def weather_code_to_icon(code):
        condition_map = {
            1000: "skc",    # Clear/Sunny
            1003: "few",    # Partly cloudy
            1006: "sct",    # Cloudy
            1009: "bkn",    # Overcast
            1030: "fg",     # Mist
            1063: "shra",   # Patchy rain
            1066: "sn",     # Patchy snow
            1069: "ip",     # Patchy sleet
            1072: "fzra",   # Patchy freezing drizzle
            1087: "tsra",   # Thundery outbreaks
            1114: "sn",     # Blowing snow
            1117: "sn",     # Blizzard
            1135: "fg",     # Fog
            1147: "fg",     # Freezing fog
            1150: "hi_shwrs", # Light drizzle
            1153: "hi_shwrs", # Light drizzle
            1168: "fzra",   # Freezing drizzle
            1171: "fzra",   # Heavy freezing drizzle
            1180: "shra",   # Light rain
            1183: "shra",   # Light rain
            1186: "ra",     # Moderate rain
            1189: "ra",     # Moderate rain
            1192: "ra",     # Heavy rain
            1195: "ra",     # Heavy rain
            1198: "fzra",   # Light freezing rain
            1201: "fzra",   # Moderate/heavy freezing rain
            1204: "ip",     # Light sleet
            1207: "ip",     # Moderate/heavy sleet
            1210: "sn",     # Light snow
            1213: "sn",     # Light snow
            1216: "sn",     # Moderate snow
            1219: "sn",     # Moderate snow
            1222: "sn",     # Heavy snow
            1225: "sn",     # Heavy snow
            1237: "ip",     # Ice pellets
            1240: "shra",   # Light rain shower
            1243: "ra",     # Heavy rain shower
            1246: "ra",     # Torrential rain shower
            1249: "ip",     # Light sleet showers
            1252: "ip",     # Heavy sleet showers
            1255: "sn",     # Light snow showers
            1258: "sn",     # Heavy snow showers
            1261: "ip",     # Light ice pellet showers
            1264: "ip",     # Heavy ice pellet showers
            1273: "tsra",   # Light rain with thunder
            1276: "tsra",   # Heavy rain with thunder
            1279: "tsra",   # Light snow with thunder
            1282: "tsra"    # Heavy snow with thunder
        }
        return condition_map.get(code, "skc")

    try:
        # Configuration
        WEATHER_API_KEY = os.environ.get('WEATHER_API_KEY')
        S3BucketName = os.environ.get('S3BucketName')
        S3FileName = os.environ.get('S3FileName')
        
        if not all([WEATHER_API_KEY, S3BucketName, S3FileName]):
            raise ValueError("Missing required environment variables")

        # Geographic location (San Francisco)
        latitude = 37.774049
        longitude = -122.395889
        location = f"{latitude},{longitude}"

        # Fetch weather data with timeout
        weather_url = f'http://api.weatherapi.com/v1/forecast.json?key={WEATHER_API_KEY}&q={quote(location)}&days=5&aqi=no&hour=0'
        request = Request(weather_url, headers={'User-Agent': 'AWS Lambda Weather Function'})
        
        try:
            with urlopen(request, timeout=5) as response:
                weather_json = json.loads(response.read())
                if 'error' in weather_json:
                    raise Exception(f"Weather API error: {weather_json['error']['message']}")
        except Exception as e:
            print(f"Error fetching weather data: {str(e)}")
            raise

        # Parse dates
        today = datetime.datetime.now(pytz.timezone("America/Los_Angeles"))
        print('Current time:', today.strftime("%Y-%m-%d %H:%M:%S %Z"))

        # Determine if report for today or tomorrow
        cutoffTime = datetime.datetime.strptime('16:59','%H:%M')
        lookupDay = 1 if today.time() >= cutoffTime.time() else 0
        day_one = today + datetime.timedelta(days=lookupDay)

        days_of_week = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday']

        # Parse temperatures & icons
        highs = []
        lows = []
        icons = []
        
        forecast_days = weather_json['forecast']['forecastday']
        print(f'Number of forecast days available: {len(forecast_days)}')
        
        # Get available forecasts (up to 4 days)
        for i in range(min(4, len(forecast_days) - lookupDay)):
            day_index = i + lookupDay
            if day_index < len(forecast_days):
                forecast_day = forecast_days[day_index]
                highs.append(int(round(forecast_day['day']['maxtemp_c'])))
                lows.append(int(round(forecast_day['day']['mintemp_c'])))
                icons.append(weather_code_to_icon(forecast_day['day']['condition']['code']))

        # Pad with None if we don't have enough days
        while len(highs) < 4:
            highs.append(None)
            lows.append(None)
            icons.append("skc")

        # Preprocess SVG
        with codecs.open('weather-script-preprocess.svg', 'r', encoding='utf-8') as f:
            output = f.read()

        # Replace placeholders
        replacements = {
            'UPDATE': f"WeatherAPI: {today.strftime('%H:%M')}",
            'DATE': f"{days_of_week[day_one.weekday()]}, {day_one.strftime('%d.%m.%Y')}",
            'ICON_ONE': icons[0],
            'ICON_TWO': icons[1],
            'ICON_THREE': icons[2],
            'ICON_FOUR': icons[3],
            'HIGH_ONE': str(highs[0]) if highs[0] is not None else "N/A",
            'HIGH_TWO': str(highs[1]) if highs[1] is not None else "N/A",
            'HIGH_THREE': str(highs[2]) if highs[2] is not None else "N/A",
            'HIGH_FOUR': str(highs[3]) if highs[3] is not None else "N/A",
            'LOW_ONE': str(lows[0]) if lows[0] is not None else "N/A",
            'LOW_TWO': str(lows[1]) if lows[1] is not None else "N/A",
            'LOW_THREE': str(lows[2]) if lows[2] is not None else "N/A",
            'LOW_FOUR': str(lows[3]) if lows[3] is not None else "N/A",
            'DAY_TWO': days_of_week[(day_one + datetime.timedelta(days=1)).weekday()],
            'DAY_THREE': days_of_week[(day_one + datetime.timedelta(days=2)).weekday()],
            'DAY_FOUR': days_of_week[(day_one + datetime.timedelta(days=3)).weekday()]
        }

        for key, value in replacements.items():
            output = output.replace(key, value)

        # Write output to temp directory
        with codecs.open('/tmp/weather-script-output.svg', 'w', encoding='utf-8') as f:
            f.write(output)

        # Convert SVG to PNG
        cmd1 = '/opt/bin/rsvg-convert --background-color=white -o /tmp/weather-script-output.png /tmp/weather-script-output.svg'
        try:
            subprocess.check_output(cmd1, shell=True, stderr=subprocess.STDOUT, timeout=30)
        except subprocess.CalledProcessError as e:
            raise RuntimeError(f"Command '{e.cmd}' failed with error (code {e.returncode}): {e.output}")
        except subprocess.TimeoutExpired:
            raise RuntimeError("SVG conversion timed out after 30 seconds")

        # Convert to grayscale
        with Image.open('/tmp/weather-script-output.png') as img:
            img_gray = img.convert('L')
            img_gray.save('/tmp/weather-grayscale.png')

        # Upload file to S3
        s3 = boto3.client("s3")
        s3.upload_file(
            '/tmp/weather-grayscale.png', 
            S3BucketName, 
            S3FileName, 
            ExtraArgs={'ContentType': "image/png"}
        )

        print('Weather update completed successfully')
        return {
            'statusCode': 200,
            'body': json.dumps('Weather update completed successfully')
        }

    except Exception as e:
        print(f"Error: {str(e)}")
        raise
