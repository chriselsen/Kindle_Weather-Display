import { CloudWatch } from "@aws-sdk/client-cloudwatch";

export const handler = async (event) => {
    console.log("Event: " + JSON.stringify(event));

    // Resolve the payload — API Gateway v2 puts POST body in event.body,
    // optionally base64-encoded. Fall back to event itself for direct invocations.
    let payload = event;
    if (event.body) {
        const raw = event.isBase64Encoded
            ? Buffer.from(event.body, 'base64').toString('utf8')
            : event.body;
        try {
            payload = JSON.parse(raw);
        } catch {
            // body is not JSON (e.g. form-encoded) — fall back to queryStringParameters
            payload = event.queryStringParameters ?? event;
        }
    } else if (event.queryStringParameters) {
        payload = event.queryStringParameters;
    }

    // Extract fields with defaults
    const battery  = payload.battery  ?? '100';
    const voltage  = payload.voltage  ?? '0';
    const load     = payload.load     ?? '0';
    const temp     = payload.temp     ?? '0';
    const capacity = payload.capacity ?? '0';

    // Strip units — gasgauge-info returns strings like "95%", "3800 mV", "-200 mA", "25 Fahrenheit", "1500 mAh"
    const batt = parseFloat(battery.replace(/%/g, ''));
    const volt = parseFloat(voltage.replace(/ mV/g, ''));
    const amps = parseFloat(load.replace(/ mA/g, ''));
    const fahr = parseFloat(temp.replace(/ Fahrenheit/g, ''));
    const mah  = parseFloat(capacity.replace(/ mAh/g, ''));

    console.log(`Battery: ${batt}%  Voltage: ${volt}mV  Load: ${amps}mA  Temp: ${fahr}°F  Capacity: ${mah}mAh`);

    const timestamp = new Date();
    const kindleDimension = [{ Name: 'Kindle Name', Value: 'Kindle 4' }];

    // --- Send to Home Assistant ---
    const homeAssistantBearerToken = process.env.HomeAssistantBearerToken;
    const homeAssistantURL = process.env.HomeAssistantURL;

    try {
        const response = await fetch(homeAssistantURL, {
            method: 'POST',
            headers: {
                'Authorization': `Bearer ${homeAssistantBearerToken}`,
                'Content-Type': 'application/json',
            },
            body: JSON.stringify({
                state: batt,
                attributes: { unit_of_measurement: '%' },
            }),
        });

        if (!response.ok) {
            const body = await response.text();
            console.error(`Home Assistant request failed: ${response.status} ${body}`);
        } else {
            console.log(`Home Assistant updated: ${response.status}`);
        }
    } catch (err) {
        console.error('Home Assistant request error:', err);
    }

    // --- Send to CloudWatch ---
    const cloudwatch = new CloudWatch({ region: 'us-west-2' });

    const params = {
        Namespace: 'Kindle Telemetry',
        MetricData: [
            {
                MetricName: 'Battery',
                Dimensions: kindleDimension,
                Timestamp: timestamp,
                Unit: 'Percent',
                Value: batt,
            },
            {
                MetricName: 'Voltage',
                Dimensions: kindleDimension,
                Timestamp: timestamp,
                Unit: 'None',
                Value: volt,
            },
            {
                MetricName: 'mA',
                Dimensions: kindleDimension,
                Timestamp: timestamp,
                Unit: 'None',
                Value: amps,
            },
            {
                MetricName: 'Fahrenheit',
                Dimensions: kindleDimension,
                Timestamp: timestamp,
                Unit: 'None',
                Value: fahr,
            },
            {
                MetricName: 'mAh',
                Dimensions: kindleDimension,
                Timestamp: timestamp,
                Unit: 'None',
                Value: mah,
            },
        ],
    };

    try {
        await cloudwatch.putMetricData(params);
        console.log('CloudWatch telemetry delivered');
    } catch (err) {
        console.error('CloudWatch delivery failed:', err);
        throw err; // surface the error to Lambda so it shows as a failure
    }

    return { statusCode: 200, body: 'Telemetry delivered' };
};
