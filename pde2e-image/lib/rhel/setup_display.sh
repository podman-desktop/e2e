#!/bin/bash

username=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --username) username="$2"; shift ;;
        *) ;;
    esac
    shift
done

username="${username:-$(whoami)}"
uid=$(id -u "$username" 2>/dev/null || id -u)

echo "Setting up headless GNOME session for user: $username (uid=$uid)"

sudo dnf install -y gnome-shell

sudo loginctl enable-linger "$username"
sleep 2

echo "Starting mutter --headless..."
sudo -u "$username" \
    XDG_RUNTIME_DIR="/run/user/$uid" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
    mutter --headless --virtual-monitor 1920x1080 --wayland > /dev/null 2>&1 &
echo "Started mutter (pid=$!)"

for i in $(seq 1 30); do
    [[ -S "/run/user/$uid/wayland-0" ]] && { echo "Headless GNOME session is up (wayland-0 found)"; exit 0; }
    echo "Waiting for wayland-0... $i/30"
    sleep 2
done

echo "ERROR: wayland-0 not found after 60s"
sudo -u "$username" \
    XDG_RUNTIME_DIR="/run/user/$uid" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
    journalctl --user -t mutter --no-pager -n 50 2>/dev/null || true
exit 1
