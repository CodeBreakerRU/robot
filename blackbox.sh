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

echo "Starting Blackbox Exporter installation..."

# Check if running as root
echo "Checking root privileges..."
if [[ $EUID -ne 0 ]]; then
   error_exit "This script must be run as root. Please run with sudo or as root user" $LINENO
fi
echo "✓ Root privileges confirmed"

# Variables
USER_HOME="/home/blackbox"
BLACKBOX_DIR="$USER_HOME/blackbox"
BLACKBOX_EXPORTER_URL="https://github.com/prometheus/blackbox_exporter/releases/download/v0.27.0/blackbox_exporter-0.27.0.linux-amd64.tar.gz"
TMP_DIR="/tmp/blackbox_tmp"
SERVICE_FILE="/etc/systemd/system/blackbox.service"
CONFIG_FILE="$BLACKBOX_DIR/blackbox.yml"

# Check if required commands exist
echo "Checking required commands..."
for cmd in curl tar systemctl useradd chown; do
    if ! command -v "$cmd" &> /dev/null; then
        error_exit "Required command '$cmd' not found. Please install it first" $LINENO
    fi
done
echo "✓ All required commands are available"

# Create user 'blackbox' with disabled login if not exists
echo "Checking/creating blackbox user..."
if id "blackbox" &>/dev/null; then
    echo "✓ User blackbox already exists"
else
    if ! useradd -m -s /usr/sbin/nologin blackbox; then
        error_exit "Failed to create user 'blackbox'. Check if useradd command has proper permissions" $LINENO
    fi
    echo "✓ User blackbox created with disabled login"
fi

# Create temp directory
echo "Creating temporary directory..."
if ! mkdir -p "$TMP_DIR"; then
    error_exit "Failed to create temporary directory: $TMP_DIR" $LINENO
fi
echo "✓ Temporary directory created: $TMP_DIR"

# Download blackbox exporter
echo "Downloading Blackbox Exporter..."
if ! curl -L "$BLACKBOX_EXPORTER_URL" -o "$TMP_DIR/blackbox_exporter.tar.gz"; then
    error_exit "Failed to download Blackbox Exporter from: $BLACKBOX_EXPORTER_URL. Check internet connection and URL validity" $LINENO
fi

# Verify download
if [[ ! -f "$TMP_DIR/blackbox_exporter.tar.gz" ]] || [[ ! -s "$TMP_DIR/blackbox_exporter.tar.gz" ]]; then
    error_exit "Downloaded file is missing or empty: $TMP_DIR/blackbox_exporter.tar.gz" $LINENO
fi
echo "✓ Blackbox Exporter downloaded successfully"

# Create destination directory
echo "Creating destination directory..."
if ! mkdir -p "$BLACKBOX_DIR"; then
    error_exit "Failed to create destination directory: $BLACKBOX_DIR" $LINENO
fi
echo "✓ Destination directory created: $BLACKBOX_DIR"

# Extract tarball
echo "Extracting Blackbox Exporter..."
if ! tar -xzf "$TMP_DIR/blackbox_exporter.tar.gz" -C "$TMP_DIR"; then
    error_exit "Failed to extract tarball: $TMP_DIR/blackbox_exporter.tar.gz. File may be corrupted" $LINENO
fi

# Find extracted directory
EXTRACTED_DIR=$(find "$TMP_DIR" -maxdepth 1 -type d -name "blackbox_exporter-*" | head -n 1)
if [[ -z "$EXTRACTED_DIR" ]]; then
    error_exit "Could not find extracted Blackbox Exporter directory in $TMP_DIR" $LINENO
fi
echo "✓ Found extracted directory: $EXTRACTED_DIR"

