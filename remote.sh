# ===== remote.sh =====
#!/bin/bash

# Remote Control Listener for Ultrasonic Sensor System
# This runs as a separate service alongside the main ultrasonic service
# Usage: ./remote.sh

# Exit on error
set -euo pipefail

# Define terminal colors
readonly _RED=$(tput setaf 1)
readonly _GREEN=$(tput setaf 2)
readonly _YELLOW=$(tput setaf 3)
readonly _BLUE=$(tput setaf 4)
readonly _RESET=$(tput sgr0)

# Configuration
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly OVERRIDE_FLAG="/tmp/relay_manual_override"
readonly PID_FILE="/tmp/remote_control.pid"

# Logging functions
log_info() {
    echo "${_BLUE}[REMOTE]${_RESET} $1"
}

log_success() {
    echo "${_GREEN}[REMOTE]${_RESET} $1"
}

log_warning() {
    echo "${_YELLOW}[REMOTE]${_RESET} $1"
}

log_error() {
    echo "${_RED}[REMOTE]${_RESET} $1" >&2
}

# Load MQTT configuration
load_mqtt_config() {
    if [[ -f "${SCRIPT_DIR}/mqtt_service.sh" ]]; then
        source "${SCRIPT_DIR}/mqtt_service.sh"
        
        if ! validate_mqtt_config; then
            log_error "MQTT configuration validation failed"
            exit 1
        fi
    else
        log_error "MQTT configuration file not found: ${SCRIPT_DIR}/mqtt_service.sh"
        exit 1
    fi
}

# Function to control relay
control_relay() {
    local action="$1"
    local reason="$2"
    
    if [[ "$action" == "on" ]]; then
        if mbpoll -m rtu -a 1 -b 9600 -P none -s 1 -t 0 -r 2 /dev/ttyAMA4 -- 1 2>/dev/null; then
            log_success "Relay turned ON ($reason)"
            return 0
        else
            log_error "Failed to turn relay ON"
            return 1
        fi
    elif [[ "$action" == "off" ]]; then
        if mbpoll -m rtu -a 1 -b 9600 -P none -s 1 -t 0 -r 2 /dev/ttyAMA4 -- 0 2>/dev/null; then
            log_success "Relay turned OFF ($reason)"
            return 0
        else
            log_error "Failed to turn relay OFF"
            return 1
        fi
    fi
    
    return 1
}

# Function to handle remote commands
process_command() {
    local command="$1"
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    
    log_info "Received command: $command"
    
    case "$command" in
        *'"relay"*:*"on"'*)
            echo "manual_on|$timestamp" > "$OVERRIDE_FLAG"
            control_relay "on" "remote_command"
            log_info "Manual override: Relay ON"
            ;;
        *'"relay"*:*"off"'*)
            echo "manual_off|$timestamp" > "$OVERRIDE_FLAG"
            control_relay "off" "remote_command"
            log_info "Manual override: Relay OFF"
            ;;
        *'"mode"*:*"auto"'*)
            if [[ -f "$OVERRIDE_FLAG" ]]; then
                rm -f "$OVERRIDE_FLAG"
                log_info "Manual override DISABLED - returning to automatic control"
            else
                log_info "Already in automatic mode"
            fi
            ;;
        *'"status"*:*"request"'*)
            if [[ -f "$OVERRIDE_FLAG" ]]; then
                local override_info=$(cat "$OVERRIDE_FLAG")
                log_info "Status: Manual override active - $override_info"
            else
                log_info "Status: Automatic mode (no override)"
            fi
            ;;
        *)
            log_warning "Unknown command: $command"
            ;;
    esac
}

# Function to handle shutdown gracefully
cleanup() {
    log_info "Shutting down remote control listener..."
    
    # Remove override flag to return to automatic mode
    if [[ -f "$OVERRIDE_FLAG" ]]; then
        rm -f "$OVERRIDE_FLAG"
        log_info "Removed manual override - system returned to automatic mode"
    fi
    
    # Remove PID file
    rm -f "$PID_FILE"
    
    exit 0
}

trap cleanup SIGTERM SIGINT

