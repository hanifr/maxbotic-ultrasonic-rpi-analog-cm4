# ===== primary.sh =====
#!/bin/bash

# Exit on any error
set -euo pipefail

# Define terminal colors
readonly _RED=$(tput setaf 1)
readonly _GREEN=$(tput setaf 2)
readonly _YELLOW=$(tput setaf 3)
readonly _BLUE=$(tput setaf 4)
readonly _MAGENTA=$(tput setaf 5)
readonly _CYAN=$(tput setaf 6)
readonly _RESET=$(tput sgr0)

# Configuration
readonly SERVICE_NAME="maxbotic_ultrasonic"
readonly SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Function to get user home directory
get_user_home() {
    if [[ -n "${SUDO_USER:-}" ]]; then
        eval echo "~$SUDO_USER"
    else
        echo "$HOME"
    fi
}

readonly USER_HOME=$(get_user_home)
readonly START_SCRIPT="${USER_HOME}/startUltrasonic.sh"

# Logging functions
log_info() {
    echo "${_MAGENTA}[INFO]${_RESET} $1"
}

log_success() {
    echo "${_GREEN}[SUCCESS]${_RESET} $1"
}

log_warning() {
    echo "${_YELLOW}[WARNING]${_RESET} $1"
}

log_error() {
    echo "${_RED}[ERROR]${_RESET} $1" >&2
}

# Error handler
cleanup_on_error() {
    log_error "Setup failed on line $1"
    log_info "Cleaning up partial installation..."
    
    # Stop and disable service if it was created
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        sudo systemctl stop "$SERVICE_NAME"
    fi
    
    if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
        sudo systemctl disable "$SERVICE_NAME"
    fi
    
    # Remove created files
    [[ -f "$SERVICE_FILE" ]] && sudo rm -f "$SERVICE_FILE"
    [[ -f "$START_SCRIPT" ]] && sudo rm -f "$START_SCRIPT"
    
    exit 1
}

trap 'cleanup_on_error $LINENO' ERR

# Dependency check
check_dependencies() {
    local dependencies=("bc" "mosquitto_pub" "mosquitto_sub" "systemctl" "mbpoll")
    local missing_deps=()
    
    for dep in "${dependencies[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing_deps+=("$dep")
        fi
    done
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "Missing dependencies: ${missing_deps[*]}"
        log_info "Please install missing dependencies and retry"
        exit 1
    fi
    
    log_success "All dependencies satisfied"
}