# Move files to destination
echo "Moving Blackbox Exporter files..."
if ! mv "$EXTRACTED_DIR"/* "$BLACKBOX_DIR"/; then
    error_exit "Failed to move files from $EXTRACTED_DIR to $BLACKBOX_DIR" $LINENO
fi

# Verify blackbox_exporter binary exists and is executable
if [[ ! -f "$BLACKBOX_DIR/blackbox_exporter" ]]; then
    error_exit "Blackbox Exporter binary not found at: $BLACKBOX_DIR/blackbox_exporter" $LINENO
fi

if ! chmod +x "$BLACKBOX_DIR/blackbox_exporter"; then
    error_exit "Failed to make blackbox_exporter binary executable" $LINENO
fi
echo "✓ Blackbox Exporter files moved and made executable"

# Verify configuration file exists
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Warning: Configuration file not found at $CONFIG_FILE"
    echo "Creating basic configuration file..."
    if ! cat > "$CONFIG_FILE" <<EOF
modules:
  http_2xx:
    prober: http
    http:
      valid_http_versions: ["HTTP/1.1", "HTTP/2.0"]
      valid_status_codes: []
      method: GET
      follow_redirects: true
  http_post_2xx:
    prober: http
    http:
      method: POST
  tcp_connect:
    prober: tcp
  ping:
    prober: icmp
EOF
    then
        error_exit "Failed to create basic configuration file: $CONFIG_FILE" $LINENO
    fi
    echo "✓ Basic configuration file created"
else
    echo "✓ Configuration file already exists: $CONFIG_FILE"
fi

# Change ownership
echo "Setting file ownership..."
if ! chown -R blackbox:blackbox "$BLACKBOX_DIR"; then
    error_exit "Failed to change ownership of $BLACKBOX_DIR to blackbox user" $LINENO
fi
echo "✓ File ownership set to blackbox user"

# Clean up temporary files
echo "Cleaning up temporary files..."
if ! rm -rf "$TMP_DIR"; then
    echo "Warning: Failed to remove temporary directory: $TMP_DIR"
fi
echo "✓ Temporary files cleaned up"

echo "✓ Blackbox Exporter installed to $BLACKBOX_DIR"

# Create systemd service file
echo "Creating systemd service file..."
if ! cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Blackbox Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=blackbox
Group=blackbox
Type=simple
ExecStart=$BLACKBOX_DIR/blackbox_exporter --config.file=$CONFIG_FILE --web.listen-address=:9115
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
echo "Enabling blackbox service..."
if ! systemctl enable blackbox.service; then
    error_exit "Failed to enable blackbox service" $LINENO
fi
echo "✓ Blackbox service enabled"

# Start service
echo "Starting blackbox service..."
if ! systemctl start blackbox.service; then
    error_exit "Failed to start blackbox service. Check service configuration and logs with: journalctl -u blackbox.service" $LINENO
fi
echo "✓ Blackbox service started"

# Give service a moment to start
sleep 2

# Check if service is running
echo "Checking service status..."
if ! systemctl is-active --quiet blackbox.service; then
    error_exit "Blackbox service is not running. Check logs with: journalctl -u blackbox.service" $LINENO
fi
echo "✓ Blackbox service is running"

# Show service status
echo "Service status:"
systemctl status blackbox.service --no-pager || {
    echo "Warning: Could not display service status, but service appears to be running"
}

# Check listening port
echo "Checking listening ports..."
if command -v lsof &> /dev/null; then
    echo "Checking if Blackbox Exporter is listening on port 9115:"
    if lsof -i :9115; then
        echo "✓ Blackbox Exporter is listening on port 9115"
    else
        echo "Warning: Port 9115 doesn't appear to be in use yet (service may still be starting)"
    fi
elif command -v netstat &> /dev/null; then
    echo "Checking listening ports with netstat:"
    netstat -tlnp | grep :9115 || echo "Warning: Port 9115 not found in netstat output"
elif command -v ss &> /dev/null; then
    echo "Checking listening ports with ss:"
    ss -tlnp | grep :9115 || echo "Warning: Port 9115 not found in ss output"
else
    echo "Warning: No port checking tools available (lsof, netstat, ss)"
fi

echo ""
echo "🎉 Blackbox Exporter installation completed successfully!"
echo "   - Service: blackbox.service"
echo "   - Status: systemctl status blackbox.service"
echo "   - Logs: journalctl -u blackbox.service"
echo "   - Port: 9115"
echo "   - Test URL: http://localhost:9115"
echo "   - Metrics: http://localhost:9115/metrics"
echo "   - Configuration: $CONFIG_FILE"
echo ""
echo "Example probe URL:"
echo "   http://localhost:9115/probe?module=http_2xx&target=https://yahoo.com"