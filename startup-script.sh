#!/bin/bash

# Startup Script untuk EMQTT-Bench di GCP Instance Template
# Script ini membaca metadata untuk menentukan mode testing
# Mode: conn, pub, sub, atau pubsub

set -e

# Log semua output
exec > >(tee -a /var/log/emqtt-bench-startup.log)
exec 2>&1

echo "=== EMQTT-Bench Startup Script ==="
echo "Timestamp: $(date)"
echo "Hostname: $(hostname)"

# Fungsi untuk mendapatkan metadata GCP
get_metadata() {
    curl -s -f "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1" \
         -H "Metadata-Flavor: Google" 2>/dev/null || echo ""
}

# Baca konfigurasi dari metadata
TEST_MODE=$(get_metadata "test-mode")              # conn, pub, sub, pubsub
BROKER_HOST=$(get_metadata "broker-host")          # MQTT broker host
BROKER_PORT=$(get_metadata "broker-port")          # MQTT broker port (default: 1883)
CLIENT_COUNT=$(get_metadata "client-count")        # Jumlah client
QOS=$(get_metadata "qos")                          # QoS level (0, 1, 2)
TOPIC=$(get_metadata "topic")                      # MQTT topic
MESSAGE_SIZE=$(get_metadata "message-size")        # Ukuran pesan dalam bytes
MESSAGE_COUNT=$(get_metadata "message-count")      # Jumlah pesan per client
INTERVAL=$(get_metadata "interval")                # Interval antar pesan (ms)
USERNAME=$(get_metadata "mqtt-username")           # MQTT username
PASSWORD=$(get_metadata "mqtt-password")           # MQTT password
KEEPALIVE=$(get_metadata "keepalive")              # Keepalive interval
AUTO_START=$(get_metadata "auto-start")            # Auto start test (true/false)

# Set default values
TEST_MODE=${TEST_MODE:-pub}
BROKER_HOST=${BROKER_HOST:-localhost}
BROKER_PORT=${BROKER_PORT:-1883}
CLIENT_COUNT=${CLIENT_COUNT:-100}
QOS=${QOS:-1}
TOPIC=${TOPIC:-bench/%i}
MESSAGE_SIZE=${MESSAGE_SIZE:-256}
MESSAGE_COUNT=${MESSAGE_COUNT:-1000}
INTERVAL=${INTERVAL:-10}
KEEPALIVE=${KEEPALIVE:-300}
AUTO_START=${AUTO_START:-false}

echo "Configuration:"
echo "  TEST_MODE: $TEST_MODE"
echo "  BROKER: $BROKER_HOST:$BROKER_PORT"
echo "  CLIENTS: $CLIENT_COUNT"
echo "  QOS: $QOS"
echo "  TOPIC: $TOPIC"
echo "  AUTO_START: $AUTO_START"

# Update system
echo "Updating system packages..."
apt-get update -qq
apt-get install -y wget git build-essential curl jq

# Install Erlang/OTP
echo "Installing Erlang/OTP..."
if ! command -v erl &> /dev/null; then
    wget -q https://packages.erlang-solutions.com/erlang-solutions_2.0_all.deb
    dpkg -i erlang-solutions_2.0_all.deb
    apt-get update -qq
    apt-get install -y erlang
    rm erlang-solutions_2.0_all.deb
fi

# Install Rebar3
echo "Installing Rebar3..."
if ! command -v rebar3 &> /dev/null; then
    cd /opt
    wget -q https://s3.amazonaws.com/rebar3/rebar3
    chmod +x rebar3
    mv rebar3 /usr/local/bin/
fi

# Clone and build emqtt-bench
echo "Building emqtt-bench..."
if [ ! -d "/opt/emqtt-bench" ]; then
    cd /opt
    git clone -q https://github.com/emqx/emqtt-bench.git
    cd emqtt-bench
    make
    ln -sf /opt/emqtt-bench/_build/default/bin/emqtt_bench /usr/local/bin/emqtt_bench
fi

# Create working directory
mkdir -p /opt/emqtt-bench-runner
cd /opt/emqtt-bench-runner

# Build command options
CMD_BASE="emqtt_bench"
CMD_OPTS="-h $BROKER_HOST -p $BROKER_PORT -c $CLIENT_COUNT -q $QOS -k $KEEPALIVE"

if [ -n "$USERNAME" ]; then
    CMD_OPTS="$CMD_OPTS -u $USERNAME"
fi

if [ -n "$PASSWORD" ]; then
    CMD_OPTS="$CMD_OPTS -P $PASSWORD"
fi

# Create run script based on test mode
cat > /opt/emqtt-bench-runner/run-test.sh << EOF
#!/bin/bash

LOG_DIR="/var/log/emqtt-bench-tests"
mkdir -p \$LOG_DIR

TIMESTAMP=\$(date +%Y%m%d_%H%M%S)
HOSTNAME=\$(hostname)

