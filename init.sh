#!/bin/bash
# Colors
_RED=`tput setaf 1`
_GREEN=`tput setaf 2`
_YELLOW=`tput setaf 3`
_BLUE=`tput setaf 4`
_MAGENTA=`tput setaf 5`
_CYAN=`tput setaf 6`
_RESET=`tput sgr0`
# printing greetings

echo "${_MAGENTA}Installation Progress....setup for for Dragino GPS data acquisition protocol :: started${_RESET}"
echo
sleep 5
chmod +x primary.sh
chmod +x mqtt_service.sh
echo "${_MAGENTA}Installation Progress....set local time to Kuala Lumpur${_RESET}"
echo
sudo timedatectl set-timezone Asia/Kuala_Lumpur
# Installation of Python Dependencies and GPS Libaries
echo "${_MAGENTA}Installation Progress...installation of Mosquitto and Mosquitto-Clients${_RESET}"
echo
sudo apt install mosquitto mosquitto-clients -y
sudo systemctl enable mosquitto

sleep 5
echo "${_MAGENTA}Installation Progress....installation of Mosquitto and Mosquitto-Clients${_RESET}"
echo
. primary.sh