# Load MQTT configuration
load_mqtt_config() {
    if [[ -f "${SCRIPT_DIR}/mqtt_service.sh" ]]; then
        # shellcheck source=mqtt_service.sh
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

# Create startup script with MQTT control capability
create_startup_script() {
    log_info "Creating ultrasonic sensor startup script with MQTT relay control"
    
    sudo tee "$START_SCRIPT" > /dev/null << 'EOF'
#!/bin/bash

# Exit on error
set -euo pipefail

# Load MQTT configurations
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/mqtt_service.sh" ]]; then
    source "${SCRIPT_DIR}/mqtt_service.sh"
else
    echo "ERROR: MQTT configuration file not found" >&2
    exit 1
fi

# Validate configuration
if ! validate_mqtt_config; then
    echo "ERROR: MQTT configuration validation failed" >&2
    exit 1
fi

# Define control topics
CONTROL_TOPIC="${MQTT_TOPIC}/relay/control"
STATUS_TOPIC="${MQTT_TOPIC}/relay/status"

# Control files for relay state management
CONTROL_FILE="/tmp/relay_control"
RELAY_STATE_FILE="/tmp/relay_state"

# Initialize control files
echo "auto" > "$CONTROL_FILE"  # auto, manual_on, manual_off
echo "0" > "$RELAY_STATE_FILE"  # 0 = off, 1 = on

# Function to control relay
control_relay() {
    local state=$1
    local reason=$2
    
    # Read current state
    local current_state
    current_state=$(cat "$RELAY_STATE_FILE" 2>/dev/null || echo "0")
    
    # Only change if state is different
    if [[ "$state" != "$current_state" ]]; then
        if mbpoll -m rtu -a 1 -b 9600 -P none -s 1 -t 0 -r 2 /dev/ttyAMA4 -- "$state" 2>/dev/null; then
            echo "$state" > "$RELAY_STATE_FILE"
            echo "$(date): Relay ${state} (${reason})"
            
            # Publish relay state to MQTT
            local relay_status="OFF"
            [[ "$state" == "1" ]] && relay_status="ON"
            
            local status_payload="${relay_status}|${reason}|$(date +"%Y-%m-%dT%H:%M:%S")"
            
            mosquitto_pub -h "$MQTT_BROKER" \
                         -p "$MQTT_PORT" \
                         -t "$STATUS_TOPIC" \
                         -q "$MQTT_QOS" \
                         -m "$status_payload" 2>/dev/null || true
        else
            echo "$(date): ERROR: Failed to control relay" >&2
        fi
    fi
}

# MQTT control listener function
mqtt_control_listener() {
    echo "Starting MQTT control listener on topic: $CONTROL_TOPIC"
    
    mosquitto_sub -h "$MQTT_BROKER" \
                  -p "$MQTT_PORT" \
                  -t "$CONTROL_TOPIC" \
                  -q "$MQTT_QOS" | while read -r message; do
        
        echo "$(date): Received MQTT control: $message"
        
        case "$message" in
            "ON"|"on"|"1")
                echo "manual_on" > "$CONTROL_FILE"
                control_relay "1" "MQTT ON command"
                ;;
            "OFF"|"off"|"0")
                echo "manual_off" > "$CONTROL_FILE"
                control_relay "0" "MQTT OFF command"
                ;;
            "AUTO"|"auto")
                echo "auto" > "$CONTROL_FILE"
                echo "$(date): Relay control set to automatic mode"
                ;;
            *)
                echo "$(date): Unknown control command: $message" >&2
                ;;
        esac
    done &
    
    # Store PID for cleanup
    echo $! > /tmp/mqtt_listener.pid
}

# Function to handle shutdown gracefully
cleanup() {
    echo "Shutting down ultrasonic sensor service..."
    
    # Kill MQTT listener if running
    if [[ -f /tmp/mqtt_listener.pid ]]; then
        local listener_pid
        listener_pid=$(cat /tmp/mqtt_listener.pid)
        if kill -0 "$listener_pid" 2>/dev/null; then
            kill "$listener_pid" 2>/dev/null || true
        fi
        rm -f /tmp/mqtt_listener.pid
    fi
    
    # Turn off relay on shutdown
    control_relay "0" "Service shutdown"
    
    # Cleanup temp files
    rm -f "$CONTROL_FILE" "$RELAY_STATE_FILE"
    
    exit 0
}

trap cleanup SIGTERM SIGINT

# Check if sensor device exists
if [[ ! -d "$SENSOR_DIR" ]]; then
    echo "ERROR: Sensor device not found at $SENSOR_DIR" >&2
    exit 1
fi

# Ensure output directory exists
OUTPUT_DIR="$(dirname "$OUTPUT_FILE")"
[[ ! -d "$OUTPUT_DIR" ]] && mkdir -p "$OUTPUT_DIR"

echo "Starting ultrasonic sensor monitoring with MQTT relay control..."
echo "Sensor: $SENSOR_DIR"
echo "MQTT Broker: $MQTT_BROKER:$MQTT_PORT"
echo "Data Topic: $MQTT_TOPIC"
echo "Control Topic: $CONTROL_TOPIC"
echo "Status Topic: $STATUS_TOPIC"
echo "Measurement interval: ${MEASUREMENT_INTERVAL}s"

# Start MQTT control listener
mqtt_control_listener

