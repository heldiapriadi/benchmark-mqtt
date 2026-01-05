#!/bin/bash

# Google Cloud VM Startup Script untuk EMQX Stress Test dengan emqtt-bench
# Script ini akan:
# 1. Update sistem
# 2. Install dependencies (Erlang, libatomic, build tools)
# 3. Clone dan build emqtt-bench
# 4. Setup resource limits untuk stress test
# 5. Jalankan benchmark sesuai konfigurasi

set -e

# ============================================================================
# KONFIGURASI
# ============================================================================

# MQTT Broker Configuration
MQTT_HOST="${MQTT_HOST:-localhost}"
MQTT_PORT="${MQTT_PORT:-1883}"
MQTT_VERSION="${MQTT_VERSION:-5}"

# Benchmark Configuration
BENCHMARK_TYPE="${BENCHMARK_TYPE:-conn}"  # conn, pub, atau sub
CLIENT_COUNT="${CLIENT_COUNT:-10000}"
CONNECTION_RATE="${CONNECTION_RATE:-100}"
INTERVAL="${INTERVAL:-10}"

# Publisher specific config
PUB_MESSAGE_INTERVAL="${PUB_MESSAGE_INTERVAL:-1000}"
PUB_MESSAGE_SIZE="${PUB_MESSAGE_SIZE:-256}"
PUB_TOPIC="${PUB_TOPIC:-bench/%i}"

# Subscriber specific config
SUB_TOPIC="${SUB_TOPIC:-bench/%i}"
SUB_QOS="${SUB_QOS:-0}"

# Additional flags
USERNAME="${USERNAME:-}"
PASSWORD="${PASSWORD:-}"
USE_SSL="${USE_SSL:-false}"
ENABLE_PROMETHEUS="${ENABLE_PROMETHEUS:-true}"
PROMETHEUS_PORT="${PROMETHEUS_PORT:-8081}"

# Logging
LOG_DIR="/var/log/emqx-benchmark"
LOG_FILE="${LOG_DIR}/benchmark-$(date +%Y%m%d-%H%M%S).log"

# ============================================================================
# LOGGING FUNCTIONS
# ============================================================================

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "${LOG_FILE}"
}

error() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $*" | tee -a "${LOG_FILE}" >&2
    exit 1
}

# ============================================================================
# SETUP LOGGING
# ============================================================================

mkdir -p "${LOG_DIR}"
touch "${LOG_FILE}"
log "===== Starting EMQX Stress Test Startup Script ====="

# ============================================================================
# DETECT OS
# ============================================================================

if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    error "Cannot detect operating system"
fi

log "Detected OS: $OS"

# ============================================================================
# UPDATE SYSTEM
# ============================================================================

log "Updating system packages..."
if [[ "$OS" == "ubuntu" ]] || [[ "$OS" == "debian" ]]; then
    apt-get update
    apt-get upgrade -y
elif [[ "$OS" == "centos" ]] || [[ "$OS" == "rhel" ]]; then
    yum update -y
fi

# ============================================================================
# INSTALL DEPENDENCIES
# ============================================================================

log "Installing dependencies..."

if [[ "$OS" == "ubuntu" ]] || [[ "$OS" == "debian" ]]; then
    apt-get install -y \
        curl \
        wget \
        git \
        build-essential \
        libatomic1 \
        ca-certificates
elif [[ "$OS" == "centos" ]] || [[ "$OS" == "rhel" ]]; then
    yum install -y \
        curl \
        wget \
        git \
        gcc \
        make \
        libatomic \
        ca-certificates
fi

# ============================================================================
# INSTALL ERLANG/OTP
# ============================================================================

log "Checking if Erlang/OTP is installed..."
if ! command -v erl &> /dev/null; then
    log "Installing Erlang/OTP..."
    
    if [[ "$OS" == "ubuntu" ]] || [[ "$OS" == "debian" ]]; then
        # Add Erlang Solutions repository
        wget https://packages.erlang-solutions.com/erlang-solutions_2.0_all.deb
        dpkg -i erlang-solutions_2.0_all.deb
        apt-get update
        apt-get install -y erlang-base erlang-dev
    elif [[ "$OS" == "centos" ]] || [[ "$OS" == "rhel" ]]; then
        yum install -y erlang
    fi
