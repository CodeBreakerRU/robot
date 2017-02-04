#!/bin/bash

# Run as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root" 
   exit 1
fi

# Create user 'blackbox' with disabled login if not exists
if id "blackbox" &>/dev/null; then
    echo "User blackbox already exists"
else
    useradd -m -s /usr/sbin/nologin blackbox
    echo "User blackbox created with disabled login"
fi

# Variables
USER_HOME="/home/blackbox"
BLACKBOX_DIR="$USER_HOME/blackbox"
BLACKBOX_EXPORTER_URL="https://github.com/prometheus/blackbox_exporter/releases/download/v0.27.0/blackbox_exporter-0.27.0.linux-amd64.tar.gz"
TMP_DIR="/tmp/blackbox_tmp"
SERVICE_FILE="/etc/systemd/system/blackbox.service"

# Create temp directory
mkdir -p $TMP_DIR

# Download latest blackbox exporter tar.gz
echo "Downloading Blackbox exporter..."
curl -L $BLACKBOX_EXPORTER_URL -o $TMP_DIR/blackbox_exporter.tar.gz

# Create destination directory
mkdir -p $BLACKBOX_DIR

# Extract tarball to blackbox directory
tar -xzf $TMP_DIR/blackbox_exporter.tar.gz -C $TMP_DIR
EXTRACTED_DIR=$(find $TMP_DIR -maxdepth 1 -type d -name "blackbox_exporter-*")
mv $EXTRACTED_DIR/* $BLACKBOX_DIR

# Change ownership
chown -R blackbox:blackbox $BLACKBOX_DIR

# Clean up
rm -rf $TMP_DIR

echo "Blackbox exporter installed to $BLACKBOX_DIR"

# Create systemd service file
echo "Creating systemd service file..."
cat > $SERVICE_FILE <<EOF
[Unit]
Description=Blackbox Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=blackbox
Group=blackbox
Type=simple
ExecStart=$BLACKBOX_DIR/blackbox_exporter --web.listen-address=:9115
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd daemon, enable and start service
systemctl daemon-reload
systemctl enable blackbox.service
systemctl start blackbox.service

# Show service status
systemctl status blackbox.service --no-pager