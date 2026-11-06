#!/bin/bash

#######################################
# discover_sensors.sh - Discover SMART attributes of all drives in system and
# publish a discovery message to MQTT for usage with Home Assistant.
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
#######################################

# Default configuration
# MQTT broker defaults
readonly MQTT_BROKER="localhost"
readonly MQTT_PORT="1883"
readonly MQTT_USER=""
readonly MQTT_PASSWORD=""
MQTT_DISCOVERY_BASE_TOPIC="homeassistant/sensor/host_$(hostname | tr - _)"
readonly MQTT_DISCOVERY_BASE_TOPIC
# default cache directory
readonly CACHE_DIR="/var/cache/discover_sensors"
# default hostname
HOSTNAME=$(hostname)

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
            echo "Error: Unknown option $1" >&2
            echo "Use -h or --help for usage information" >&2
            exit 1
            ;;
    esac
done

# Readonly configuration (can be overridden by CLI args above)
readonly MQTT_BROKER MQTT_PORT MQTT_USER MQTT_PASSWORD MQTT_DISCOVERY_BASE_TOPIC CACHE_DIR HOSTNAME

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
# Arguments:
#   None
# Creates :
#   CACHED_<TYPE> variable for each cached sensor type.
#   <TYPE>_CACHE_FILE variable for each sensor types path to cache file.
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
# Arguments:
#   None
# Returns:
#   1 if mosquitto_pub,  smartctl or jq is not found.
# Outputs:
#   Writes error messages to STDERR if commands are missing.
#######################################
check_environment() {
    local environment_error=false

    # Check if mosquitto_pub is installed.
    if ! command -v mosquitto_pub &> /dev/null; then
        echo "Error: mosquitto_pub not found. Please install mosquitto-clients." >&2
        environment_error=true
    fi

    # Check if smartctl is insalled.
    if ! command -v smartctl &> /dev/null; then
        echo "Error: smartctl not found. Please install smartmontools." >&2
        environment_error=true
    fi

    # Check if jq is installed.
    if ! command -v jq &> /dev/null; then
        echo "Error: jq not found. Please install jq." >&2
        environment_error=true
    fi

    if [[ "$environment_error" = true ]]; then
        exit 1
    fi
}

#######################################
# Publish a sensor value to MQTT broker.
# Arguments:
#   $1 - topic_suffix: The suffix to append to the base MQTT topic.
#   $2 - value: The value to publish.
#   $3 - retained: Boolean flag (true/1/false/0) for retained message.
# Outputs:
#   Publishes the value to the MQTT broker.
#######################################
publish_mqtt() {
    local topic_suffix=$1
    local value=$2
    local retained=$3
    local full_topic="${MQTT_DISCOVERY_BASE_TOPIC}${topic_suffix}"
    
    # set retained flag if retained_flag is true
    local retained_flag=""
    if [[ "$retained" == "true" || "$retained" == "1" ]]; then
        retained_flag="-r"
    fi

    if [[ -n "$MQTT_USER" ]]; then
        mosquitto_pub -h "$MQTT_BROKER" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASSWORD" -t "$full_topic" -m "$value" -q 1 $retained_flag
    else
        mosquitto_pub -h "$MQTT_BROKER" -p "$MQTT_PORT" -t "$full_topic" -m "$value" -q 1 $retained_flag
    fi
}

#######################################
# Publish a json formatted message per sensor/entity under the ../available
# topic with retained, this ensures that no cache handling is needed.
#######################################
publish_sensor_available() {
    local topic_suffix=$1
    publish_mqtt "$topic_suffix" "online" "false"
}

#######################################
# Publish a json formatted message per sensor/entity under the ../available
# topic with retained, this ensures that no cache handling is needed.
#######################################
publish_sensor_unavailable() {
    local topic_suffix=$1
    publish_mqtt "$topic_suffix" "offline" "true"
}

#######################################
# Publish a json formatted message which contains the name, unique_id,
# state_topic, value_template, unit_of_measurement, device_class, state_class
# and the device itself. (id, name, model, serial, manufacturer, etc.).
# Also publishes the entity/sensor as available in it's topic
#######################################
publish_discovery() {
    local topic_suffix=$1
    local message=$2
    publish_mqtt "$topic_suffix" "$message" "retained"
}

