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
        # OpenWeatherMap weather codes
        condition_map = {
            # Thunderstorm
            200: "tsra", # thunderstorm with light rain
            201: "tsra", # thunderstorm with rain
            202: "tsra", # thunderstorm with heavy rain
            210: "tsra", # light thunderstorm
            211: "tsra", # thunderstorm
            212: "tsra", # heavy thunderstorm
            221: "tsra", # ragged thunderstorm
            230: "tsra", # thunderstorm with light drizzle
            231: "tsra", # thunderstorm with drizzle
            232: "tsra", # thunderstorm with heavy drizzle
            # Drizzle
            300: "hi_shwrs", # light intensity drizzle
            301: "hi_shwrs", # drizzle
            302: "hi_shwrs", # heavy intensity drizzle
            310: "hi_shwrs", # light intensity drizzle rain
            311: "hi_shwrs", # drizzle rain
            312: "hi_shwrs", # heavy intensity drizzle rain
            313: "hi_shwrs", # shower rain and drizzle
            314: "hi_shwrs", # heavy shower rain and drizzle
            321: "hi_shwrs", # shower drizzle
            # Rain
            500: "shra", # light rain
            501: "ra",   # moderate rain
            502: "ra",   # heavy intensity rain
            503: "ra",   # very heavy rain
            504: "ra",   # extreme rain
            511: "fzra", # freezing rain
            520: "shra", # light intensity shower rain
            521: "shra", # shower rain
            522: "shra", # heavy intensity shower rain
            531: "shra", # ragged shower rain
            # Snow
            600: "sn",   # light snow
            601: "sn",   # snow
            602: "sn",   # heavy snow
            611: "ip",   # sleet
            612: "ip",   # light shower sleet
            613: "ip",   # shower sleet
            615: "rasn", # light rain and snow
            616: "rasn", # rain and snow
            620: "sn",   # light shower snow
            621: "sn",   # shower snow
            622: "sn",   # heavy shower snow
            # Atmosphere
            701: "fg",   # mist
            711: "fg",   # smoke
            721: "fg",   # haze
            731: "fg",   # sand/dust whirls
            741: "fg",   # fog
            751: "fg",   # sand
            761: "fg",   # dust
            762: "fg",   # volcanic ash
            771: "wind", # squalls
            781: "torn", # tornado
            # Clear/Clouds
            800: "skc",  # clear sky
            801: "few",  # few clouds: 11-25%
            802: "sct",  # scattered clouds: 25-50%
            803: "bkn",  # broken clouds: 51-84%
            804: "ovc",  # overcast clouds: 85-100%
        }
        return condition_map.get(code, "skc")

    try:
        # Configuration
        OPENWEATHER_API_KEY = os.environ.get('OPENWEATHER_API_KEY')
        S3BucketName = os.environ.get('S3BucketName')
        S3FileName = os.environ.get('S3FileName')
        LATITUDE = os.environ.get('LATITUDE')
        LONGITUDE = os.environ.get('LONGITUDE')
        
        # Validate all required environment variables
        required_vars = {
            'OPENWEATHER_API_KEY': OPENWEATHER_API_KEY,
            'S3BucketName': S3BucketName,
            'S3FileName': S3FileName,
            'LATITUDE': LATITUDE,
            'LONGITUDE': LONGITUDE
        }
        
        missing_vars = [k for k, v in required_vars.items() if not v]
        if missing_vars:
            raise ValueError(f"Missing required environment variables: {', '.join(missing_vars)}")

        try:
            latitude = float(LATITUDE)
            longitude = float(LONGITUDE)
        except ValueError:
            raise ValueError("LATITUDE and LONGITUDE must be valid numbers")

        # Fetch weather data with timeout
        weather_url = f'https://api.openweathermap.org/data/2.5/forecast?lat={latitude}&lon={longitude}&appid={OPENWEATHER_API_KEY}&units=metric'
        request = Request(weather_url, headers={'User-Agent': 'AWS Lambda Weather Function'})
        
        try:
            with urlopen(request, timeout=5) as response:
                weather_json = json.loads(response.read())
                if weather_json.get('cod') != '200' and weather_json.get('cod') != 200:
                    raise Exception(f"Weather API error: {weather_json.get('message', 'Unknown error')}")
        except Exception as e:
            print(f"Error fetching weather data: {str(e)}")
            raise

        # Parse dates
        today = datetime.datetime.now(pytz.timezone("America/Los_Angeles"))
        print('Current time:', today.strftime("%Y-%m-%d %H:%M %Z"))

        # Determine if report for today or tomorrow
        cutoffTime = datetime.datetime.strptime('16:59','%H:%M')
        lookupDay = 1 if today.time() >= cutoffTime.time() else 0
        day_one = today + datetime.timedelta(days=lookupDay)

        days_of_week = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday']

        # Parse temperatures & icons - Optimized version
        highs = [float('-inf')] * 4
        lows = [float('inf')] * 4
        weather_codes = [[] for _ in range(4)]
        
        base_date = day_one.date()
        
        # Process each forecast entry
        for item in weather_json['list']:
            dt = datetime.datetime.fromtimestamp(item['dt'], pytz.timezone("America/Los_Angeles"))
            day_diff = (dt.date() - base_date).days
            
            if 0 <= day_diff < 4:  # Only process next 4 days
                highs[day_diff] = max(highs[day_diff], item['main']['temp_max'])
                lows[day_diff] = min(lows[day_diff], item['main']['temp_min'])
                weather_codes[day_diff].append(item['weather'][0]['id'])

        # Convert temperatures and get icons
        icons = []
        for i in range(4):
            if highs[i] != float('-inf'):
                highs[i] = int(round(highs[i]))
                lows[i] = int(round(lows[i]))
                # Get most common weather code for the day
                most_common = max(set(weather_codes[i]), key=weather_codes[i].count) if weather_codes[i] else 800
                icons.append(weather_code_to_icon(most_common))
            else:
                highs[i] = None
                lows[i] = None
                icons.append("skc")

        # Add detailed logging here, before SVG processing
        print(f"Location: {latitude}, {longitude}")
        print(f"Processing forecast for: {day_one.strftime('%Y-%m-%d')}")
        print(f"Temperatures (°C) - Next 4 days:")
        for i in range(4):
            print(f"Day {i+1}: High: {highs[i]}, Low: {lows[i]}, Weather: {icons[i]}")

        # Preprocess SVG
        with codecs.open('weather-script-preprocess.svg', 'r', encoding='utf-8') as f:
            output = f.read()

        # Replace placeholders
        replacements = {
            'UPDATE': f"OpenW:{today.strftime('%H:%M')}",
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
