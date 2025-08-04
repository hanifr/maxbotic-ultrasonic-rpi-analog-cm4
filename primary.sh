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

# Create enhanced startup script (based on original logic)
create_startup_script() {
    log_info "Creating enhanced ultrasonic sensor startup script with remote control"
    
    # Create the startup script with remote control functionality added to original logic
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

# Remote control configuration
CONTROL_TOPIC="${MQTT_TOPIC}/control"
STATUS_TOPIC="${MQTT_TOPIC}/status"
FIFO_PATH="/tmp/relay_control_fifo"

# Control state variables
RELAY_MODE="auto"  # "auto", "manual_on", "manual_off"
MANUAL_OVERRIDE=false
CURRENT_RELAY_STATE="unknown"

# Function to control relay
control_relay() {
    local action="$1"
    local reason="$2"
    
    if [[ "$action" == "on" ]]; then
        if mbpoll -m rtu -a 1 -b 9600 -P none -s 1 -t 0 -r 2 /dev/ttyAMA4 -- 1 2>/dev/null; then
            CURRENT_RELAY_STATE="on"
            echo "$(date): Relay turned ON ($reason)"
            publish_status_update "on" "$reason"
        else
            echo "$(date): ERROR: Failed to turn relay ON" >&2
        fi
    elif [[ "$action" == "off" ]]; then
        if mbpoll -m rtu -a 1 -b 9600 -P none -s 1 -t 0 -r 2 /dev/ttyAMA4 -- 0 2>/dev/null; then
            CURRENT_RELAY_STATE="off"
            echo "$(date): Relay turned OFF ($reason)"
            publish_status_update "off" "$reason"
        else
            echo "$(date): ERROR: Failed to turn relay OFF" >&2
        fi
    fi
}

# Function to publish status updates
publish_status_update() {
    local relay_status="$1"
    local reason="$2"
    local timestamp=$(date +"%Y-%m-%dT%H:%M:%S.%3N")
    
    local status_payload=$(cat << JSON_EOF
{
    "relay_status": "$relay_status",
    "control_mode": "$RELAY_MODE",
    "reason": "$reason",
    "timestamp": "$timestamp",
    "sensor_id": "$MQTT_CLIENT_ID"
}
JSON_EOF
)
    
    mosquitto_pub -h "$MQTT_BROKER" \
                  -p "$MQTT_PORT" \
                  -t "$STATUS_TOPIC" \
                  -q "$MQTT_QOS" \
                  -m "$status_payload" 2>/dev/null || true
}

# Function to handle control messages
process_control_message() {
    local message="$1"
    echo "$(date): Received control message: $message"
    
    # Simple JSON parsing for control commands
    if echo "$message" | grep -q '"relay".*:.*"on"'; then
        RELAY_MODE="manual_on"
        MANUAL_OVERRIDE=true
        control_relay "on" "remote_command"
    elif echo "$message" | grep -q '"relay".*:.*"off"'; then
        RELAY_MODE="manual_off"
        MANUAL_OVERRIDE=true
        control_relay "off" "remote_command"
    elif echo "$message" | grep -q '"mode".*:.*"auto"'; then
        RELAY_MODE="auto"
        MANUAL_OVERRIDE=false
        echo "$(date): Switched to automatic mode"
        publish_status_update "$CURRENT_RELAY_STATE" "switched_to_auto"
    elif echo "$message" | grep -q '"status".*:.*"request"'; then
        # Status request
        publish_status_update "$CURRENT_RELAY_STATE" "status_request"
    else
        echo "$(date): Unknown control command: $message"
    fi
}

# Function to start MQTT subscription in background
start_mqtt_listener() {
    # Create named pipe for communication
    [[ -p "$FIFO_PATH" ]] || mkfifo "$FIFO_PATH"
    
    # Start MQTT subscriber in background
    (
        mosquitto_sub -h "$MQTT_BROKER" \
                      -p "$MQTT_PORT" \
                      -t "$CONTROL_TOPIC" \
                      -q "$MQTT_QOS" 2>/dev/null | while read -r line; do
            echo "$line" > "$FIFO_PATH" 2>/dev/null || true
        done
    ) &
    
    MQTT_SUB_PID=$!
    echo "$(date): MQTT listener started (PID: $MQTT_SUB_PID)"
}

# Function to handle shutdown gracefully
cleanup() {
    echo "$(date): Shutting down ultrasonic sensor service..."
    
    # Clean up MQTT subscription
    [[ -n "${MQTT_SUB_PID:-}" ]] && kill "$MQTT_SUB_PID" 2>/dev/null || true
    
    # Remove FIFO
    [[ -p "$FIFO_PATH" ]] && rm -f "$FIFO_PATH"
    
    # Turn off relay on shutdown
    if [[ "$CURRENT_RELAY_STATE" == "on" ]]; then
        control_relay "off" "service_shutdown"
    fi
    
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

echo "Starting enhanced ultrasonic sensor monitoring with remote control..."
echo "Sensor: $SENSOR_DIR"
echo "MQTT Broker: $MQTT_BROKER:$MQTT_PORT"
echo "Data Topic: $MQTT_TOPIC"
echo "Control Topic: $CONTROL_TOPIC"
echo "Status Topic: $STATUS_TOPIC"
echo "Measurement interval: ${MEASUREMENT_INTERVAL}s"

# Start MQTT listener for remote control
start_mqtt_listener

# Send startup status
CURRENT_RELAY_STATE="off"
publish_status_update "off" "service_started"

# Main monitoring loop (preserving original logic)
while true; do
    # Check for control messages (non-blocking)
    if [[ -p "$FIFO_PATH" ]] && read -t 0 < "$FIFO_PATH" 2>/dev/null; then
        if read -r control_msg < "$FIFO_PATH" 2>/dev/null; then
            process_control_message "$control_msg"
        fi
    fi
    
    # Read sensor data
    if RAW_VALUE=$(cat "$SENSOR_DIR/in_voltage1_raw" 2>/dev/null); then
        # Calculate distance using bc for floating point arithmetic
        ULTRASONIC_DISTANCE=$(echo "scale=3; ($RAW_VALUE * 10) / 1303" | bc)
        
        # Create JSON payload with timestamp (enhanced with relay info)
        TIMESTAMP=$(date +"%Y-%m-%dT%H:%M:%S.%3N")
        JSON_PAYLOAD=$(cat << JSON_EOF
{
    "distance": $ULTRASONIC_DISTANCE,
    "unit": "meters",
    "timestamp": "$TIMESTAMP",
    "sensor_id": "$MQTT_CLIENT_ID",
    "raw_value": $RAW_VALUE,
    "relay_status": "$CURRENT_RELAY_STATE",
    "control_mode": "$RELAY_MODE"
}
JSON_EOF
)
        
        # Save data locally with timestamp (enhanced with relay info)
        echo "$TIMESTAMP,$ULTRASONIC_DISTANCE,$CURRENT_RELAY_STATE,$RELAY_MODE" >> "$OUTPUT_FILE"

        # Original threshold logic - only act if in automatic mode
        THRESHOLD=5.0
        is_below_threshold=$(echo "$ULTRASONIC_DISTANCE < $THRESHOLD" | bc)
        
        if [[ "$MANUAL_OVERRIDE" == false ]]; then
            # Original automatic relay control logic
            if [[ $is_below_threshold -eq 1 ]]; then
                # Turn on the relay if distance is below threshold
                control_relay "on" "distance_${ULTRASONIC_DISTANCE}m_below_threshold"
            else
                # Turn off the relay if distance is above threshold
                control_relay "off" "distance_${ULTRASONIC_DISTANCE}m_above_threshold"
                # Continue to skip MQTT publishing when above threshold (original behavior)
                continue
            fi
        fi
        
        # Original MQTT publishing logic - only publish when below threshold or in manual mode
        if [[ $is_below_threshold -eq 1 ]] || [[ "$MANUAL_OVERRIDE" == true ]]; then
            if mosquitto_pub -h "$MQTT_BROKER" \
                              -p "$MQTT_PORT" \
                              -t "$MQTT_TOPIC" \
                              -q "$MQTT_QOS" \
                              -m "$JSON_PAYLOAD" 2>/dev/null; then
                echo "$(date): Distance: ${ULTRASONIC_DISTANCE}m, Relay: $CURRENT_RELAY_STATE, Mode: $RELAY_MODE (published successfully)"
            else
                echo "$(date): Distance: ${ULTRASONIC_DISTANCE}m, Relay: $CURRENT_RELAY_STATE, Mode: $RELAY_MODE (MQTT publish failed)" >&2
            fi
        else
            # When above threshold in auto mode, just log without publishing (original behavior)
            echo "$(date): Distance: ${ULTRASONIC_DISTANCE}m (above threshold, not publishing)"
        fi
        
    else
        echo "$(date): ERROR: Failed to read sensor data from $SENSOR_DIR/in_voltage1_raw" >&2
    fi
    
    sleep "$MEASUREMENT_INTERVAL"
done
EOF

    # Set proper permissions
    sudo chmod 755 "$START_SCRIPT"
    log_success "Enhanced startup script created at $START_SCRIPT"
}

# Create remote control client script
create_control_client() {
    log_info "Creating remote relay control client"
    
    sudo tee "$CONTROL_CLIENT" > /dev/null << 'EOF'
#!/bin/bash

# Remote Relay Control Client
# Usage: ./relay_control_client.sh [on|off|auto|status|monitor]

# Load MQTT configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/mqtt_service.sh" ]]; then
    source "${SCRIPT_DIR}/mqtt_service.sh"
else
    echo "ERROR: MQTT configuration file not found" >&2
    exit 1
fi

# Control and status topics
CONTROL_TOPIC="${MQTT_TOPIC}/control"
STATUS_TOPIC="${MQTT_TOPIC}/status"

# Colors for output
RED=$(tput setaf 1)
GREEN=$(tput setaf 2)
YELLOW=$(tput setaf 3)
BLUE=$(tput setaf 4)
RESET=$(tput sgr0)

# Function to show usage
show_usage() {
    cat << USAGE_EOF
${BLUE}Remote Relay Control Client${RESET}

${YELLOW}Usage:${RESET}
    \$0 <command>

${YELLOW}Commands:${RESET}
    ${GREEN}on${RESET}          Turn relay ON (manual mode)
    ${GREEN}off${RESET}         Turn relay OFF (manual mode)  
    ${GREEN}auto${RESET}        Switch to automatic mode (distance-based control)
    ${GREEN}status${RESET}      Request current status
    ${GREEN}monitor${RESET}     Monitor sensor data (10 seconds)
    ${GREEN}listen${RESET}      Listen for status updates (10 seconds)

${YELLOW}Examples:${RESET}
    \$0 on                      # Turn relay on
    \$0 off                     # Turn relay off
    \$0 auto                    # Switch to automatic mode
    \$0 status                  # Request status
    \$0 monitor                 # Monitor sensor data
    \$0 listen                  # Listen for status updates

${YELLOW}MQTT Configuration:${RESET}
    Broker: $MQTT_BROKER:$MQTT_PORT
    Data Topic: $MQTT_TOPIC
    Control Topic: $CONTROL_TOPIC
    Status Topic: $STATUS_TOPIC
USAGE_EOF
}

# Function to send control command
send_command() {
    local command="$1"
    local payload=""
    local description=""
    
    case "$command" in
        "on")
            payload='{"relay": "on"}'
            description="Turn relay ON"
            ;;
        "off")
            payload='{"relay": "off"}'
            description="Turn relay OFF"
            ;;
        "auto")
            payload='{"mode": "auto"}'
            description="Switch to automatic mode"
            ;;
        "status")
            payload='{"status": "request"}'
            description="Request status update"
            ;;
        *)
            echo "${RED}Error: Invalid command '$command'${RESET}"
            show_usage
            exit 1
            ;;
    esac
    
    echo "${BLUE}[INFO]${RESET} $description"
    echo "${BLUE}[INFO]${RESET} Publishing to: $CONTROL_TOPIC"
    
    if mosquitto_pub -h "$MQTT_BROKER" \
                      -p "$MQTT_PORT" \
                      -t "$CONTROL_TOPIC" \
                      -q "$MQTT_QOS" \
                      -m "$payload"; then
        echo "${GREEN}[SUCCESS]${RESET} Command sent successfully"
    else
        echo "${RED}[ERROR]${RESET} Failed to send command"
        exit 1
    fi
}

