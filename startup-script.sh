#!/bin/bash

# Startup Script untuk EMQTT-Bench - Fixed Version
set -e

# Log setup
exec > >(tee -a /var/log/emqtt-bench-startup.log)
exec 2>&1

echo "=== EMQTT-Bench Startup Script ==="
echo "Timestamp: $(date)"
echo "Hostname: $(hostname)"

# Get metadata function
get_metadata() {
    curl -s -f "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1" \
         -H "Metadata-Flavor: Google" 2>/dev/null || echo ""
}

# Read configuration
TEST_MODE=$(get_metadata "test-mode")
BROKER_HOST=$(get_metadata "broker-host")
BROKER_PORT=$(get_metadata "broker-port")
CLIENT_COUNT=$(get_metadata "client-count")
QOS=$(get_metadata "qos")
TOPIC=$(get_metadata "topic")
MESSAGE_SIZE=$(get_metadata "message-size")
MESSAGE_COUNT=$(get_metadata "message-count")
INTERVAL=$(get_metadata "interval")
USERNAME=$(get_metadata "mqtt-username")
PASSWORD=$(get_metadata "mqtt-password")
KEEPALIVE=$(get_metadata "keepalive")
AUTO_START=$(get_metadata "auto-start")

# Set defaults
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

# Wait for apt to be ready
echo "Waiting for apt to be ready..."
while sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 ; do
    echo "Waiting for other apt processes to finish..."
    sleep 5
done

# Update system
echo "Updating system packages..."
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq

echo "Installing dependencies..."
sudo apt-get install -y -qq wget git build-essential curl jq < /dev/null

# Install Erlang/OTP - Fixed method
echo "Installing Erlang/OTP..."
if ! command -v erl &> /dev/null; then
    echo "Downloading Erlang repository package..."
    wget -q https://packages.erlang-solutions.com/erlang-solutions_2.0_all.deb
    
    echo "Installing Erlang repository..."
    sudo dpkg -i erlang-solutions_2.0_all.deb || true
    
    echo "Updating package list..."
    sudo apt-get update -qq
    
    echo "Installing Erlang (this may take a few minutes)..."
    sudo apt-get install -y erlang < /dev/null
    
    echo "Cleaning up..."
    rm erlang-solutions_2.0_all.deb
    
    echo "Verifying Erlang installation..."
    erl -version || echo "Warning: Erlang verification failed"
else
    echo "Erlang already installed"
fi

# Install Rebar3
echo "Installing Rebar3..."
if ! command -v rebar3 &> /dev/null; then
    cd /opt
    wget -q https://s3.amazonaws.com/rebar3/rebar3
    chmod +x rebar3
    sudo mv rebar3 /usr/local/bin/
else
    echo "Rebar3 already installed"
fi

# Clone and build emqtt-bench
echo "Building emqtt-bench..."
if [ ! -d "/opt/emqtt-bench" ]; then
    cd /opt
    echo "Cloning repository..."
    git clone -q https://github.com/emqx/emqtt-bench.git
    cd emqtt-bench
    
    echo "Building (this may take a few minutes)..."
    make
    
    sudo ln -sf /opt/emqtt-bench/_build/default/bin/emqtt_bench /usr/local/bin/emqtt_bench
    
    echo "Verifying emqtt_bench installation..."
    emqtt_bench --help | head -5 || echo "Warning: emqtt_bench verification failed"
else
    echo "emqtt-bench already installed"
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

# Create run script
cat > /opt/emqtt-bench-runner/run-test.sh << 'RUNSCRIPT'
#!/bin/bash

LOG_DIR="/var/log/emqtt-bench-tests"
mkdir -p $LOG_DIR

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
HOSTNAME=$(hostname)

echo "=== Starting EMQTT-Bench Test ==="
echo "Mode: TEST_MODE_PLACEHOLDER"
echo "Broker: BROKER_PLACEHOLDER:PORT_PLACEHOLDER"
echo "Clients: CLIENTS_PLACEHOLDER"
echo "Timestamp: $TIMESTAMP"

