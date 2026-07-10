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
    from urllib.parse import urlencode
    from PIL import Image

    def weather_code_to_icon(code):
        # tomorrow.io weather codes
        # Reference: https://docs.tomorrow.io/reference/data-layers-weather-codes
        condition_map = {
            # Clear / Cloudy
            1000: "skc",     # clear
            1100: "few",     # mostly clear
            1101: "sct",     # partly cloudy
            1102: "bkn",     # mostly cloudy
            1001: "ovc",     # cloudy
            # Fog
            2100: "fg",      # fog light
            2000: "fg",      # fog
            # Drizzle / Rain
            4000: "hi_shwrs", # drizzle
            4200: "shra",    # rain light
            4001: "ra",      # rain
            4201: "ra",      # rain heavy
            # Snow
            5001: "sn",      # flurries
            5100: "sn",      # snow light
            5000: "sn",      # snow
            5101: "sn",      # snow heavy
            # Freezing precipitation
            6000: "fzra",    # freezing drizzle
            6200: "fzra",    # freezing rain light
            6001: "fzra",    # freezing rain
            6201: "fzra",    # freezing rain heavy
            # Ice pellets / sleet
            7102: "ip",      # ice pellets light
            7000: "ip",      # ice pellets
            7101: "ip",      # ice pellets heavy
            # Thunderstorm
            8000: "tsra",    # thunderstorm
        }
        return condition_map.get(code, "skc")

    try:
        # Configuration
        TOMORROW_API_KEY = os.environ.get('TOMORROW_API_KEY')
        S3BucketName = os.environ.get('S3BucketName')
        S3FileName = os.environ.get('S3FileName')
        LATITUDE = os.environ.get('LATITUDE')
        LONGITUDE = os.environ.get('LONGITUDE')

        # Validate all required environment variables
        required_vars = {
            'TOMORROW_API_KEY': TOMORROW_API_KEY,
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

        # Fetch daily forecast from tomorrow.io
        # The /weather/forecast endpoint returns hourly and daily timelines in one call.
        # We request metric units; daily values include temperatureMax, temperatureMin,
        # and weatherCodeMax (the dominant weather code for the day).
        params = urlencode({
            'location': f'{latitude},{longitude}',
            'units': 'metric',
            'apikey': TOMORROW_API_KEY,
        })
        weather_url = f'https://api.tomorrow.io/v4/weather/forecast?{params}'
        request = Request(weather_url, headers={'User-Agent': 'AWS Lambda Weather Function'})

        try:
            with urlopen(request, timeout=10) as response:
                weather_json = json.loads(response.read())
        except Exception as e:
            print(f"Error fetching weather data: {str(e)}")
            raise

        # Parse dates
        today = datetime.datetime.now(pytz.timezone("America/Los_Angeles"))
        print('Current time:', today.strftime("%Y-%m-%d %H:%M %Z"))

        # Determine if report for today or tomorrow
        cutoffTime = datetime.datetime.strptime('16:59', '%H:%M')
        lookupDay = 1 if today.time() >= cutoffTime.time() else 0
        day_one = today + datetime.timedelta(days=lookupDay)

        days_of_week = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday']

        # Extract daily forecast data
        # Response structure: weather_json['timelines']['daily'] is a list of daily intervals.
        # Each interval has 'time' (ISO 8601) and 'values' containing temperatureMax,
        # temperatureMin, and weatherCodeMax.
        daily_intervals = weather_json.get('timelines', {}).get('daily', [])
        if not daily_intervals:
            raise ValueError("No daily forecast data returned from tomorrow.io API")

        # Build a dict keyed by date for easy lookup
        daily_by_date = {}
        for interval in daily_intervals:
            # 'time' is an ISO 8601 string, e.g. "2024-01-15T06:00:00Z"
            dt_utc = datetime.datetime.fromisoformat(interval['time'].replace('Z', '+00:00'))
            dt_local = dt_utc.astimezone(pytz.timezone("America/Los_Angeles"))
            date_key = dt_local.date()
            daily_by_date[date_key] = interval['values']

        # Collect data for 4 days starting from day_one
        highs = []
        lows = []
        icons = []

        base_date = day_one.date()
        for i in range(4):
            target_date = base_date + datetime.timedelta(days=i)
            values = daily_by_date.get(target_date)
            if values:
                high = int(round(values.get('temperatureMax', 0)))
                low = int(round(values.get('temperatureMin', 0)))
                # weatherCodeMax represents the dominant (most severe) weather code for the day
                code = values.get('weatherCodeMax', 1000)
                icon = weather_code_to_icon(code)
                highs.append(high)
                lows.append(low)
                icons.append(icon)
            else:
                highs.append(None)
                lows.append(None)
                icons.append("skc")

        # Logging
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
            'UPDATE': f"Tmrw.io:{today.strftime('%H:%M')}",
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
