#!/bin/bash

# Ensure an IP address is provided when running the script
if [ -z "$1" ]; then
    echo "Error: No IP address provided."
    echo "Usage: ./connect.sh <IP_ADDRESS>"
    echo "Example: ./connect.sh 192.168.1.160"
    exit 1
fi

TARGET_IP=$1
TARGET_PORT="5555"
FULL_ADDRESS="$TARGET_IP:$TARGET_PORT"

echo "--- Connecting to $TARGET_IP ---"

# 1. Setup USB Devices (Initial Pairing)
# Finds physical USB devices and enables TCP/IP. 
# Targeting specific serials prevents disruption to existing Wi-Fi connections.
USB_DEVICES=$(adb devices | awk 'NR>1 {print $1}' | grep -v ":" | grep -v "^$")

if [[ -n "$USB_DEVICES" ]]; then
    for SERIAL in $USB_DEVICES; do
        adb -s "$SERIAL" tcpip "$TARGET_PORT" > /dev/null 2>&1
    done
    sleep 2
fi

# 2. Check and Connect the Specific IP
CURRENT_DEVICES=$(adb devices)

if echo "$CURRENT_DEVICES" | grep -q "$FULL_ADDRESS.*device"; then
    echo "[Status] $TARGET_IP is already connected and active."
elif echo "$CURRENT_DEVICES" | grep -q "$FULL_ADDRESS.*offline"; then
    echo "[Status] $TARGET_IP is offline. Resetting connection..."
    adb disconnect "$FULL_ADDRESS" > /dev/null 2>&1
    adb connect "$FULL_ADDRESS"
else
    echo "[Status] Initiating new connection..."
    adb connect "$FULL_ADDRESS"
fi

# 3. Verify
echo -e "\n--- Current Active Devices ---"
adb devices