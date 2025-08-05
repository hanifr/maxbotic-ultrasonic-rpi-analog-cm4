#!/bin/bash

# Simple Remote Control for Ultrasonic Sensor Relay
# Listens to MQTT control topic and triggers relay

set -euo pipefail

# Configuration
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly OVERRIDE_FLAG="/tmp/relay_manual_override"

# Load MQTT configuration
if [[ -f "${SCRIPT_DIR}/mqtt_service.sh" ]]; then
    source "${SCRIPT_DIR}/mqtt_service.sh"
else
    echo "ERROR: MQTT configuration file not found: ${SCRIPT_DIR}/mqtt_service.sh" >&2
    exit 1
fi

# Validate configuration
if ! validate_mqtt_config; then
    echo "ERROR: MQTT configuration validation failed" >&2
    exit 1
fi

# Logging function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [REMOTE] $1"
}

# Control relay function
control_relay() {
    local action="$1"
    local reason="${2:-remote_command}"
    
    log "Controlling relay: $action ($reason)"
    
    if [[ ! -e /dev/ttyAMA4 ]]; then
        log "ERROR: Relay device /dev/ttyAMA4 not found"
        return 1
    fi
    
    case "$action" in
        "on"|"ON"|"1")
            if mbpoll -m rtu -a 1 -b 9600 -P none -s 1 -t 0 -r 2 /dev/ttyAMA4 -- 1 2>/dev/null; then
                log "Relay turned ON ($reason)"
                return 0
            fi
            ;;
        "off"|"OFF"|"0")
            if mbpoll -m rtu -a 1 -b 9600 -P none -s 1 -t 0 -r 2 /dev/ttyAMA4 -- 0 2>/dev/null; then
                log "Relay turned OFF ($reason)"
                return 0
            fi
            ;;
    esac
    
    log "ERROR: Failed to control relay"
    return 1
}

# Process MQTT commands
process_command() {
    local command="$1"
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    
    log "Received command: $command"
    
    case "$command" in
        *"on"*|*"ON"*|*"1"*)
            echo "manual_on|$timestamp" > "$OVERRIDE_FLAG"
            control_relay "on" "mqtt_command"
            log "Manual override: Relay ON"
            ;;
        *"off"*|*"OFF"*|*"0"*)
            echo "manual_off|$timestamp" > "$OVERRIDE_FLAG"
            control_relay "off" "mqtt_command"
            log "Manual override: Relay OFF"
            ;;
        *"auto"*|*"AUTO"*)
            if [[ -f "$OVERRIDE_FLAG" ]]; then
                rm -f "$OVERRIDE_FLAG"
                log "Manual override DISABLED - returning to automatic control"
            else
                log "Already in automatic mode"
            fi
            ;;
        *"status"*|*"STATUS"*)
            if [[ -f "$OVERRIDE_FLAG" ]]; then
                local override_info=$(cat "$OVERRIDE_FLAG" 2>/dev/null || echo "unknown")
                log "Status: Manual override active - $override_info"
            else
                log "Status: Automatic mode (sensor-controlled)"
            fi
            ;;
        *)
            log "Unknown command: $command"
            ;;
    esac
}

# Cleanup function
cleanup() {
    log "Shutting down remote control..."
    if [[ -f "$OVERRIDE_FLAG" ]]; then
        rm -f "$OVERRIDE_FLAG"
        log "Removed manual override - returned to automatic mode"
    fi
    exit 0
}

trap cleanup SIGTERM SIGINT

# Main execution
log "Starting remote control listener..."
log "MQTT Broker: $MQTT_BROKER:$MQTT_PORT"
log "Control Topic: ${MQTT_TOPIC}/control"

# Test MQTT connection
if ! mosquitto_pub -h "$MQTT_BROKER" -p "$MQTT_PORT" -t "${MQTT_TOPIC}/test" -m "remote_test" -q "$MQTT_QOS" 2>/dev/null; then
    log "WARNING: MQTT connection test failed"
fi

log "Listening for commands..."

# Main listener loop with auto-reconnect
while true; do
    log "Starting MQTT subscription..."
    
    if mosquitto_sub -h "$MQTT_BROKER" \
                      -p "$MQTT_PORT" \
                      -t "${MQTT_TOPIC}/control" \
                      -q "$MQTT_QOS" \
                      -k 60 \
                      2>/dev/null | while read -r line; do
        if [[ -n "$line" ]]; then
            process_command "$line"
        fi
    done; then
        log "MQTT listener exited normally"
    else
        log "MQTT listener failed, retrying in 10 seconds..."
        sleep 10
    fi
done