echo "=== Starting EMQTT-Bench Test ==="
echo "Mode: $TEST_MODE"
echo "Broker: $BROKER_HOST:$BROKER_PORT"
echo "Clients: $CLIENT_COUNT"
echo "Timestamp: \$TIMESTAMP"
echo "Hostname: \$HOSTNAME"

case "$TEST_MODE" in
    conn)
        echo "Running CONNECTION test..."
        $CMD_BASE conn $CMD_OPTS -i $INTERVAL \\
            2>&1 | tee \$LOG_DIR/conn_\${HOSTNAME}_\${TIMESTAMP}.log
        ;;
    
    pub)
        echo "Running PUBLISH test..."
        $CMD_BASE pub $CMD_OPTS \\
            -t "$TOPIC" \\
            -s $MESSAGE_SIZE \\
            -C $MESSAGE_COUNT \\
            -I $INTERVAL \\
            2>&1 | tee \$LOG_DIR/pub_\${HOSTNAME}_\${TIMESTAMP}.log
        ;;
    
    sub)
        echo "Running SUBSCRIBE test..."
        $CMD_BASE sub $CMD_OPTS \\
            -t "$TOPIC" \\
            2>&1 | tee \$LOG_DIR/sub_\${HOSTNAME}_\${TIMESTAMP}.log
        ;;
    
    pubsub)
        echo "Running PUBLISH+SUBSCRIBE test..."
        
        # Start subscribers first
        $CMD_BASE sub $CMD_OPTS \\
            -t "$TOPIC" \\
            2>&1 | tee \$LOG_DIR/sub_\${HOSTNAME}_\${TIMESTAMP}.log &
        
        SUB_PID=\$!
        echo "Subscribers started (PID: \$SUB_PID), waiting 10 seconds..."
        sleep 10
        
        # Start publishers
        $CMD_BASE pub $CMD_OPTS \\
            -t "$TOPIC" \\
            -s $MESSAGE_SIZE \\
            -C $MESSAGE_COUNT \\
            -I $INTERVAL \\
            2>&1 | tee \$LOG_DIR/pub_\${HOSTNAME}_\${TIMESTAMP}.log
        
        echo "Publishers completed, stopping subscribers..."
        sleep 5
        kill \$SUB_PID 2>/dev/null
        ;;
    
    *)
        echo "ERROR: Invalid test mode: $TEST_MODE"
        echo "Valid modes: conn, pub, sub, pubsub"
        exit 1
        ;;
esac

echo "=== Test completed ==="
echo "End time: \$(date)"
echo "Logs: \$LOG_DIR"

# Report to metadata (optional - untuk monitoring)
curl -X PUT --data "completed" \\
    "http://metadata.google.internal/computeMetadata/v1/instance/guest-attributes/emqtt-bench/status" \\
    -H "Metadata-Flavor: Google" 2>/dev/null || true
EOF

chmod +x /opt/emqtt-bench-runner/run-test.sh

# Create systemd service
cat > /etc/systemd/system/emqtt-bench.service << EOF
[Unit]
Description=EMQTT Bench Test Service
After=network.target

[Service]
Type=oneshot
User=root
WorkingDirectory=/opt/emqtt-bench-runner
ExecStart=/opt/emqtt-bench-runner/run-test.sh
StandardOutput=journal
StandardError=journal
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

# Create info file
cat > /opt/emqtt-bench-runner/INFO.txt << EOF
=== EMQTT-Bench Runner Configuration ===

Instance: $(hostname)
Test Mode: $TEST_MODE
Broker: $BROKER_HOST:$BROKER_PORT
Clients: $CLIENT_COUNT
QoS: $QOS
Topic: $TOPIC

MANUAL COMMANDS:
----------------
Start test:
  sudo systemctl start emqtt-bench

View logs:
  sudo journalctl -u emqtt-bench -f

Test logs location:
  /var/log/emqtt-bench-tests/

Run script directly:
  /opt/emqtt-bench-runner/run-test.sh

EMQTT-Bench Command:
  emqtt_bench --help
EOF

echo ""
echo "=========================================="
echo "EMQTT-Bench Installation Complete!"
echo "=========================================="
echo "Mode: $TEST_MODE"
echo "Broker: $BROKER_HOST:$BROKER_PORT"
echo "Clients: $CLIENT_COUNT"
echo ""

# Auto-start test if enabled
if [ "$AUTO_START" = "true" ]; then
    echo "AUTO_START enabled, starting test in 5 seconds..."
    sleep 5
    systemctl start emqtt-bench
    echo "Test started! Monitor with: journalctl -u emqtt-bench -f"
else
    echo "To start test manually:"
    echo "  sudo systemctl start emqtt-bench"
    echo ""
    echo "Or run directly:"
    echo "  /opt/emqtt-bench-runner/run-test.sh"
fi

echo ""
echo "Installation log: /var/log/emqtt-bench-startup.log"
echo "Configuration: /opt/emqtt-bench-runner/INFO.txt"
echo "=========================================="

touch /var/log/emqtt-bench-installation-complete
echo "Startup script finished at $(date)"
