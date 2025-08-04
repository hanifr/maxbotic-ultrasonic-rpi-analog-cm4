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
readonly START_SCRIPT="/home/pi/startUltrasonic.sh"
readonly CONTROL_CLIENT="/home/pi/relay_control_client.sh"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
    [[ -f "$CONTROL_CLIENT" ]] && sudo rm -f "$CONTROL_CLIENT"
    
    exit 1
}

trap 'cleanup_on_error $LINENO' ERR

# Dependency check
check_dependencies() {
    local dependencies=("bc" "mosquitto_pub" "mosquitto_sub" "systemctl")
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

# Load and validate MQTT configuration
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

# Create startup script with simple remote control
create_startup_script() {
    log_info "Creating ultrasonic sensor startup script with simple remote control"
    
    # Create the startup script with proper error handling
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

# Simple remote control variables
CONTROL_TOPIC="${MQTT_TOPIC}/control"
CONTROL_FILE="/tmp/relay_control"
MANUAL_MODE=false

# Function to handle shutdown gracefully
cleanup() {
    echo "Shutting down ultrasonic sensor service..."
    rm -f "$CONTROL_FILE"
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

echo "Starting ultrasonic sensor monitoring with simple remote control..."
echo "Sensor: $SENSOR_DIR"
echo "MQTT Broker: $MQTT_BROKER:$MQTT_PORT"
echo "Topic: $MQTT_TOPIC"
echo "Control Topic: $CONTROL_TOPIC"
echo "Measurement interval: ${MEASUREMENT_INTERVAL}s"

# Simple control check counter
CONTROL_CHECK_COUNTER=0

# Continuous measurement loop (original logic preserved)
while true; do
    # Check for remote control commands every 5 cycles (simple approach)
    if [[ $((CONTROL_CHECK_COUNTER % 5)) -eq 0 ]]; then
        # Simple file-based control check
        if [[ -f "$CONTROL_FILE" ]]; then
            CONTROL_COMMAND=$(cat "$CONTROL_FILE" 2>/dev/null || echo "")
            case "$CONTROL_COMMAND" in
                "on")
                    echo "$(date): Remote command: Relay ON"
                    mbpoll -m rtu -a 1 -b 9600 -P none -s 1 -t 0 -r 2 /dev/ttyAMA4 -- 1
                    MANUAL_MODE=true
                    ;;
                "off")
                    echo "$(date): Remote command: Relay OFF"
                    mbpoll -m rtu -a 1 -b 9600 -P none -s 1 -t 0 -r 2 /dev/ttyAMA4 -- 0
                    MANUAL_MODE=true
                    ;;
                "auto")
                    echo "$(date): Remote command: Auto mode"
                    MANUAL_MODE=false
                    ;;
            esac
            rm -f "$CONTROL_FILE"
        fi
        
        # Also check MQTT for commands (simple, non-blocking)
        MQTT_CMD=$(timeout 0.1 mosquitto_sub -h "$MQTT_BROKER" -p "$MQTT_PORT" -t "$CONTROL_TOPIC" -C 1 2>/dev/null | head -1 || echo "")
        if [[ -n "$MQTT_CMD" ]]; then
            if echo "$MQTT_CMD" | grep -q '"relay".*:.*"on"'; then
                echo "$(date): MQTT command: Relay ON"
                mbpoll -m rtu -a 1 -b 9600 -P none -s 1 -t 0 -r 2 /dev/ttyAMA4 -- 1
                MANUAL_MODE=true
            elif echo "$MQTT_CMD" | grep -q '"relay".*:.*"off"'; then
                echo "$(date): MQTT command: Relay OFF"
                mbpoll -m rtu -a 1 -b 9600 -P none -s 1 -t 0 -r 2 /dev/ttyAMA4 -- 0
                MANUAL_MODE=true
            elif echo "$MQTT_CMD" | grep -q '"mode".*:.*"auto"'; then
                echo "$(date): MQTT command: Auto mode"
                MANUAL_MODE=false
            fi
        fi
    fi
    CONTROL_CHECK_COUNTER=$((CONTROL_CHECK_COUNTER + 1))
    
    # Original sensor reading and relay logic
    if RAW_VALUE=$(cat "$SENSOR_DIR/in_voltage1_raw" 2>/dev/null); then
        # Calculate distance using bc for floating point arithmetic
        ULTRASONIC_DISTANCE=$(echo "scale=3; ($RAW_VALUE * 10) / 1303" | bc)
        
        # Create JSON payload with timestamp (enhanced with manual_mode)
        TIMESTAMP=$(date +"%Y-%m-%dT%H:%M:%S.%3N")
        JSON_PAYLOAD=$(cat << JSON_EOF
{
    "distance": $ULTRASONIC_DISTANCE,
    "unit": "meters",
    "timestamp": "$TIMESTAMP",
    "sensor_id": "$MQTT_CLIENT_ID",
    "raw_value": $RAW_VALUE,
    "manual_mode": $MANUAL_MODE
}
JSON_EOF
)
        
        # Save data locally with timestamp
        echo "$TIMESTAMP,$ULTRASONIC_DISTANCE" >> "$OUTPUT_FILE"

        # Original threshold logic - skip if in manual mode
        if [[ "$MANUAL_MODE" == false ]]; then
            THRESHOLD=5.0
            is_below_threshold=$(echo "$ULTRASONIC_DISTANCE < $THRESHOLD" | bc)
            if [[ $is_below_threshold -eq 1 ]]; then
                # Turn on the relay if distance is below threshold
                mbpoll -m rtu -a 1 -b 9600 -P none -s 1 -t 0 -r 2 /dev/ttyAMA4 -- 1
            else
                # Turn off the relay if distance is above threshold
                mbpoll -m rtu -a 1 -b 9600 -P none -s 1 -t 0 -r 2 /dev/ttyAMA4 -- 0
                continue  # Original behavior - don't publish when above threshold
            fi
        fi
        
        # Publish to MQTT broker with error handling (original logic)
        if mosquitto_pub -h "$MQTT_BROKER" \
                          -p "$MQTT_PORT" \
                          -t "$MQTT_TOPIC" \
                          -q "$MQTT_QOS" \
                          -m "$JSON_PAYLOAD" 2>/dev/null; then
            if [[ "$MANUAL_MODE" == true ]]; then
                echo "$(date): Distance: ${ULTRASONIC_DISTANCE}m (manual mode, published successfully)"
            else
                echo "$(date): Distance: ${ULTRASONIC_DISTANCE}m (published successfully)"
            fi
        else
            echo "$(date): Distance: ${ULTRASONIC_DISTANCE}m (MQTT publish failed)" >&2
        fi
        
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

