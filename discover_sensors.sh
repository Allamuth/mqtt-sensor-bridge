#!/bin/bash

#######################################
# discover_sensors.sh - Discover SMART attributes of all drives in the system
# and publish discovery messages to MQTT for Home Assistant integration.
#
# Usage: discover_sensors.sh [OPTIONS]
#
# Options:
#   -b, --broker HOST     MQTT broker hostname (default: localhost)
#   -p, --port PORT       MQTT broker port (default: 1883)
#   -u, --user USERNAME   MQTT username
#   -P, --password PASS   MQTT password
#   -t, --topic TOPIC     MQTT discovery base topic
#   -c, --cache-dir DIR   Cache directory (default: /var/cache/discover_sensors)
#   -h, --help            Show this help message
#
#######################################

set -euo pipefail

# Default configuration
# Default hostname
HOST_NAME="$(hostname | tr '-' '_')"
readonly HOST_NAME
# MQTT broker defaults
MQTT_BROKER="localhost"
MQTT_PORT="1883"
MQTT_USER=""
MQTT_PASSWORD=""
MQTT_DISCOVERY_BASE_TOPIC="homeassistant/sensor/host_${HOST_NAME}"
# default cache directory
CACHE_DIR="/var/cache/discover_sensors"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    -b|--broker)
      MQTT_BROKER="$2"
      shift 2
      ;;
    -p|--port)
      MQTT_PORT="$2"
      shift 2
      ;;
    -u|--user)
      MQTT_USER="$2"
      shift 2
      ;;
    -P|--password)
      MQTT_PASSWORD="$2"
      shift 2
      ;;
    -t|--topic)
      MQTT_DISCOVERY_BASE_TOPIC="$2"
      shift 2
      ;;
    -c|--cache-dir)
      CACHE_DIR="$2"
      shift 2
      ;;
    -h|--help)
      grep '^# ' "$0" | sed -e 's/^# //' -e 's/^#//'
      exit 0
      ;;
    *)
      echo "Error: Unknown option ${1}" >&2
      echo "Use -h or --help for usage information" >&2
      exit 1
      ;;
  esac
done

# Readonly configuration (can be overridden by CLI args above)
readonly MQTT_BROKER MQTT_PORT MQTT_USER MQTT_PASSWORD MQTT_DISCOVERY_BASE_TOPIC CACHE_DIR

# SMART attributes to check for
readonly -A COMMON_ATTRS=(
  [1]="Raw_Read_Error_Rate"
  [4]="Start_Stop_Count"
  [5]="Reallocated_Sector_Ct"
  [9]="Power_On_Hours"
  [12]="Power_Cycle_Count"
  [194]="Temperature_Celsius"
  [197]="Current_Pending_Sector"
  [198]="Offline_Uncorrectable"
)

readonly -A SSD_ATTRS=(
  [177]="Wear_Leveling_Count"
  [179]="Used_Rsvd_Blk_Cnt_Tot"
  [181]="Program_Fail_Cnt_Total"
  [182]="Erase_Fail_Count_Total"
  [183]="Runtime_Bad_Block"
  [184]="End-to-End_Error"
  [187]="Reported_Uncorrect"
  [232]="Available_Reservd_Space"
  [233]="Media_Wearout_Indicator"
  [234]="Total_LBAs_Written"
  [235]="Total_LBAs_Read"
  [241]="Total_LBAs_Written_Exp"
  [242]="Total_LBAs_Read_Exp"
)

readonly -A HDD_ATTRS=(
  [2]="Throughput_Performance"
  [3]="Spin_Up_Time"
  [6]="Read_Channel_Margin"
  [7]="Seek_Error_Rate"
  [8]="Seek_Time_Performance"
  [10]="Spin_Retry_Count"
  [11]="Calibration_Retry_Count"
  [13]="Soft_Read_Error_Rate"
  [190]="Airflow_Temperature_Cel"
  [191]="GW_Power_Cycle_Count"
  [192]="Power-off_Retract_Count"
  [193]="Load_Cycle_Count"
  [195]="Hardware_ECC_Recovered"
  [199]="UDMA_CRC_Error_Count"
  [200]="Multi_Zone_Error_Rate"
  [240]="Head_Flying_Hours"
  [241]="Total_LBAs_Written"
  [242]="Total_LBAs_Read"
)

