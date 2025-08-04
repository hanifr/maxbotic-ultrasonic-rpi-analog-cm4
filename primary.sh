#!/bin/bash

# Define terminal colors
_RED=$(tput setaf 1)
_GREEN=$(tput setaf 2)
_YELLOW=$(tput setaf 3)
_BLUE=$(tput setaf 4)
_MAGENTA=$(tput setaf 5)
_CYAN=$(tput setaf 6)
_RESET=$(tput sgr0)

# Source external script if exists
source mqtt_service.sh

# Inform the user about the start of service setup
echo "${_MAGENTA}Setup Progress: Creating Maxbotic Ultrasonic startup service... [STARTED]${_RESET}"
echo

# Create the startUltrasonic.sh script
sudo tee /home/pi/startUltrasonic.sh > /dev/null << 'EOF'
#!/bin/bash

# Load MQTT configurations
source /home/pi/mqtt_service.sh

SENSOR_DIR="/sys/bus/iio/devices/iio:device0"
OUTPUT_FILE="/home/pi/ultrasonic.txt"

# Continuous measurement loop every 2 seconds
while true
do
    if RAW_VALUE=$(cat "$SENSOR_DIR/in_voltage1_raw"); then
        ULTRASONIC_DISTANCE=$(echo "scale=3; ($RAW_VALUE * 10) / 1303" | bc)

        # Save data locally
        echo "$ULTRASONIC_DISTANCE" > "$OUTPUT_FILE"

        # Publish to MQTT broker
        mosquitto_pub -h "$MQTT_BROKER" \
                      -p "$MQTT_PORT" \
                      -t "$MQTT_TOPIC" \
                      -i "$MQTT_CLIENT_ID" \
                      -m "$ULTRASONIC_DISTANCE"

        # Terminal output for debugging
        echo "Ultrasonic Data: $ULTRASONIC_DISTANCE m (published via MQTT)"
    else
        echo "Error reading ultrasonic sensor data" >&2
    fi

    sleep 2
done


EOF

# Set proper permissions
sudo chmod 755 /home/pi/startUltrasonic.sh

# Create systemd service file for Maxbotic Ultrasonic
sudo tee /etc/systemd/system/maxbotic_ultrasonic.service > /dev/null << 'EOF'
[Unit]
Description=Maxbotic Ultrasonic Sensor Service
After=network.target

[Service]
Type=simple
ExecStart=/home/pi/startUltrasonic.sh
Restart=on-failure
User=pi

[Install]
WantedBy=multi-user.target
EOF

# Inform user about service activation steps
echo "${_YELLOW}[+] Starting and enabling maxbotic_ultrasonic systemd service...${_RESET}"

# Set correct permissions for the service file
sudo chmod 644 /etc/systemd/system/maxbotic_ultrasonic.service

# Reload systemd, enable and start the service
sudo systemctl daemon-reload
sudo systemctl enable --now maxbotic_ultrasonic.service

echo "${_GREEN}[✔] Maxbotic Ultrasonic service setup successfully completed.${_RESET}"
echo
echo "${_YELLOW}To view the service logs, run:${_RESET} ${_CYAN}sudo journalctl -u maxbotic_ultrasonic -f${_RESET}"
echo
echo "${_MAGENTA}Setup Progress: Creating Maxbotic Ultrasonic startup service... [COMPLETED]${_RESET}"
echo
sleep 5

echo "${_MAGENTA}If you need to restart the Maxbotic Ultrasonic service using the provided daemon script, please run:${_RESET} ${_CYAN}./loraControl.sh${_RESET}"
echo