# Function to monitor sensor data
monitor_sensor() {
    echo "${BLUE}[INFO]${RESET} Monitoring sensor data for 10 seconds..."
    echo "${BLUE}[INFO]${RESET} Data topic: $MQTT_TOPIC"
    echo "${YELLOW}Press Ctrl+C to stop monitoring${RESET}"
    echo
    
    timeout 10 mosquitto_sub -h "$MQTT_BROKER" \
                             -p "$MQTT_PORT" \
                             -t "$MQTT_TOPIC" \
                             -q "$MQTT_QOS" \
                             -v 2>/dev/null | while read -r line; do
        # Extract key information from JSON payload
        if echo "$line" | grep -q "distance"; then
            distance=$(echo "$line" | grep -o '"distance":[^,]*' | cut -d':' -f2 | tr -d ' ')
            relay_status=$(echo "$line" | grep -o '"relay_status":"[^"]*"' | cut -d'"' -f4 2>/dev/null || echo "unknown")
            control_mode=$(echo "$line" | grep -o '"control_mode":"[^"]*"' | cut -d'"' -f4 2>/dev/null || echo "unknown")
            timestamp=$(echo "$line" | grep -o '"timestamp":"[^"]*"' | cut -d'"' -f4 2>/dev/null || echo "unknown")
            
            echo "${GREEN}[DATA]${RESET} ${timestamp} | Distance: ${distance}m | Relay: ${relay_status} | Mode: ${control_mode}"
        else
            echo "${GREEN}[RAW]${RESET} $line"
        fi
    done
    
    echo "${YELLOW}[INFO]${RESET} Monitoring completed"
}