readonly -A ATTRS_CLASS_MAP=(
  [1]=""
  [2]=""
  [3]="duration"
  [4]=""
  [5]=""
  [6]=""
  [7]=""
  [8]=""
  [9]="duration"
  [10]=""
  [11]=""
  [12]=""
  [13]=""
  [177]=""
  [179]=""
  [181]=""
  [182]=""
  [183]=""
  [184]=""
  [187]=""
  [190]="temperature"
  [191]=""
  [192]=""
  [193]=""
  [194]="temperature"
  [195]=""
  [197]=""
  [198]=""
  [199]=""
  [200]=""
  [232]="data_size"
  [233]="data_size"
  [234]=""
  [235]=""
  [240]="duration"
  [241]=""
  [242]=""
)

readonly -A CLASS_UOM_MAP=(
  ["temperature"]="°C"
  ["duration"]="h"
  ["data_size"]="B"
)

readonly CACHE_TYPES=("drives" "sensors")

# auto-discover sensors, restricted to drives, CPU, GPU, others? and store to config
# script is run on every startup of server, run auto-discovery and if config is already there check for new or missing sensors
# autogenerate discovery message for ansible mqtt
# resend discovery message on each restart not only when sensor changed


#######################################
# Initialize caches needed for this script using script variables.
# Globals:
#   CACHE_DIR
#   CACHE_TYPES
# Arguments:
#   None
# Outputs:
#   None
# Returns:
#   None
# Creates:
#   CACHED_DRIVES - Array of cached drive records
#   CACHED_SENSORS - Array of cached sensor records
#   DRIVES_CACHE_FILE - Path to drives cache file
#   SENSORS_CACHE_FILE - Path to sensors cache file
#######################################
init_caches() {
  # Create dir for cache files
  mkdir -p "$CACHE_DIR"

  # Load available cache files if exist, if not create them.
  for type in "${CACHE_TYPES[@]}"; do
    # cache_file contains full path of cache file
    local cache_file="$CACHE_DIR/${type}.cache"

    # create cache file if it doesn't exist
    if [[ ! -f "$cache_file" ]]; then
      touch "$cache_file"
    fi

    # Create array variable named CACHED_<TYPE> (e.g., CACHED_DRIVES)
    local array_var
    array_var="CACHED_$(tr '[:lower:]' '[:upper:]' <<< "$type")"
    mapfile -t "$array_var" < "$cache_file" || true

    # Create <TYPE>_CACHE_FILE variable (e.g., DRIVE_CACHE_FILE)
    local cache_path
    cache_path="$(tr '[:lower:]' '[:upper:]' <<< "$type")_CACHE_FILE"
    declare -g "$cache_path"="$cache_file"
  done
}

#######################################
# Check if required commands are available in the environment.
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   Writes error messages to STDERR if commands are missing.
# Returns:
#   1 if mosquitto_pub, smartctl, or jq is not found.
#   0 if all required commands are available.
#######################################
check_environment() {
  local environment_error=false

  # Check if mosquitto_pub is installed.
  if ! command -v mosquitto_pub &> /dev/null; then
    echo "Error: mosquitto_pub not found. Install mosquitto-clients." >&2
    environment_error=true
  fi

  # Check if smartctl is insalled.
  if ! command -v smartctl &> /dev/null; then
    echo "Error: smartctl not found. Install smartmontools." >&2
    environment_error=true
  fi

  # Check if jq is installed.
  if ! command -v jq &> /dev/null; then
    echo "Error: jq not found. Install jq." >&2
    environment_error=true
  fi

  if [[ "$environment_error" = true ]]; then
    exit 1
  fi
}