#######################################
# Handle all sensors of drives, including discovery and announcements.
#######################################
handle_drives() {

    #######################################
    # Discover currently installed drives.
    # Creates:
    #   CURRENT_DRIVES containing all drives in an array.
    # Returns:
    #   1 if no drives were found.
    #######################################
    discover_drives() {
        mapfile -t CURRENT_DRIVES < <(ls /dev/sd[a-z] /dev/nvme[0-9]n[0-9] /dev/hd[a-z] /dev/vd[a-z] 2>/dev/null | sed 's|/dev/||' || true)

        # Check if any drives were found
        if [[ ${#CURRENT_DRIVES[@]} -eq 0 ]]; then
            echo "No drives found." >&2
            return 1
        fi
        echo "Detected drives: ${CURRENT_DRIVES[*]}" >&2
    }

    #######################################
    # Detect if drive is of type HDD, SSD or NVME and write to cache.
    # Outputs:
    #   Writes error for each SSD/HDD to STDERR if attributes are not reported.
    #######################################
    detect_drive_types() {
        local new_drives=()
        for drive in "${CURRENT_DRIVES[@]}"; do
            local info_output
            case "$drive" in
                nvme*)
                    drive_type="nvme"
                    ;;
                sd*|hd*|vd*)
                    info_output=$(smartctl -i "/dev/$drive" 2>/dev/null)

                    # check if smartctl -i reports if not error
                    if [[ -z $info_output ]]; then
                        echo "ERROR: Could not get info for $drive" >&2
                        continue
                    fi

                    local model serial capacity drive_type
                    model=$(echo "$info_output" | awk -F: '/^[[:space:]]*Device Model:/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2}')
                    serial=$(echo "$info_output" | awk -F: '/^[[:space:]]*Serial Number:/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2}')
                    capacity=$(echo "$info_output" | awk -F'[][]' '/User Capacity:/ {print $2}')
                    

                    if echo "$info_output" | grep -qiE "Solid State|SSD|NAND|Rotation Rate.* 1"; then
                        drive_type="ssd"
                    elif echo "$info_output" | grep -qiE "Rotation Rate.*[0-9]+ rpm"; then
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
    # Detect available sensors for each drive.
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
            if [[ -z $attribute_output ]]; then
                echo "WARNING: Could not get SMART attributes for $drive_path" >&2
                continue
            fi

            while IFS= read -r line; do
                [[ "$line" =~ ^ID#|^#|^[[:space:]]*$ ]] && continue
                local attr_id
                attr_id=$(echo "$line" | awk '{print $1}')

                if [[ "$attr_id" =~ ^[0-9]+$ ]]; then
                    case "$drive_type" in
                        "ssd"|"nvme")
                            if [[ -n "${COMMON_ATTRS[$attr_id]}" || -n "${SSD_ATTRS[$attr_id]}" ]]; then
                                detected_attributes+=("$attr_id")
                            fi
                            ;;
                        "hdd")
                            if [[ -n "${COMMON_ATTRS[$attr_id]}" || -n "${HDD_ATTRS[$attr_id]}" ]]; then
                                detected_attributes+=("$attr_id")
                            fi
                            ;;
                        *)
                            echo "WARNING: Unknown drive type '$drive_type' for $drive_path" >&2
                        ;;
                    esac
                fi
            done <<< "$attribute_output"

            if [[ ${#detected_attributes[@]} -gt 0 ]]; then
                readarray -t detected_attributes < <(sort  -n -u <<<"${detected_attributes[*]}")

                # remove attribute 190 if 194 is present
                if [[ " ${detected_attributes[*]} " == *\ 194\ * ]]; then
                      detected_attributes=("${detected_attributes[@]/\ ,190/}")
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
    # Detect which drives are new or missing.
    # Outputs:
    #   Writes new discovered drives STDERR.
    #   Writes missing drives to STDERR.
    #######################################
    detect_drive_changes() {
        # Helper: extract drive path (first field before |)
        get_drive_path() {
            echo "${1%%|*}"
        }

        # Create new, missing and changed drives variables.
        local new_drives=() missing_drives=() changed_drives=()

        # Build associative arrays: drive_path -> full_record
        declare -A current_map cached_map

        # for each drive in CURRENT_DRIVES, map path to rest of content
        for record in "${CURRENT_DRIVES[@]}"; do
            current_map["$(get_drive_path "$record")"]="$record"
        done
        # for each drive in CACHED_DRIVES (file) map path to rest of content
        for record in "${CACHED_DRIVES[@]}"; do
            cached_map["$(get_drive_path "$record")"]="$record"
        done
 
        # Find new drives (in current, but not in cached)
        for path in "${!current_map[@]}"; do
            # Search for uncached drives and write to new_drives
            [[ -z "${cached_map[$path]}" ]] && new_drives+=("$path")
        done

        if [[ ${#new_drives[*]} -gt 0 ]]; then
            echo "New drives: ${new_drives[*]}" >&2
        else
            echo "No new drives detected!" >&2
        fi

        # Find missing drives (in cached, not in current)
        for path in "${!cached_map[@]}"; do
            [[ -z "${current_map[$path]}" ]] && missing_drives+=("$path")
        done

        if [[ ${#missing_drives[@]} -gt 0 ]]; then
            echo "ERROR: Missing drives: ${missing_drives[*]}" >&2
            declare -g MISSING_DRIVES_RECORDS=()
            for path in "${missing_drives[@]}"; do
                MISSING_DRIVES_RECORDS+=("${cached_map[$path]}")
            done
        else 
            echo "No missing drives, hurrey!" >&2
        fi
        
        # Find changed drives (in both, but different records)
        for path in "${!cached_map[@]}"; do
            # Drive already exists in cached_map and records differ
            [[ -n "${cached_map[$path]}" && "${current_map[$path]}" != "${cached_map[$path]}" ]] && changed_drives+=("$path")
        done

        # Detect missing attributes for existing drives
        declare -g -A MISSING_ATTRS_BY_DRIVE=()  # Global: drive_path -> "attr_id1 attr_id2..."
        for path in "${!current_map[@]}"; do
            if [[ -n "${cached_map[$path]}" ]]; then
                local current_attrs="${current_map[$path]}"
                local cached_attrs="${cached_map[$path]}"

                echo "cached map: ${cached_map[$path]}"
                echo "current attrs: ${current_map[$path]}"
                echo "cached_attrs: ${cached_map[$path]}"


                # Convert CSV to arrays
                IFS='|' read -r drive_path _ _ _ _ current_attr_list <<< "$current_attrs"
                IFS='|' read -r drive_path _ _ _ _ cached_attr_list <<< "$cached_attrs"

                # Find attributes in cached but not current
                local missing_attrs=()
                for cached_attr in "${cached_attr_list[@]}"; do
                    local found=false
                    echo "cached attr: $cached_attr"
                    for current_attr in "${current_attr_list[@]}"; do
                        [[ "$cached_attr" == "$current_attr" ]] && found=true && break
                    done
                    [[ "$found" == false ]] && missing_attrs+=("$cached_attr")
                done

                # Store missing attributes for this drive
                if [[ ${#missing_attrs[@]} -gt 0 ]]; then
                    MISSING_ATTRS_BY_DRIVE["$path"]="${missing_attrs[*]}"
                    echo "WARNING: Missing attributes for $path: ${missing_attrs[*]}" >&2
                fi
            fi
        done

        if [[ ${#changed_drives[@]} -eq 0 ]]; then
            echo "No drive attribute changes detected!" >&2
        fi
    }

    #######################################
    # Send the discovery message(s) for each drive's available sensors
    # and set it as online in its "../available" topic.
    #######################################
    publish_drive_discovery() {
        for drive in "${CURRENT_DRIVES[@]}"; do
            IFS='|' read -r drive_path model serial_number capacity drive_type attributes <<< "$drive"

            echo "Processing: $drive_path, Model: $model, Serial: $serial_number"
            
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

                local state_topic="${MQTT_DISCOVERY_BASE_TOPIC}/${drive_path}_${attr_id}/state"
                local avail_topic="${MQTT_DISCOVERY_BASE_TOPIC}/${drive_path}_${attr_id}/available"
                local config_topic="${MQTT_DISCOVERY_BASE_TOPIC}/${drive_path}_${attr_id}/config"

                # Look up device class and unit from mappings
                local device_class="${ATTRS_CLASS_MAP[$attr_id]:-}"
                local unit=""
                [[ -n "$device_class" ]] && unit="${CLASS_UOM_MAP[$device_class]:-}"

                message=$(jq -n \
                    --arg name "${drive_path} ${attr_name//_/ }" \
                    --arg uid "${HOSTNAME}_${drive_path}_${attr_id}" \
                    --arg st "${state_topic}" \
                    --arg av "${avail_topic}" \
                    --arg dc "$device_class" \
                    --arg uom "$unit" \
                    --arg model "$model" \
                    --arg serial_number "$serial_number" \
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
                        identifiers: [$uid],
                        name: ("Drive " + "'"${drive_path}"'"),
                        model: $model,
                        serial: $serial_number
                      }
                    }')
                
                #publish_discovery "$config_topic" "$message"
            done
        done
    }

    #######################################
    # Publish sensors which are not available anymore by setting their
    # availability topic as offline. This can lead to all sensors of a drive
    # being set to offline.
    #######################################
    publish_unavailable_sensors() {
        for drive in "${MISSING_DRIVES_RECORDS[@]}"; do
            IFS='|' read -r drive_path _ _ _ _ attributes <<< "$drive"
            
            for attr_id in ${attributes//,/ }; do
                local avail_topic="${MQTT_DISCOVERY_BASE_TOPIC}/${drive_path}_${attr_id}/available"
                #publish_sensor_unavailable "$avail_topic"
                echo "$avail_topic not available"
            done
        done

        # Handle missing attributes on existing drives
        for drive_path in "${!MISSING_ATTRS_BY_DRIVE[@]}"; do
            for attr_id in ${MISSING_ATTRS_BY_DRIVE[$drive_path]}; do
                local avail_topic="${MQTT_DISCOVERY_BASE_TOPIC}/${drive_path}_${attr_id}/available"
                #publish_sensor_unavailable "$avail_topic"
                echo "$avail_topic not available"
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
# Main script
#######################################

check_environment
init_caches
handle_drives