else
    ERLANG_VERSION=$(erl -eval 'erlang:halt(0)' -noshell 2>&1 | grep "Erlang/OTP" || echo "unknown")
    log "Erlang/OTP already installed: $ERLANG_VERSION"
fi

# ============================================================================
# CLONE & BUILD EMQTT-BENCH
# ============================================================================

BENCH_DIR="/opt/emqtt-bench"

log "Cloning emqtt-bench repository..."
if [ -d "$BENCH_DIR" ]; then
    log "emqtt-bench already exists, updating..."
    cd "$BENCH_DIR"
    git pull origin master
else
    git clone https://github.com/emqx/emqtt-bench.git "$BENCH_DIR"
    cd "$BENCH_DIR"
fi

log "Building emqtt-bench..."
cd "$BENCH_DIR"
make clean
make 2>&1 | tee -a "${LOG_FILE}"

if [ ! -f "$BENCH_DIR/bin/emqtt_bench" ]; then
    error "Build failed - emqtt_bench binary not found"
fi

log "Build successful!"

# ============================================================================
# SETUP RESOURCE LIMITS
# ============================================================================

log "Setting up resource limits for stress testing..."

# Increase file descriptors
ulimit -n 200000
log "Set max open files: 200000"

# Increase network parameters
sysctl -w net.ipv4.ip_local_port_range="1025 65534" 2>&1 | tee -a "${LOG_FILE}"
sysctl -w net.core.somaxconn=65535 2>&1 | tee -a "${LOG_FILE}"
sysctl -w net.ipv4.tcp_max_syn_backlog=65535 2>&1 | tee -a "${LOG_FILE}"

# Permanent settings
cat >> /etc/sysctl.conf << EOF
net.ipv4.ip_local_port_range = 1025 65534
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
EOF

log "Resource limits configured"

# ============================================================================
# BUILD BENCHMARK COMMAND
# ============================================================================

log "Building benchmark command..."

BENCH_CMD="$BENCH_DIR/bin/emqtt_bench $BENCHMARK_TYPE"
BENCH_CMD="$BENCH_CMD -h $MQTT_HOST"
BENCH_CMD="$BENCH_CMD -p $MQTT_PORT"
BENCH_CMD="$BENCH_CMD -V $MQTT_VERSION"
BENCH_CMD="$BENCH_CMD -c $CLIENT_COUNT"
BENCH_CMD="$BENCH_CMD -R $CONNECTION_RATE"
BENCH_CMD="$BENCH_CMD -i $INTERVAL"

# Add authentication if provided
if [ -n "$USERNAME" ]; then
    BENCH_CMD="$BENCH_CMD -u $USERNAME"
fi

if [ -n "$PASSWORD" ]; then
    BENCH_CMD="$BENCH_CMD -P $PASSWORD"
fi

# Add SSL if enabled
if [ "$USE_SSL" = "true" ]; then
    BENCH_CMD="$BENCH_CMD -S"
fi

# Add Prometheus if enabled
if [ "$ENABLE_PROMETHEUS" = "true" ]; then
    BENCH_CMD="$BENCH_CMD --prometheus"
    BENCH_CMD="$BENCH_CMD --restapi 0.0.0.0:$PROMETHEUS_PORT"
fi

# Type-specific options
case "$ " in
    pub)
        BENCH_CMD="$BENCH_CMD -I $PUB_MESSAGE_INTERVAL"
        BENCH_CMD="$BENCH_CMD -t $PUB_TOPIC"
        BENCH_CMD="$BENCH_CMD -s $PUB_MESSAGE_SIZE"
        ;;
    sub)
        BENCH_CMD="$BENCH_CMD -t $SUB_TOPIC"
        BENCH_CMD="$BENCH_CMD -q $SUB_QOS"
        ;;
esac

log "Benchmark command: $BENCH_CMD"

# ============================================================================
# CREATE SYSTEMD SERVICE (OPTIONAL)
# ============================================================================