# Create simple control client
create_control_client() {
    log_info "Creating simple relay control client"
    
    sudo tee "$CONTROL_CLIENT" > /dev/null << 'EOF'
#!/bin/bash

# Simple Remote Relay Control Client
# Usage: ./relay_control_client.sh [on|off|auto]

# Load MQTT configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/mqtt_service.sh" ]]; then
    source "${SCRIPT_DIR}/mqtt_service.sh"
else
    echo "ERROR: MQTT configuration file not found" >&2
    exit 1
fi

CONTROL_TOPIC="${MQTT_TOPIC}/control"

# Simple usage function
show_usage() {
    echo "Usage: $0 [on|off|auto]"
    echo "  on   - Turn relay ON (manual mode)"
    echo "  off  - Turn relay OFF (manual mode)"
    echo "  auto - Switch to automatic mode"
}

# Main function
if [[ $# -eq 0 ]]; then
    show_usage
    exit 1
fi

case "$1" in
    "on")
        echo "Sending command: Relay ON"
        mosquitto_pub -h "$MQTT_BROKER" -p "$MQTT_PORT" -t "$CONTROL_TOPIC" -m '{"relay": "on"}'
        ;;
    "off")
        echo "Sending command: Relay OFF"
        mosquitto_pub -h "$MQTT_BROKER" -p "$MQTT_PORT" -t "$CONTROL_TOPIC" -m '{"relay": "off"}'
        ;;
    "auto")
        echo "Sending command: Auto mode"
        mosquitto_pub -h "$MQTT_BROKER" -p "$MQTT_PORT" -t "$CONTROL_TOPIC" -m '{"mode": "auto"}'
        ;;
    *)
        echo "Error: Invalid command '$1'"
        show_usage
        exit 1
        ;;
esac

echo "Command sent successfully"
EOF

    # Set proper permissions
    sudo chmod 755 "$CONTROL_CLIENT"
    log_success "Simple control client created at $CONTROL_CLIENT"
}

# Create systemd service
create_systemd_service() {
    log_info "Creating systemd service: $SERVICE_NAME"
    
    sudo tee "$SERVICE_FILE" > /dev/null << EOF
[Unit]
Description=Maxbotic Ultrasonic Sensor Service
Documentation=man:ultrasonic-sensor(1)
After=network.target mosquitto.service
Wants=mosquitto.service

[Service]
Type=simple
ExecStart=$START_SCRIPT
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5
StartLimitIntervalSec=60
StartLimitBurst=3
User=pi
Group=pi
WorkingDirectory=/home/pi

# Security settings
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=/home/pi /tmp

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
    sleep 2
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
    echo "Disable service:     ${_YELLOW}sudo systemctl disable $SERVICE_NAME${_RESET}"
    echo
    echo "${_CYAN}=== Simple Remote Control ===${_RESET}"
    echo "Turn relay ON:       ${_YELLOW}$CONTROL_CLIENT on${_RESET}"
    echo "Turn relay OFF:      ${_YELLOW}$CONTROL_CLIENT off${_RESET}"
    echo "Auto mode:           ${_YELLOW}$CONTROL_CLIENT auto${_RESET}"
    echo
    echo "${_CYAN}=== Configuration Files ===${_RESET}"
    echo "Startup script:      ${_YELLOW}$START_SCRIPT${_RESET}"
    echo "Control client:      ${_YELLOW}$CONTROL_CLIENT${_RESET}"
    echo "Service file:        ${_YELLOW}$SERVICE_FILE${_RESET}"
    echo "MQTT config:         ${_YELLOW}${SCRIPT_DIR}/mqtt_service.sh${_RESET}"
    echo
}

# Main function
main() {
    log_info "Maxbotic Ultrasonic Sensor service setup with simple remote control started"
    echo
    
    check_dependencies
    load_mqtt_config
    
    # Test MQTT connection before proceeding
    if ! test_mqtt_connection; then
        log_warning "MQTT connection test failed. Service will be created but may not work properly."
        log_info "Please verify MQTT broker configuration in mqtt_service.sh"
    fi
    
    create_startup_script
    create_control_client
    create_systemd_service
    setup_service
    
    log_success "Maxbotic Ultrasonic service with simple remote control setup completed successfully!"
    show_usage_info
}

# Run main function
main "$@"