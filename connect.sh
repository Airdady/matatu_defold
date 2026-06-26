#!/bin/bash

# Configuration
# TARGET_IP="10.51.116.223"
TARGET_IP="192.168.1.150"
TARGET_PORT="5555"

echo "--- Preparing remote connection for $TARGET_IP ---"

# 1. Attempt to switch connected USB device to TCP mode
# This only works if a device is currently connected via USB
USB_DEVICE=$(adb devices | grep -v "list" | grep -v "$TARGET_IP" | grep "device")

if [[ -n "$USB_DEVICE" ]]; then
    echo "USB device detected. Switching to TCP/IP mode..."
    adb tcpip $TARGET_PORT
    sleep 2 # Wait for the device to restart its ADB daemon
else
    echo "No USB device detected. Skipping 'adb tcpip' setup."
fi

# 2. Proceed to remote connection
echo "Connecting to $TARGET_IP:$TARGET_PORT..."
adb connect $TARGET_IP:$TARGET_PORT

# 3. Verify and Launch
if adb -s $TARGET_IP:$TARGET_PORT shell true 2>/dev/null; then
    echo "Successfully connected to $TARGET_IP."
    echo "Launching remote shell..."
    adb -s $TARGET_IP:$TARGET_PORT shell
else
    echo "ERROR: Could not connect to $TARGET_IP."
    echo "Ensure the device is on the network and 'adb tcpip 5555' was previously enabled."
    exit 1
fi