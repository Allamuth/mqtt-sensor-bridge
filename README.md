## Overview

This repository contains two scripts for monitoring disk health via MQTT:

- **`discover_sensors.sh`** - Discovers drives and SMART attributes, publishes Home Assistant MQTT discovery messages
- **`publish_sensor.sh`** - Publishes actual sensor values to MQTT

## Requirements

- `smartctl` (from smartmontools package)
- `mosquitto_pub` (from mosquitto-clients package)
- `jq` (for JSON processing)

## Usage

### Discover drives and publish discovery messages:
```bash
./discover_sensors.sh [OPTIONS]
```

### Publish sensor values:
```bash
./publish_sensor.sh [OPTIONS]
```

### Common Options
-b, --broker HOST       MQTT broker hostname (default: localhost)
-p, --port PORT         MQTT broker port (default: 1883)
-u, --user USERNAME     MQTT username
-P, --password PASS     MQTT password
-t, --topic TOPIC       MQTT discovery base topic
-c, --cache-dir DIR     Cache directory (default: /var/cache/discover_sensors)
-h, --help              Show help
Run with `-h` for full usage information.

## Integration

Use with systemd timers or cron for scheduled execution.

---

## AI Assistance Disclosure

This project was developed with the assistance of Mistral Vibe AI as part of an experiment to test generative AI for coding tasks.