case "TEST_MODE_PLACEHOLDER" in
    conn)
        echo "Running CONNECTION test..."
        CMD_BASE_PLACEHOLDER conn CMD_OPTS_PLACEHOLDER -i INTERVAL_PLACEHOLDER \
            2>&1 | tee $LOG_DIR/conn_${HOSTNAME}_${TIMESTAMP}.log
        ;;
    
    pub)
        echo "Running PUBLISH test..."
        CMD_BASE_PLACEHOLDER pub CMD_OPTS_PLACEHOLDER \
            -t "TOPIC_PLACEHOLDER" \
            -s MESSAGE_SIZE_PLACEHOLDER \
            -C MESSAGE_COUNT_PLACEHOLDER \
            -I INTERVAL_PLACEHOLDER \
            2>&1 | tee $LOG_DIR/pub_${HOSTNAME}_${TIMESTAMP}.log
        ;;
    
    sub)
        echo "Running SUBSCRIBE test..."
        CMD_BASE_PLACEHOLDER sub CMD_OPTS_PLACEHOLDER \
            -t "TOPIC_PLACEHOLDER" \
            2>&1 | tee $LOG_DIR/sub_${HOSTNAME}_${TIMESTAMP}.log
        ;;
    
    pubsub)
        echo "Running PUBLISH+SUBSCRIBE test..."
        
        CMD_BASE_PLACEHOLDER sub CMD_OPTS_PLACEHOLDER \
            -t "TOPIC_PLACEHOLDER" \
            2>&1 | tee $LOG_DIR/sub_${HOSTNAME}_${TIMESTAMP}.log &
        
        SUB_PID=$!
        echo "Subscribers started (PID: $SUB_PID), waiting 10 seconds..."
        sleep 10
        
        CMD_BASE_PLACEHOLDER pub CMD_OPTS_PLACEHOLDER \
            -t "TOPIC_PLACEHOLDER" \
            -s MESSAGE_SIZE_PLACEHOLDER \
            -C MESSAGE_COUNT_PLACEHOLDER \
            -I INTERVAL_PLACEHOLDER \
            2>&1 | tee $LOG_DIR/pub_${HOSTNAME}_${TIMESTAMP}.log
        
        sleep 5
        kill $SUB_PID 2>/dev/null
        ;;
    
    *)
        echo "ERROR: Invalid test mode"
        exit 1
        ;;
esac

echo "=== Test completed ==="
echo "End time: $(date)"
RUNSCRIPT

# Replace placeholders
sed -i "s|TEST_MODE_PLACEHOLDER|$TEST_MODE|g" /opt/emqtt-bench-runner/run-test.sh
sed -i "s|BROKER_PLACEHOLDER|$BROKER_HOST|g" /opt/emqtt-bench-runner/run-test.sh
sed -i "s|PORT_PLACEHOLDER|$BROKER_PORT|g" /opt/emqtt-bench-runner/run-test.sh
sed -i "s|CLIENTS_PLACEHOLDER|$CLIENT_COUNT|g" /opt/emqtt-bench-runner/run-test.sh
sed -i "s|CMD_BASE_PLACEHOLDER|$CMD_BASE|g" /opt/emqtt-bench-runner/run-test.sh
sed -i "s|CMD_OPTS_PLACEHOLDER|$CMD_OPTS|g" /opt/emqtt-bench-runner/run-test.sh
sed -i "s|TOPIC_PLACEHOLDER|$TOPIC|g" /opt/emqtt-bench-runner/run-test.sh
sed -i "s|MESSAGE_SIZE_PLACEHOLDER|$MESSAGE_SIZE|g" /opt/emqtt-bench-runner/run-test.sh
sed -i "s|MESSAGE_COUNT_PLACEHOLDER|$MESSAGE_COUNT|g" /opt/emqtt-bench-runner/run-test.sh
sed -i "s|INTERVAL_PLACEHOLDER|$INTERVAL|g" /opt/emqtt-bench-runner/run-test.sh

chmod +x /opt/emqtt-bench-runner/run-test.sh

# Create systemd service
cat > /etc/systemd/system/emqtt-bench.service << 'SERVICE'
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
SERVICE

systemctl daemon-reload

# Create info file
cat > /opt/emqtt-bench-runner/INFO.txt << INFO
=== EMQTT-Bench Configuration ===

Instance: $(hostname)
Test Mode: $TEST_MODE
Broker: $BROKER_HOST:$BROKER_PORT
Clients: $CLIENT_COUNT
QoS: $QOS
Topic: $TOPIC

COMMANDS:
Start test: sudo systemctl start emqtt-bench
View logs: sudo journalctl -u emqtt-bench -f
Test logs: /var/log/emqtt-bench-tests/
Run directly: /opt/emqtt-bench-runner/run-test.sh
INFO

echo ""
echo "=========================================="
echo "EMQTT-Bench Installation Complete!"
echo "=========================================="
echo "Mode: $TEST_MODE"
echo "Broker: $BROKER_HOST:$BROKER_PORT"
echo ""

# Auto-start test if enabled
if [ "$AUTO_START" = "true" ]; then
    echo "AUTO_START enabled, starting test in 5 seconds..."
    sleep 5
    systemctl start emqtt-bench
    echo "Test started!"
else
    echo "To start test: sudo systemctl start emqtt-bench"
fi

echo ""
echo "Installation log: /var/log/emqtt-bench-startup.log"
echo "=========================================="

touch /var/log/emqtt-bench-installation-complete
echo "Startup script finished at $(date)"