# Continuous measurement loop
while true; do
    if RAW_VALUE=$(cat "$SENSOR_DIR/in_voltage1_raw" 2>/dev/null); then
        # Calculate distance using bc for floating point arithmetic
        ULTRASONIC_DISTANCE=$(echo "scale=3; ($RAW_VALUE * 10) / 1303" | bc)
        
        # Create JSON payload with timestamp
        TIMESTAMP=$(date +"%Y-%m-%dT%H:%M:%S.%3N")
        JSON_PAYLOAD=$(cat << JSON_EOF
{
    "distance": $ULTRASONIC_DISTANCE,
    "unit": "meters",
    "timestamp": "$TIMESTAMP",
    "sensor_id": "$MQTT_CLIENT_ID",
    "raw_value": $RAW_VALUE
}
JSON_EOF
)
        
        # Save data locally with timestamp
        echo "$TIMESTAMP,$ULTRASONIC_DISTANCE" >> "$OUTPUT_FILE"
        
        # Check control mode
        CONTROL_MODE=$(cat "$CONTROL_FILE" 2>/dev/null || echo "auto")
        
        case "$CONTROL_MODE" in
            "auto")
                # Automatic control based on distance threshold
                THRESHOLD=5.0
                is_below_threshold=$(echo "$ULTRASONIC_DISTANCE < $THRESHOLD" | bc)
                
                if [[ $is_below_threshold -eq 1 ]]; then
                    control_relay "1" "Distance: ${ULTRASONIC_DISTANCE}m < ${THRESHOLD}m"
                    
                    # Publish sensor data to MQTT when relay is on
                    if mosquitto_pub -h "$MQTT_BROKER" \
                                      -p "$MQTT_PORT" \
                                      -t "$MQTT_TOPIC" \
                                      -q "$MQTT_QOS" \
                                      -m "$JSON_PAYLOAD" 2>/dev/null; then
                        echo "$(date): Distance: ${ULTRASONIC_DISTANCE}m (published)"
                    else
                        echo "$(date): Distance: ${ULTRASONIC_DISTANCE}m (publish failed)" >&2
                    fi
                else
                    control_relay "0" "Distance: ${ULTRASONIC_DISTANCE}m >= ${THRESHOLD}m"
                    echo "$(date): Distance: ${ULTRASONIC_DISTANCE}m (above threshold)"
                fi
                ;;
            "manual_on")
                # Manual ON mode - always publish data
                if mosquitto_pub -h "$MQTT_BROKER" \
                                  -p "$MQTT_PORT" \
                                  -t "$MQTT_TOPIC" \
                                  -q "$MQTT_QOS" \
                                  -m "$JSON_PAYLOAD" 2>/dev/null; then
                    echo "$(date): Distance: ${ULTRASONIC_DISTANCE}m (manual ON, published)"
                else
                    echo "$(date): Distance: ${ULTRASONIC_DISTANCE}m (manual ON, publish failed)" >&2
                fi
                ;;
            "manual_off")
                # Manual OFF mode - don't publish, just log
                echo "$(date): Distance: ${ULTRASONIC_DISTANCE}m (manual OFF)"
                ;;
        esac
        
    else
        echo "$(date): ERROR: Failed to read sensor data from $SENSOR_DIR/in_voltage1_raw" >&2
    fi
    
    sleep "$MEASUREMENT_INTERVAL"
done
EOF

    # Set proper permissions
    sudo chmod 755 "$START_SCRIPT"
    log_success "Startup script created at $START_SCRIPT"
}

# Create systemd service
create_systemd_service() {
    log_info "Creating systemd service: $SERVICE_NAME"
    
    # Get the actual username for the service
    local service_user
    if [[ -n "${SUDO_USER:-}" ]]; then
        service_user="$SUDO_USER"
    else
        service_user="$(whoami)"
    fi
    
    sudo tee "$SERVICE_FILE" > /dev/null << EOF
[Unit]
Description=Maxbotic Ultrasonic Sensor Service with MQTT Relay Control
After=network.target mosquitto.service
Wants=mosquitto.service

[Service]
Type=simple
ExecStart=$START_SCRIPT
Restart=on-failure
RestartSec=5
User=$service_user
Group=$service_user
WorkingDirectory=$USER_HOME

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=$SERVICE_NAME

[Install]
WantedBy=multi-user.target
EOF

    # Set correct permissions
    sudo chmod 644 "$SERVICE_FILE"
    log_success "Systemd service created"
}