log "Creating systemd service file..."

cat > /etc/systemd/system/emqx-benchmark.service << 'EOF'
[Unit]
Description=EMQX Benchmark Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/emqtt-bench
ExecStart=$BENCH_CMD
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# ============================================================================
# SAVE CONFIGURATION
# ============================================================================

CONFIG_FILE="/opt/emqx-benchmark-config.sh"
log "Saving configuration to $CONFIG_FILE..."

cat > "$CONFIG_FILE" << EOF
# EMQX Benchmark Configuration
# Auto-generated by startup script at $(date)

# MQTT Broker Configuration
export MQTT_HOST="${MQTT_HOST}"
export MQTT_PORT="${MQTT_PORT}"
export MQTT_VERSION="${MQTT_VERSION}"

# Benchmark Configuration
export BENCHMARK_TYPE="${BENCHMARK_TYPE}"
export CLIENT_COUNT="${CLIENT_COUNT}"
export CONNECTION_RATE="${CONNECTION_RATE}"
export INTERVAL="${INTERVAL}"

# Publisher specific config
export PUB_MESSAGE_INTERVAL="${PUB_MESSAGE_INTERVAL}"
export PUB_MESSAGE_SIZE="${PUB_MESSAGE_SIZE}"
export PUB_TOPIC="${PUB_TOPIC}"

# Subscriber specific config
export SUB_TOPIC="${SUB_TOPIC}"
export SUB_QOS="${SUB_QOS}"

# Additional flags
export USERNAME="${USERNAME}"
export PASSWORD="${PASSWORD}"
export USE_SSL="${USE_SSL}"
export ENABLE_PROMETHEUS="${ENABLE_PROMETHEUS}"
export PROMETHEUS_PORT="${PROMETHEUS_PORT}"

# Benchmark command
export BENCH_CMD="$BENCH_CMD"
export BENCH_DIR="$BENCH_DIR"
EOF

chmod +x "$CONFIG_FILE"

# ============================================================================
# CREATE HELPER SCRIPTS
# ============================================================================

log "Creating helper scripts..."

# Script untuk run benchmark
cat > /usr/local/bin/run-benchmark << 'EOF'
#!/bin/bash
source /opt/emqx-benchmark-config.sh
$BENCH_CMD
EOF

chmod +x /usr/local/bin/run-benchmark

# Script untuk check status
cat > /usr/local/bin/benchmark-status << 'EOF'
#!/bin/bash
CONFIG_FILE="/opt/emqx-benchmark-config.sh"
if [ -f "$CONFIG_FILE" ]; then
    echo "=== EMQX Benchmark Configuration ==="
    grep "export" "$CONFIG_FILE" | grep -v "^#"
else
    echo "Configuration file not found"
fi
EOF

chmod +x /usr/local/bin/benchmark-status

# ============================================================================
# PRINT SUMMARY
# ============================================================================

cat << EOF

╔════════════════════════════════════════════════════════════════╗
║     EMQX Stress Test - Setup Complete!                        ║
╚════════════════════════════════════════════════════════════════╝

📍 Installation Directory: $BENCH_DIR
📍 Configuration File:     $CONFIG_FILE
📍 Log File:              $LOG_FILE

🚀 Quick Start Commands:

1. Run benchmark directly:
   run-benchmark

2. Run benchmark in background:
   nohup run-benchmark > $LOG_FILE 2>&1 &

3. View configuration:
   benchmark-status

4. Access Prometheus metrics (if enabled):
   curl http://localhost:$PROMETHEUS_PORT/metrics

📊 Current Configuration:
   • MQTT Host:        $MQTT_HOST:$MQTT_PORT
   • Benchmark Type:   $BENCHMARK_TYPE
   • Client Count:     $CLIENT_COUNT
   • Connection Rate:  $CONNECTION_RATE/s

📝 For manual customization, edit:
   $CONFIG_FILE

🔍 To enable systemd service:
   systemctl daemon-reload
   systemctl enable emqx-benchmark
   systemctl start emqx-benchmark

Log file: $LOG_FILE

EOF

log "===== Startup Script Complete ====="