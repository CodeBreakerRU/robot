#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Function to handle errors with detailed messages
error_exit() {
    local error_message="$1"
    local line_number="$2"
    echo "ERROR: $error_message (Line: $line_number)"
    echo "Script execution stopped due to error."
    exit 1
}

# Trap errors and call error_exit function
trap 'error_exit "Command failed" $LINENO' ERR

echo "Starting Node Exporter installation..."

# Check if running as root
echo "Checking root privileges..."
if [[ $EUID -ne 0 ]]; then
   error_exit "This script must be run as root. Please run with sudo or as root user" $LINENO
fi
echo "✓ Root privileges confirmed"

# Variables
USER_HOME="/home/node-exporter"
NODE_EXPORTER_DIR="$USER_HOME/node-exporter"
NODE_EXPORTER_URL="https://github.com/prometheus/node_exporter/releases/download/v1.9.1/node_exporter-1.9.1.linux-amd64.tar.gz"
TMP_DIR="/tmp/node-exporter_tmp"
SERVICE_FILE="/etc/systemd/system/node-exporter.service"

# Check if required commands exist
echo "Checking required commands..."
for cmd in curl tar systemctl useradd chown lsof; do
    if ! command -v "$cmd" &> /dev/null; then
        error_exit "Required command '$cmd' not found. Please install it first" $LINENO
    fi
done
echo "✓ All required commands are available"

# Create user 'node-exporter' with disabled login if not exists
echo "Checking/creating node-exporter user..."
if id "node-exporter" &>/dev/null; then
    echo "✓ User node-exporter already exists"
else
    if ! useradd -m -s /usr/sbin/nologin node-exporter; then
        error_exit "Failed to create user 'node-exporter'. Check if useradd command has proper permissions" $LINENO
    fi
    echo "✓ User node-exporter created with disabled login"
fi

# Create temp directory
echo "Creating temporary directory..."
if ! mkdir -p "$TMP_DIR"; then
    error_exit "Failed to create temporary directory: $TMP_DIR" $LINENO
fi
echo "✓ Temporary directory created: $TMP_DIR"

# Download node-exporter
echo "Downloading Node Exporter..."
if ! curl -L "$NODE_EXPORTER_URL" -o "$TMP_DIR/node_exporter.tar.gz"; then
    error_exit "Failed to download Node Exporter from: $NODE_EXPORTER_URL. Check internet connection and URL validity" $LINENO
fi

# Verify download
if [[ ! -f "$TMP_DIR/node_exporter.tar.gz" ]] || [[ ! -s "$TMP_DIR/node_exporter.tar.gz" ]]; then
    error_exit "Downloaded file is missing or empty: $TMP_DIR/node_exporter.tar.gz" $LINENO
fi
echo "✓ Node Exporter downloaded successfully"

# Create destination directory
echo "Creating destination directory..."
if ! mkdir -p "$NODE_EXPORTER_DIR"; then
    error_exit "Failed to create destination directory: $NODE_EXPORTER_DIR" $LINENO
fi
echo "✓ Destination directory created: $NODE_EXPORTER_DIR"

# Extract tarball
echo "Extracting Node Exporter..."
if ! tar -xzf "$TMP_DIR/node_exporter.tar.gz" -C "$TMP_DIR"; then
    error_exit "Failed to extract tarball: $TMP_DIR/node_exporter.tar.gz. File may be corrupted" $LINENO
fi

# Find extracted directory
EXTRACTED_DIR=$(find "$TMP_DIR" -maxdepth 1 -type d -name "node_exporter-*" | head -n 1)
if [[ -z "$EXTRACTED_DIR" ]]; then
    error_exit "Could not find extracted Node Exporter directory in $TMP_DIR" $LINENO
fi
echo "✓ Found extracted directory: $EXTRACTED_DIR"

# Move files to destination
echo "Moving Node Exporter files..."
if ! mv "$EXTRACTED_DIR"/* "$NODE_EXPORTER_DIR"/; then
    error_exit "Failed to move files from $EXTRACTED_DIR to $NODE_EXPORTER_DIR" $LINENO
fi

# Verify node_exporter binary exists and is executable
if [[ ! -f "$NODE_EXPORTER_DIR/node_exporter" ]]; then
    error_exit "Node Exporter binary not found at: $NODE_EXPORTER_DIR/node_exporter" $LINENO
fi

if ! chmod +x "$NODE_EXPORTER_DIR/node_exporter"; then
    error_exit "Failed to make node_exporter binary executable" $LINENO
fi
echo "✓ Node Exporter files moved and made executable"

# Change ownership
echo "Setting file ownership..."
if ! chown -R node-exporter:node-exporter "$NODE_EXPORTER_DIR"; then
    error_exit "Failed to change ownership of $NODE_EXPORTER_DIR to node-exporter user" $LINENO
fi
echo "✓ File ownership set to node-exporter user"

# Clean up temporary files
echo "Cleaning up temporary files..."
if ! rm -rf "$TMP_DIR"; then
    echo "Warning: Failed to remove temporary directory: $TMP_DIR"
fi
echo "✓ Temporary files cleaned up"

echo "✓ Node Exporter installed to $NODE_EXPORTER_DIR"

# Create systemd service file
echo "Creating systemd service file..."
if ! cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Node Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=node-exporter
Group=node-exporter
Type=simple
ExecStart=$NODE_EXPORTER_DIR/node_exporter
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
then
    error_exit "Failed to create systemd service file: $SERVICE_FILE" $LINENO
fi
echo "✓ Systemd service file created"

# Reload systemd daemon
echo "Reloading systemd daemon..."
if ! systemctl daemon-reload; then
    error_exit "Failed to reload systemd daemon. Check systemctl permissions" $LINENO
fi
echo "✓ Systemd daemon reloaded"

# Enable service
echo "Enabling node-exporter service..."
if ! systemctl enable node-exporter.service; then
    error_exit "Failed to enable node-exporter service" $LINENO
fi
echo "✓ Node-exporter service enabled"

# Start service
echo "Starting node-exporter service..."
if ! systemctl start node-exporter.service; then
    error_exit "Failed to start node-exporter service. Check service configuration and logs with: journalctl -u node-exporter.service" $LINENO
fi
echo "✓ Node-exporter service started"

# Give service a moment to start
sleep 2

# Check if service is running
echo "Checking service status..."
if ! systemctl is-active --quiet node-exporter.service; then
    error_exit "Node-exporter service is not running. Check logs with: journalctl -u node-exporter.service" $LINENO
fi
echo "✓ Node-exporter service is running"

# Show service status
echo "Service status:"
systemctl status node-exporter.service --no-pager || {
    echo "Warning: Could not display service status, but service appears to be running"
}

# Show listening port (Node Exporter default port is 9100, not 9111)
echo "Checking listening ports..."
if command -v lsof &> /dev/null; then
    echo "Ports being listened on by node_exporter:"
    lsof -i :9100 || echo "Note: Node Exporter typically runs on port 9100"
else
    echo "lsof not available, cannot check listening ports"
fi

echo ""
echo "🎉 Node Exporter installation completed successfully!"
echo "   - Service: node-exporter.service"
echo "   - Status: systemctl status node-exporter.service"
echo "   - Logs: journalctl -u node-exporter.service"
echo "   - Default port: 9100"
echo "   - Test URL: http://localhost:9100/metrics"