# Function to listen for status updates
listen_status() {
    echo "${BLUE}[INFO]${RESET} Listening for status updates for 10 seconds..."
    echo "${BLUE}[INFO]${RESET} Status topic: $STATUS_TOPIC"
    echo "${YELLOW}Press Ctrl+C to stop listening${RESET}"
    echo
    
    timeout 10 mosquitto_sub -h "$MQTT_BROKER" \
                             -p "$MQTT_PORT" \
                             -t "$STATUS_TOPIC" \
                             -q "$MQTT_QOS" \
                             -v 2>/dev/null | while read -r line; do
        echo "${GREEN}[STATUS]${RESET} $line"
    done
    
    echo "${YELLOW}[INFO]${RESET} Status listening completed"
}

# Main function
main() {
    if [[ $# -eq 0 ]]; then
        show_usage
        exit 1
    fi
    
    local command="$1"
    
    # Validate MQTT configuration
    if ! validate_mqtt_config; then
        echo "${RED}[ERROR]${RESET} MQTT configuration validation failed"
        exit 1
    fi
    
    # Execute command
    case "$command" in
        "on"|"off"|"auto"|"status")
            send_command "$command"
            ;;
        "monitor")
            monitor_sensor
            ;;
        "listen")
            listen_status
            ;;
        "help"|"-h"|"--help")
            show_usage
            ;;
        *)
            echo "${RED}Error: Invalid command '$command'${RESET}"
            show_usage
            exit 1
            ;;
    esac
}