# Function to check if already running
check_running() {
    if [[ -f "$PID_FILE" ]]; then
        local existing_pid=$(cat "$PID_FILE")
        if kill -0 "$existing_pid" 2>/dev/null; then
            log_error "Remote control listener already running (PID: $existing_pid)"
            log_info "Stop it first: kill $existing_pid"
            exit 1
        else
            # PID file exists but process is dead, remove stale file
            rm -f "$PID_FILE"
        fi
    fi
}

# Function to show status
show_status() {
    if [[ -f "$OVERRIDE_FLAG" ]]; then
        local override_info=$(cat "$OVERRIDE_FLAG")
        echo "Manual override: ACTIVE ($override_info)"
    else
        echo "Control mode: AUTOMATIC (no manual override)"
    fi
    
    if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo "Remote listener: RUNNING (PID: $(cat "$PID_FILE"))"
    else
        echo "Remote listener: NOT RUNNING"
    fi
}

# Function to show usage
show_usage() {
    cat << EOF
Remote Control Listener for Ultrasonic Sensor System

Usage: $0 [OPTION]

Options:
  start     Start the remote control listener
  stop      Stop the remote control listener  
  status    Show current status
  help      Show this help message

The listener subscribes to MQTT topic: ${_YELLOW}\${MQTT_TOPIC}/control${_RESET}

Commands:
  {"relay": "on"}      - Force relay ON (manual override)
  {"relay": "off"}     - Force relay OFF (manual override)  
  {"mode": "auto"}     - Return to automatic control
  {"status": "request"} - Request status information

When manual override is active, the main ultrasonic service continues
running but the relay control is overridden by remote commands.

Files:
  Override flag: $OVERRIDE_FLAG
  PID file: $PID_FILE
EOF
}

# Main listener function
start_listener() {
    log_info "Starting remote control listener..."
    
    # Save PID
    echo $$ > "$PID_FILE"
    
    log_info "Listening for commands on topic: ${MQTT_TOPIC}/control"
    log_info "Override flag file: $OVERRIDE_FLAG"
    log_info "Send commands using:"
    log_info "  mosquitto_pub -h $MQTT_BROKER -p $MQTT_PORT -t ${MQTT_TOPIC}/control -m '{\"relay\": \"on\"}'"
    echo
    
    # Start MQTT listener
    mosquitto_sub -h "$MQTT_BROKER" \
                  -p "$MQTT_PORT" \
                  -t "${MQTT_TOPIC}/control" \
                  -q "$MQTT_QOS" | while read -r line; do
        if [[ -n "$line" ]]; then
            process_command "$line"
        fi
    done
}

# Stop function
stop_listener() {
    if [[ -f "$PID_FILE" ]]; then
        local pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            log_info "Stopping remote control listener (PID: $pid)..."
            kill "$pid"
            sleep 2
            if kill -0 "$pid" 2>/dev/null; then
                log_warning "Process still running, force killing..."
                kill -9 "$pid"
            fi
            log_success "Remote control listener stopped"
        else
            log_warning "Process not running, cleaning up PID file"
        fi
        rm -f "$PID_FILE"
    else
        log_warning "Remote control listener is not running"
    fi
    
    # Remove override flag
    if [[ -f "$OVERRIDE_FLAG" ]]; then
        rm -f "$OVERRIDE_FLAG"
        log_info "Removed manual override - system returned to automatic mode"
    fi
}

# Main function
main() {
    case "${1:-start}" in
        "start")
            check_running
            load_mqtt_config
            
            # Test MQTT connection
            if ! test_mqtt_connection; then
                log_error "MQTT connection test failed"
                log_info "Please verify MQTT broker configuration in mqtt_service.sh"
                exit 1
            fi
            
            start_listener
            ;;
        "stop")
            stop_listener
            ;;
        "status")
            load_mqtt_config
            show_status
            ;;
        "help"|"-h"|"--help")
            show_usage
            ;;
        *)
            log_error "Invalid option: $1"
            show_usage
            exit 1
            ;;
    esac
}

# Run main function
main "$@"