#######################################
# Check if a MQTT Broker is running and reachable.
# Globals:
#   MQTT_BROKER
#   MQTT_PORT
# Arguments:
#   None
# Outputs:
#   Writes error message to STDERR if broker is unavailable.
# Returns:
#   Exits with status 1 if broker is not available.
#   Returns 0 if broker is reachable.
#######################################
check_MQTT_broker() {
  if ! nc -z "$MQTT_BROKER" "$MQTT_PORT" 2>/dev/null; then
    echo "Error: MQTT broker not available at ${MQTT_BROKER}:{$MQTT_PORT}" >&2
    exit 1
  fi
}

#######################################
# Publish a sensor value to MQTT broker.
# Globals:
#   MQTT_BROKER
#   MQTT_PORT
#   MQTT_USER
#   MQTT_PASSWORD
#   MQTT_DISCOVERY_BASE_TOPIC
# Arguments:
#   $1 - topic_suffix: The suffix to append to the base MQTT topic.
#   $2 - value: The value to publish.
#   $3 - retained: Boolean flag (true/1/false/0) for retained message.
# Outputs:
#   Publishes the value to the MQTT broker.
# Returns:
#   None
#######################################
publish_mqtt() {
  local topic_suffix="$1"
  local value="$2"
  local retained="$3"
  local full_topic="${MQTT_DISCOVERY_BASE_TOPIC}${topic_suffix}"

  # set retained flag if retained_flag is true
  local retained_flag=""
  if [[ "$retained" == "true" || "$retained" == "1" ]]; then
    retained_flag="-r"
  fi

  if [[ -n "$MQTT_USER" ]]; then
    mosquitto_pub -h "$MQTT_BROKER" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASSWORD" -t "$full_topic" -m "$value" -q 1 "$retained_flag"
  else
    mosquitto_pub -h "$MQTT_BROKER" -p "$MQTT_PORT" -t "$full_topic" -m "$value" -q 1 "$retained_flag"
  fi
}

#######################################
# Publish a message indicating a sensor is available.
# Globals:
#   None (uses publish_mqtt which uses MQTT globals)
# Arguments:
#   $1 - topic_suffix: The suffix to append to the base MQTT topic.
# Outputs:
#   Publishes "online" to the ../available topic with retained=false.
# Returns:
#   None
#######################################
publish_sensor_available() {
  local topic_suffix="$1"
  publish_mqtt "$topic_suffix" "online" "false"
}

#######################################
# Publish a message indicating a sensor is unavailable.
# Globals:
#   None (uses publish_mqtt which uses MQTT globals)
# Arguments:
#   $1 - topic_suffix: The suffix to append to the base MQTT topic.
# Outputs:
#   Publishes "offline" to the ../available topic with retained=true.
# Returns:
#   None
#######################################
publish_sensor_unavailable() {
  local topic_suffix="$1"
  publish_mqtt "$topic_suffix" "offline" "true"
}

#######################################
# Publish a discovery message to MQTT for Home Assistant auto-discovery.
# Globals:
#   None (uses publish_mqtt which uses MQTT globals)
# Arguments:
#   $1 - topic_suffix: The config topic suffix.
#   $2 - message: The JSON discovery message.
# Outputs:
#   Publishes the discovery message as retained to MQTT.
# Returns:
#   None
#######################################
publish_discovery() {
  local topic_suffix="$1"
  local message="$2"
  publish_mqtt "$topic_suffix" "$message" "true"
}