# Run main function
main "$@"
EOF

    # Set proper permissions
    sudo chmod 755 "$CONTROL_CLIENT"
    log_success "Control client created at $CONTROL_CLIENT"
}

# Create systemd service
create_systemd_service() {
    log_info "Creating systemd service: $SERVICE_NAME"
    
    sudo tee "$SERVICE_FILE" > /dev/null << EOF
[Unit]
Description=Maxbotic Ultrasonic Sensor Service with Remote Control
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
    echo "${_CYAN}=== Remote Control Commands ===${_RESET}"
    echo "Turn relay ON:       ${_YELLOW}$CONTROL_CLIENT on${_RESET}"
    echo "Turn relay OFF:      ${_YELLOW}$CONTROL_CLIENT off${_RESET}"
    echo "Auto mode:           ${_YELLOW}$CONTROL_CLIENT auto${_RESET}"
    echo "Request status:      ${_YELLOW}$CONTROL_CLIENT status${_RESET}"
    echo "Monitor data:        ${_YELLOW}$CONTROL_CLIENT monitor${_RESET}"
    echo "Listen to status:    ${_YELLOW}$CONTROL_CLIENT listen${_RESET}"
    echo
    echo "${_CYAN}=== MQTT Topics ===${_RESET}"
    echo "Data topic:          ${_YELLOW}$MQTT_TOPIC${_RESET} ${_BLUE}(only when distance < 5.0m or manual mode)${_RESET}"
    echo "Control topic:       ${_YELLOW}$MQTT_TOPIC/control${_RESET}"
    echo "Status topic:        ${_YELLOW}$MQTT_TOPIC/status${_RESET}"
    echo
    echo "${_CYAN}=== Configuration Files ===${_RESET}"
    echo "Startup script:      ${_YELLOW}$START_SCRIPT${_RESET}"
    echo "Control client:      ${_YELLOW}$CONTROL_CLIENT${_RESET}"
    echo "Service file:        ${_YELLOW}$SERVICE_FILE${_RESET}"
    echo "MQTT config:         ${_YELLOW}${SCRIPT_DIR}/mqtt_service.sh${_RESET}"
    echo
    echo "${_CYAN}=== Quick Test Commands ===${_RESET}"
    echo "Test relay control:  ${_YELLOW}$CONTROL_CLIENT on && sleep 3 && $CONTROL_CLIENT off${_RESET}"
    echo "Monitor in real-time:${_YELLOW}$CONTROL_CLIENT monitor${_RESET}"
    echo
}

# Main function
main() {
    log_info "Enhanced Maxbotic Ultrasonic Sensor service setup with remote control started"
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
    
    log_success "Enhanced Maxbotic Ultrasonic service with remote control setup completed successfully!"
    show_usage_info
}

# Run main function
main "$@"