# KindleBattery Lambda Function

`index.mjs` receives battery telemetry from the Kindle each time it wakes up and forwards it to two destinations: Home Assistant and AWS CloudWatch.

## What it does

1. **Parses the incoming telemetry** — the Kindle sends a JSON POST body via API Gateway containing five fields from `gasgauge-info`:

   | Field | Example | Unit |
   |---|---|---|
   | `battery` | `"95%"` | Percent |
   | `voltage` | `"3800 mV"` | Millivolts |
   | `load` | `"-200 mA"` | Milliamps (negative = discharging) |
   | `temp` | `"75 Fahrenheit"` | Degrees Fahrenheit |
   | `capacity` | `"1500 mAh"` | Milliamp-hours remaining |

2. **Strips the unit strings** and converts values to numbers.

3. **Sends the battery state to Home Assistant** via a POST to the configured entity URL (`HomeAssistantURL` environment variable), using a Bearer token (`HomeAssistantBearerToken` environment variable).

4. **Publishes all five metrics to CloudWatch** under the `Kindle Telemetry` namespace, dimensioned by `Kindle Name = Kindle 4`.

## Environment variables

| Variable | Description |
|---|---|
| `HomeAssistantURL` | Full URL of the Home Assistant sensor entity, e.g. `https://your-ha-instance/api/states/sensor.kindle_battery` |
| `HomeAssistantBearerToken` | Long-lived access token from Home Assistant |

## Runtime

Node.js 24.x. No external dependencies — uses the AWS SDK v3 (`@aws-sdk/client-cloudwatch`) provided by the Lambda runtime.

## Testing

Use `test-event.json` as the test event in the Lambda console. It simulates an API Gateway v2 HTTP POST with a base64-encoded JSON body.

The `body` field decodes to:
```json
{"battery":"95%","voltage":"3800 mV","load":"-200 mA","temp":"75 Fahrenheit","capacity":"1500 mAh"}
```

Expected log output:
```
Battery: 95%  Voltage: 3800mV  Load: -200mA  Temp: 75°F  Capacity: 1500mAh
Home Assistant updated: 200
CloudWatch telemetry delivered
```