#######################################
# Handle all sensors of drives, including discovery and announcements.
# This is the main function that orchestrates drive discovery,
# SMART attribute detection, change detection, and MQTT publishing.
# Globals:
#   HOST_NAME
#   MQTT_DISCOVERY_BASE_TOPIC
#   CACHE_DIR
#   COMMON_ATTRS
#   SSD_ATTRS
#   HDD_ATTRS
#   ATTRS_CLASS_MAP
#   CLASS_UOM_MAP
#   DRIVES_CACHE_FILE
#   CURRENT_DRIVES
#   CACHED_DRIVES
#   MISSING_DRIVES_RECORDS
#   MISSING_ATTRS_BY_DRIVE
# Arguments:
#   None
# Outputs:
#   Writes status messages to STDERR.
#   Publishes discovery and state messages to MQTT.
# Returns:
#   1 if drive discovery fails.
#   0 on success.
#######################################
handle_drives() {

  #######################################
  # Discover currently installed drives in the system.
  # Globals:
  #   None
  # Arguments:
  #   None
  # Outputs:
  #   Writes detection status to STDERR.
  # Returns:
  #   1 if no drives were found.
  #   0 on success.
  # Creates:
  #   CURRENT_DRIVES - Array containing all detected drive paths.
  #######################################
  discover_drives() {
    mapfile -t CURRENT_DRIVES < <(
      find /dev -maxdepth 1 \
        \( -name 'sd[a-z]' -o -name 'nvme[0-9]n[0-9]' \
        -o -name 'hd[a-z]' -o -name 'vd[a-z]' \) \
        2>/dev/null | sed 's|/dev/||' | sort)
    # Check if any drives were found
    if [[ ${#CURRENT_DRIVES[@]} -eq 0 ]]; then
      echo "No drives found." >&2
      return 1
    fi
    echo "Detected drives: ${CURRENT_DRIVES[*]}" >&2
  }

  #######################################
  # Detect if each drive is HDD, SSD, or NVME and extract metadata.
  # Globals:
  #   CURRENT_DRIVES
  # Arguments:
  #   None
  # Outputs:
  #   Writes error messages to STDERR if drive info cannot be retrieved.
  # Returns:
  #   None
  # Modifies:
  #   CURRENT_DRIVES - Enriches each entry with model, serial, capacity, type.
  #######################################
  detect_drive_types() {
    local new_drives=()

    for drive in "${CURRENT_DRIVES[@]}"; do
      local drive_type smartctl_output model serial capacity 
      case "$drive" in
        nvme*)
          drive_type="nvme"
          ;;
        sd*|hd*|vd*)
          smartctl_output=$(smartctl -i "/dev/${drive}" 2>/dev/null)

          # check if smartctl -i reports if not error
          if [[ -z "$smartctl_output" ]]; then
            echo "ERROR: Could not get info for ${drive}" >&2
            continue
          fi

          model=$(echo "${smartctl_output}" | awk -F: '
            /^[[:space:]]*Device Model:/ {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
            print $2
          }')
          serial=$(echo "${smartctl_output}" | awk -F: '
            /^[[:space:]]*Serial Number:/ {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
            print $2
          }')
          capacity=$(echo "${smartctl_output}" | awk -F'
            [][]' '/User Capacity:/ {print $2}')

          if echo "${smartctl_output}" | grep -qiE \
            "Solid State|SSD|NAND|Rotation Rate.* 1"; then
            drive_type="ssd"
          elif echo "${smartctl_output}" | grep -qiE \
            "Rotation Rate.*[0-9]+ rpm"; then
            drive_type="hdd"
          else
            drive_type="unknown"
          fi
          ;;
        *)
          echo "ERROR: Drive detected which is not NVME, HDD, or SSD!" >&2
          ;;
      esac
      # Build pipe-delimited record and store in temporary array
      new_drives+=("${drive}|${model}|${serial}|${capacity}|${drive_type}")
    done
    # Replace global CURRENT_DRIVES with enriched data
    CURRENT_DRIVES=("${new_drives[@]}")
  }

  #######################################
  # Detect available SMART attributes for each drive.
  # Globals:
  #   CURRENT_DRIVES
  #   COMMON_ATTRS
  #   SSD_ATTRS
  #   HDD_ATTRS
  # Arguments:
  #   None
  # Outputs:
  #   Writes warning messages to STDERR if attributes cannot be read.
  # Returns:
  #   None
  # Modifies:
  #   CURRENT_DRIVES - Appends detected SMART attribute IDs to each drive entry.
  #######################################
  detect_smart_attributes() {
    local updated_drives
    for drive in "${CURRENT_DRIVES[@]}"; do
      local drive_path="/dev/${drive%%|*}"
      local drive_type="${drive##*|}"
      local -a detected_attributes=()
      local detected_attributes_csv=""
      local attribute_output
      attribute_output=$(smartctl -A "$drive_path" 2>/dev/null)
      if [[ -z "$attribute_output" ]]; then
        echo "WARNING: Could not get SMART attributes for ${drive_path}" >&2
        continue
      fi

      while IFS= read -r line; do
        [[ "$line" =~ ^ID#|^#|^[[:space:]]*$ ]] && continue
        local attr_id
        attr_id=$(echo "${line}" | awk '{print $1}')

        if [[ "$attr_id" =~ ^[0-9]+$ ]]; then
          case "$drive_type" in
            "ssd"|"nvme")
              if [[ -v "${COMMON_ATTRS[$attr_id]}" \
                || -v "${SSD_ATTRS[$attr_id]}" ]]; then
                detected_attributes+=("$attr_id")
              fi
              ;;
            "hdd")
              if [[ -v "${COMMON_ATTRS[$attr_id]}" \
                || -v "${HDD_ATTRS[$attr_id]}" ]]; then
                detected_attributes+=("$attr_id")
              fi
              ;;
            *)
              echo "WARNING: Unknown drive type '${drive_type}' for ${drive_path}" >&2
              ;;
          esac
        fi
      done <<< "$attribute_output"

      if [[ ${#detected_attributes[@]} -gt 0 ]]; then
        readarray -t detected_attributes < <(
        printf '%s\n' "${detected_attributes[@]}" | sort -n -u)

        local has_194=false
        for attr in "${detected_attributes[@]}"; do
          [[ "$attr" == "194" ]] && has_194=true && break
        done

        # remove attribute 190 if 194 is present
        if [[ "$has_194" == true ]]; then
          local temp_attrs=()
          for attr in "${detected_attributes[@]}"; do
            [[ "$attr" != "190" ]] && temp_attrs+=("$attr")
          done
          detected_attributes=("${temp_attrs[@]}")
          unset temp_attrs
        fi
      fi

      # Convert detected_attributes to comma separated list string
      detected_attributes_csv="${detected_attributes[*]}"
      detected_attributes_csv="${detected_attributes_csv// /,}"

      # Append attributes as final pipe-delimited field
      updated_drives+=("${drive}|${detected_attributes_csv}")
    done

    # Replace global array
    CURRENT_DRIVES=("${updated_drives[@]}")
  }

  #######################################
  # Detect which drives are new, missing, or have changed attributes.
  # Globals:
  #   CURRENT_DRIVES
  #   CACHED_DRIVES
  # Arguments:
  #   None
  # Outputs:
  #   Writes status messages to STDERR.
  # Returns:
  #   None
  # Creates:
  #   MISSING_DRIVES_RECORDS - Array of missing drive records.
  #   MISSING_ATTRS_BY_DRIVE - Associative array mapping drive paths to missing attribute IDs.
  #######################################
  detect_drive_changes() {
    #######################################
    # Extract the drive path from a pipe-delimited drive record.
    # Arguments:
    #   $1 - drive_record: Pipe-delimited string containing drive data.
    # Returns:
    #   The drive path (first field before the first | character).
    #######################################
    get_drive_path() {
      echo "${1%%|*}"
    }

    # Create new, missing and changed drives variables.
    local new_drives=() missing_drives=() changed_drives=()

    # Build associative arrays: drive_path -> full_record
    declare -A current_drives_map cached_drives_map

    # for each drive in CURRENT_DRIVES, map path to rest of content
    for drive in "${CURRENT_DRIVES[@]}"; do
      current_drives_map["$(get_drive_path "$drive")"]="$drive"
    done
    # for each drive in CACHED_DRIVES (file) map path to rest of content
    for drive in "${CACHED_DRIVES[@]}"; do
      cached_drives_map["$(get_drive_path "$drive")"]="$drive"
    done

    # Find new drives (in current, but not in cached)
    for drive in "${!current_drives_map[@]}"; do
      # Search for uncached drives and write to new_drives
      [[ -z "${cached_drives_map[$drive]}" ]] && new_drives+=("$drive")
    done

    if [[ ${#new_drives[*]} -gt 0 ]]; then
      echo "New drives: ${new_drives[*]}" >&2
    else
      echo "No new drives detected!" >&2
    fi

    # Find missing drives (in cached, not in current)
    for drive in "${!cached_drives_map[@]}"; do
      [[ -z "${current_drives_map[$drive]}" ]] && missing_drives+=("$drive")
    done

    if [[ ${#missing_drives[@]} -gt 0 ]]; then
      echo "ERROR: Missing drives: ${missing_drives[*]}" >&2
      declare -g MISSING_DRIVES_RECORDS=()
      for drive in "${missing_drives[@]}"; do
        MISSING_DRIVES_RECORDS+=("${cached_drives_map[$drive]}")
      done
    else
      echo "No missing drives, hurrey!" >&2
    fi

    # Find changed drives (in both, but different records)
    for drive in "${!cached_drives_map[@]}"; do
      # Drive already exists in cached_drives_map and records differ
      [[ -n "${cached_drives_map[$drive]}" && "${current_drives_map[$drive]}" \
        != "${cached_drives_map[$drive]}" ]] && changed_drives+=("$drive")
    done

    # Detect missing attributes for existing drives
    # Global: drive_path -> "attr_id1 attr_id2..."
    declare -g -A MISSING_ATTRS_BY_DRIVE=()
    for drive in "${!current_drives_map[@]}"; do
      if [[ -n "${cached_drives_map[$drive]}" ]]; then

        # extract needed fields from maps
        IFS='|' read -r _ _ _ _ _ current_attributes <<< \
          "${current_drives_map[$drive]}"
        IFS='|' read -r _ _ _ _ _ cached_attributes <<< \
          "${cached_drives_map[$drive]}"

        # Find attributes in cached but not current
        local missing_attrs=()
        for cached_attr_id in ${cached_attributes//,/ }; do
          local found=false
          for current_attr_id in ${current_attributes//,/ }; do
            [[ "$cached_attr_id" == "$current_attr_id" ]] \
              && found=true && break
          done
          [[ "$found" == false ]] && missing_attrs+=("$cached_attr_id")
        done

        # Store missing attributes for this drive
        if [[ ${#missing_attrs[@]} -gt 0 ]]; then
          MISSING_ATTRS_BY_DRIVE["$drive"]="${missing_attrs[*]}"
          echo "WARNING: Missing attributes for ${drive}: ${missing_attrs[*]}" \
            >&2
        fi
      fi
    done

    if [[ ${#changed_drives[@]} -eq 0 ]]; then
      echo "No drive attribute changes detected!" >&2
    fi
  }

  #######################################
  # Send discovery messages for each drive's available sensors.
  # Creates MQTT discovery topics for Home Assistant to auto-create sensor entities.
  # Globals:
  #   HOST_NAME
  #   MQTT_DISCOVERY_BASE_TOPIC
  #   CURRENT_DRIVES
  #   COMMON_ATTRS
  #   SSD_ATTRS
  #   HDD_ATTRS
  #   ATTRS_CLASS_MAP
  #   CLASS_UOM_MAP
  # Arguments:
  #   None
  # Outputs:
  #   Writes processing status to STDERR.
  #   Publishes discovery messages to MQTT.
  # Returns:
  #   None
  #######################################
  publish_drive_discovery() {
    for drive in "${CURRENT_DRIVES[@]}"; do
      IFS='|' read -r drive_path model serial_number capacity drive_type \
        attributes <<< "$drive"
      echo "Processing: ${drive_path}, Model: ${model}, Serial: ${serial_number}"

      for attr_id in ${attributes//,/ }; do
        attr_name="${COMMON_ATTRS[$attr_id]}"
        if [[ -z "$attr_name" ]]; then
          case "$drive_type" in
            "ssd"|"nvme")
              attr_name="${SSD_ATTRS[$attr_id]}"
              ;;
            "hdd")
              attr_name="${HDD_ATTRS[$attr_id]}"
              ;;
          esac
        fi
        [[ -z "$attr_name" ]] && continue

        # Create different topics needed for state, availability and config
        local state_topic="${MQTT_DISCOVERY_BASE_TOPIC}/${drive_path}_${attr_id}/state"
        local avail_topic="${MQTT_DISCOVERY_BASE_TOPIC}/${drive_path}_${attr_id}/available"
        local config_topic="${MQTT_DISCOVERY_BASE_TOPIC}/${drive_path}_${attr_id}/config"

        # Look up device class and unit from mappings
        local device_class="${ATTRS_CLASS_MAP[$attr_id]:-}"
        local unit=""
        [[ -n "$device_class" ]] && unit="${CLASS_UOM_MAP[$device_class]:-}"

        message=$(jq -n \
          --arg name "${drive_path} ${attr_name//_/ }" \
          --arg uid "${HOST_NAME}_${drive_path}_${attr_id}" \
          --arg st "${state_topic}" \
          --arg av "${avail_topic}" \
          --arg dc "$device_class" \
          --arg uom "$unit" \
          --arg model "$model" \
          --arg serial_number "$serial_number" \
          --arg drive_path "$drive_path" \
          '{
            name: $name,
            unique_id: $uid,
            state_topic: $st,
            value_template: "{{ value_json.value }}",
            unit_of_measurement: $uom,
            device_class: $dc,
            state_class: "measurement",
            availability: [{topic: $av}],
            device: {
              identifiers: [$serial_number],
              name: ("Drive " + $drive_path),
              model: $model,
              serial: $serial_number
            }
          }')
        publish_discovery "$config_topic" "$message"
      done
    done
  }

  #######################################
  # Publish sensors which are not available anymore by setting their
  # availability topic as offline.
  # Globals:
  #   MQTT_DISCOVERY_BASE_TOPIC
  #   MISSING_DRIVES_RECORDS
  #   MISSING_ATTRS_BY_DRIVE
  # Arguments:
  #   None
  # Outputs:
  #   Writes status messages to STDERR.
  #   Publishes offline messages to MQTT availability topics.
  # Returns:
  #   None
  #######################################
  publish_unavailable_sensors() {
    for drive in "${MISSING_DRIVES_RECORDS[@]}"; do
      IFS='|' read -r drive_path _ _ _ _ attributes <<< "$drive"

      for attr_id in ${attributes//,/ }; do
        local avail_topic="${MQTT_DISCOVERY_BASE_TOPIC}/\
          ${drive_path}_${attr_id}/available"
        publish_sensor_unavailable "$avail_topic"
        echo "${avail_topic} not available"
      done
    done

    # Handle missing attributes on existing drives
    for drive_path in "${!MISSING_ATTRS_BY_DRIVE[@]}"; do
      for attr_id in ${MISSING_ATTRS_BY_DRIVE[$drive_path]}; do
        local avail_topic="${MQTT_DISCOVERY_BASE_TOPIC}/\
          ${drive_path}_${attr_id}/available"
        publish_sensor_unavailable "$avail_topic"
        echo "${avail_topic} not available"
      done
    done
  }


  if ! discover_drives; then
    echo "ERROR: Drive discovery failed, skipping to next sensor type." >&2
    return 1
  fi
  detect_drive_types
  detect_smart_attributes
  detect_drive_changes
  echo "${CURRENT_DRIVES[@]}"
  publish_drive_discovery
  publish_unavailable_sensors
  printf '%s\n' "${CURRENT_DRIVES[@]}" > "$DRIVES_CACHE_FILE"
}


#######################################
# Main script execution.
# Orchestrates environment checks, broker verification,
# cache initialization, and drive handling.
# Globals:
#   All global variables defined above
# Arguments:
#   None (uses command-line arguments parsed earlier)
# Outputs:
#   Writes status/error messages to STDERR.
# Returns:
#   Exit status from the last command (typically 0 on success, 1 on failure).
#######################################

check_environment
check_MQTT_broker
init_caches
handle_drives