# Setup and start service
setup_service() {
    log_info "Setting up systemd service"
    
    # Reload systemd daemon
    sudo systemctl daemon-reload
    
    # Enable and start service
    if sudo systemctl enable "$SERVICE_NAME"; then
        log_success "Service enabled successfully"
    else
        log_error "Failed to enable service"
        exit 1
    fi
    
    if sudo systemctl start "$SERVICE_NAME"; then
        log_success "Service started successfully"
    else
        log_warning "Service may have failed to start. Check logs for details."
    fi
    
    # Wait a moment and check service status
    sleep 3
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        log_success "Service is running successfully"
    else
        log_warning "Service is not running. Check status with: systemctl status $SERVICE_NAME"
    fi
}

# Display usage information
show_usage_info() {
    echo
    echo "${_CYAN}=== Service Management Commands ===${_RESET}"
    echo "View logs:           ${_YELLOW}sudo journalctl -u $SERVICE_NAME -f${_RESET}"
    echo "Service status:      ${_YELLOW}sudo systemctl status $SERVICE_NAME${_RESET}"
    echo "Start service:       ${_YELLOW}sudo systemctl start $SERVICE_NAME${_RESET}"
    echo "Stop service:        ${_YELLOW}sudo systemctl stop $SERVICE_NAME${_RESET}"
    echo "Restart service:     ${_YELLOW}sudo systemctl restart $SERVICE_NAME${_RESET}"
    echo
    echo "${_CYAN}=== MQTT Relay Control Commands ===${_RESET}"
    echo "Turn relay ON:       ${_YELLOW}mosquitto_pub -h $MQTT_BROKER -t $MQTT_TOPIC/relay/control -m \"ON\"${_RESET}"
    echo "Turn relay OFF:      ${_YELLOW}mosquitto_pub -h $MQTT_BROKER -t $MQTT_TOPIC/relay/control -m \"OFF\"${_RESET}"
    echo "Set to AUTO mode:    ${_YELLOW}mosquitto_pub -h $MQTT_BROKER -t $MQTT_TOPIC/relay/control -m \"AUTO\"${_RESET}"
    echo "Monitor relay status: ${_YELLOW}mosquitto_sub -h $MQTT_BROKER -t $MQTT_TOPIC/relay/status${_RESET}"
    echo
    echo "${_CYAN}=== Configuration Files ===${_RESET}"
    echo "Startup script:      ${_YELLOW}$START_SCRIPT${_RESET}"
    echo "Service file:        ${_YELLOW}$SERVICE_FILE${_RESET}"
    echo "MQTT config:         ${_YELLOW}${SCRIPT_DIR}/mqtt_service.sh${_RESET}"
    echo
    echo "${_CYAN}=== Control Modes ===${_RESET}"
    echo "AUTO:    Relay controlled by distance threshold (< 5.0m = ON)"
    echo "MANUAL:  Relay controlled by MQTT commands (ON/OFF)"
    echo
}

# Main function
main() {
    log_info "Maxbotic Ultrasonic Sensor service setup started"
    echo
    
    check_dependencies
    load_mqtt_config
    
    # Test MQTT connection before proceeding
    if ! test_mqtt_connection; then
        log_warning "MQTT connection test failed. Service will be created but may not work properly."
        log_info "Please verify MQTT broker configuration in mqtt_service.sh"
    fi
    
    create_startup_script
    create_systemd_service
    setup_service
    
    log_success "Maxbotic Ultrasonic service with MQTT relay control setup completed successfully!"
    show_usage_info
}

# Run main function
main "$@"