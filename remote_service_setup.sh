#!/bin/bash

# Remote Control Service Setup Script
# Creates systemd service for remote.sh to run in background

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
readonly SERVICE_NAME="ultrasonic_remote"
readonly SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
readonly START_SCRIPT="/home/pi/startRemote.sh"
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
    
    exit 1
}

trap 'cleanup_on_error $LINENO' ERR

# Dependency check
check_dependencies() {
    local dependencies=("mosquitto_sub" "mosquitto_pub" "mbpoll" "systemctl")
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

# Create startup script
create_startup_script() {
    log_info "Creating remote control startup script"
    
    # Create the startup script
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

# Configuration
readonly OVERRIDE_FLAG="/tmp/relay_manual_override"

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
EOF

    # Set proper permissions
    sudo chmod 755 "$START_SCRIPT"
    log_success "Startup script created at $START_SCRIPT"
}

# Create systemd service
create_systemd_service() {
    log_info "Creating systemd service: $SERVICE_NAME"
    
    sudo tee "$SERVICE_FILE" > /dev/null << EOF
[Unit]
Description=Ultrasonic Remote Control Service
Documentation=man:ultrasonic-remote(1)
After=network.target mosquitto.service
Wants=mosquitto.service

[Service]
Type=simple
ExecStart=$START_SCRIPT
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10
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
    echo "${_CYAN}=== Remote Control Service Management ===${_RESET}"
    echo "View logs:           ${_YELLOW}sudo journalctl -u $SERVICE_NAME -f${_RESET}"
    echo "Service status:      ${_YELLOW}sudo systemctl status $SERVICE_NAME${_RESET}"
    echo "Start service:       ${_YELLOW}sudo systemctl start $SERVICE_NAME${_RESET}"
    echo "Stop service:        ${_YELLOW}sudo systemctl stop $SERVICE_NAME${_RESET}"
    echo "Restart service:     ${_YELLOW}sudo systemctl restart $SERVICE_NAME${_RESET}"
    echo "Disable service:     ${_YELLOW}sudo systemctl disable $SERVICE_NAME${_RESET}"
    echo
    echo "${_CYAN}=== MQTT Control Commands ===${_RESET}"
    echo "Turn relay ON:       ${_YELLOW}mosquitto_pub -h $MQTT_BROKER -p $MQTT_PORT -t \"${MQTT_TOPIC}/control\" -m \"on\"${_RESET}"
    echo "Turn relay OFF:      ${_YELLOW}mosquitto_pub -h $MQTT_BROKER -p $MQTT_PORT -t \"${MQTT_TOPIC}/control\" -m \"off\"${_RESET}"
    echo "Auto mode:           ${_YELLOW}mosquitto_pub -h $MQTT_BROKER -p $MQTT_PORT -t \"${MQTT_TOPIC}/control\" -m \"auto\"${_RESET}"
    echo "Status request:      ${_YELLOW}mosquitto_pub -h $MQTT_BROKER -p $MQTT_PORT -t \"${MQTT_TOPIC}/control\" -m \"status\"${_RESET}"
    echo
    echo "${_CYAN}=== Configuration Files ===${_RESET}"
    echo "Startup script:      ${_YELLOW}$START_SCRIPT${_RESET}"
    echo "Service file:        ${_YELLOW}$SERVICE_FILE${_RESET}"
    echo "MQTT config:         ${_YELLOW}${SCRIPT_DIR}/mqtt_service.sh${_RESET}"
    echo "Override flag:       ${_YELLOW}/tmp/relay_manual_override${_RESET}"
    echo
}

# Main function
main() {
    log_info "Remote control service setup started"
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
    
    log_success "Remote control service setup completed successfully!"
    show_usage_info
}

# Run main function
main "$@"