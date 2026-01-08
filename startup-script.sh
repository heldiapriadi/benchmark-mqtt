#!/bin/bash
#
# GCP Startup Script for MQTT Stress Testing with emqtt-bench
# This script automatically downloads, installs, and runs emqtt-bench
# based on GCP instance metadata configuration
#
# Metadata Configuration:
#   mqtt-host: MQTT broker host (required)
#   mqtt-port: MQTT broker port (default: 1883)
#   mqtt-username: MQTT username (optional)
#   mqtt-password: MQTT password (optional)
#   test-type: Type of test - connect, publish, subscribe, full (default: connect)
#   connections: Number of connections (default: 100)
#   interval: Message interval in ms (default: 1000)
#   topic: MQTT topic pattern (default: bench/%i)
#   payload-size: Payload size in bytes (default: 256)
#   qos: Quality of Service level 0-2 (default: 0)
#   duration: Test duration in seconds (default: 60)
#   emqtt-version: emqtt-bench version (default: 0.6.1)
#   use-ssl: Enable SSL/TLS (default: false)
#   use-websocket: Use WebSocket transport (default: false)
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# Function to get GCP instance metadata
get_metadata() {
    local key="$1"
    local default="${2:-}"
    
    local value
    value=$(curl -s -H "Metadata-Flavor: Google" \
        "http://metadata.google.internal/computeMetadata/v1/instance/attributes/${key}" 2>/dev/null || echo "")
    
    if [ -z "$value" ]; then
        echo "$default"
    else
        echo "$value"
    fi
}

# Function to detect OS architecture
detect_arch() {
    local arch
    arch=$(uname -m)
    local os
    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    
    case "$arch" in
        x86_64|amd64)
            echo "amd64"
            ;;
        aarch64|arm64)
            echo "arm64"
            ;;
        *)
            log_error "Unsupported architecture: $arch"
            exit 1
            ;;
    esac
}

# Function to detect OS distribution
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            ubuntu)
                echo "ubuntu${VERSION_ID%%.*}"
                ;;
            debian)
                echo "debian${VERSION_ID%%.*}"
                ;;
            *)
                log_warn "Unknown OS distribution, defaulting to ubuntu22.04"
                echo "ubuntu22.04"
                ;;
        esac
    else
        log_warn "Cannot detect OS, defaulting to ubuntu22.04"
        echo "ubuntu22.04"
    fi
}

# Main installation function
main() {
    log_info "Starting MQTT stress testing setup..."
    
    # Read configuration from metadata
    MQTT_HOST=$(get_metadata "mqtt-host" "")
    MQTT_PORT=$(get_metadata "mqtt-port" "1883")
    MQTT_USERNAME=$(get_metadata "mqtt-username" "")
    MQTT_PASSWORD=$(get_metadata "mqtt-password" "")
    TEST_TYPE=$(get_metadata "test-type" "connect")
    CONNECTIONS=$(get_metadata "connections" "100")
    INTERVAL=$(get_metadata "interval" "1000")
    TOPIC=$(get_metadata "topic" "bench/%i")
    PAYLOAD_SIZE=$(get_metadata "payload-size" "256")
    QOS=$(get_metadata "qos" "0")
    DURATION=$(get_metadata "duration" "60")
    EMQTT_VERSION=$(get_metadata "emqtt-version" "0.6.1")
    USE_SSL=$(get_metadata "use-ssl" "false")
    USE_WEBSOCKET=$(get_metadata "use-websocket" "false")
    
    # Validate required parameters
    if [ -z "$MQTT_HOST" ]; then
        log_error "mqtt-host metadata is required but not set"
        exit 1
    fi
    
    log_info "Configuration loaded:"
    log_info "  MQTT Host: $MQTT_HOST"
    log_info "  MQTT Port: $MQTT_PORT"
    log_info "  Test Type: $TEST_TYPE"
    log_info "  Connections: $CONNECTIONS"
    log_info "  Interval: ${INTERVAL}ms"
    log_info "  Topic: $TOPIC"
    log_info "  Payload Size: $PAYLOAD_SIZE bytes"
    log_info "  QoS: $QOS"
    log_info "  Duration: ${DURATION}s"
    
    # Install dependencies
    log_info "Installing dependencies..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq curl wget tar gzip ca-certificates
    
    # Detect architecture and OS
    ARCH=$(detect_arch)
    OS=$(detect_os)
    
    log_info "Detected architecture: $ARCH, OS: $OS"
    
    # Download emqtt-bench
    INSTALL_DIR="/opt/emqtt-bench"
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"
    
    # Determine download URL based on version and architecture
    if [ "$ARCH" = "amd64" ]; then
        ARCH_SUFFIX="amd64"
    else
        ARCH_SUFFIX="arm64"
    fi
    
    # Try to download from GitHub releases
    DOWNLOAD_URL="https://github.com/emqx/emqtt-bench/releases/download/${EMQTT_VERSION}/emqtt-bench-${EMQTT_VERSION}-${OS}-${ARCH_SUFFIX}.tar.gz"
    
    log_info "Downloading emqtt-bench ${EMQTT_VERSION} from ${DOWNLOAD_URL}..."
    
    if ! wget -q --timeout=30 --tries=3 -O emqtt-bench.tar.gz "$DOWNLOAD_URL"; then
        log_error "Failed to download emqtt-bench from GitHub releases"
        log_info "Trying alternative download method..."
        
        # Alternative: try to build from source or use different URL pattern
        log_error "Please check if the version and OS combination is available"
        exit 1
    fi
    
    # Extract
    log_info "Extracting emqtt-bench..."
    tar -xzf emqtt-bench.tar.gz
    rm -f emqtt-bench.tar.gz
    
    # Find the binary
    if [ -f "bin/emqtt_bench" ]; then
        chmod +x bin/emqtt_bench
        EMQTT_BENCH_BIN="$INSTALL_DIR/bin/emqtt_bench"
    elif [ -f "emqtt_bench" ]; then
        chmod +x emqtt_bench
        EMQTT_BENCH_BIN="$INSTALL_DIR/emqtt_bench"
    else
        log_error "emqtt_bench binary not found after extraction"
        exit 1
    fi
    
    log_info "emqtt-bench installed successfully at $EMQTT_BENCH_BIN"
    
    # Build command arguments
    CMD_ARGS=(
        -h "$MQTT_HOST"
        -p "$MQTT_PORT"
        -c "$CONNECTIONS"
        -i "$INTERVAL"
        -t "$TOPIC"
        -s "$PAYLOAD_SIZE"
        -q "$QOS"
    )
    
    # Add optional parameters
    if [ -n "$MQTT_USERNAME" ]; then
        CMD_ARGS+=(-u "$MQTT_USERNAME")
    fi
    
    if [ -n "$MQTT_PASSWORD" ]; then
        CMD_ARGS+=(-P "$MQTT_PASSWORD")
    fi
    
    if [ "$USE_SSL" = "true" ]; then
        CMD_ARGS+=(--ssl)
    fi
    
    if [ "$USE_WEBSOCKET" = "true" ]; then
        CMD_ARGS+=(--ws)
    fi
    
    # Create log directory
    LOG_DIR="/var/log/emqtt-bench"
    mkdir -p "$LOG_DIR"
    LOG_FILE="$LOG_DIR/test-$(date +%Y%m%d-%H%M%S).log"
    
    # Execute test based on type
    log_info "Starting test type: $TEST_TYPE"
    
    case "$TEST_TYPE" in
        connect)
            log_info "Running connection test..."
            "$EMQTT_BENCH_BIN" conn "${CMD_ARGS[@]}" 2>&1 | tee "$LOG_FILE"
            ;;
        publish)
            log_info "Running publish test..."
            CMD_ARGS+=(-L "$((DURATION * 1000 / INTERVAL))")  # Approximate message count
            "$EMQTT_BENCH_BIN" pub "${CMD_ARGS[@]}" 2>&1 | tee "$LOG_FILE"
            ;;
        subscribe)
            log_info "Running subscribe test..."
            timeout "$DURATION" "$EMQTT_BENCH_BIN" sub "${CMD_ARGS[@]}" 2>&1 | tee "$LOG_FILE" || true
            ;;
        full)
            log_info "Running full test (publish + subscribe)..."
            
            # Start subscribers in background
            log_info "Starting subscribers..."
            "$EMQTT_BENCH_BIN" sub "${CMD_ARGS[@]}" > "$LOG_DIR/subscribe.log" 2>&1 &
            SUB_PID=$!
            
            # Wait a bit for subscribers to connect
            sleep 5
            
            # Start publishers
            log_info "Starting publishers..."
            CMD_ARGS+=(-L "$((DURATION * 1000 / INTERVAL))")
            "$EMQTT_BENCH_BIN" pub "${CMD_ARGS[@]}" 2>&1 | tee "$LOG_FILE"
            
            # Wait for subscribers
            sleep 5
            kill $SUB_PID 2>/dev/null || true
            ;;
        *)
            log_error "Unknown test type: $TEST_TYPE"
            log_info "Available test types: connect, publish, subscribe, full"
            exit 1
            ;;
    esac
    
    log_info "Test completed. Logs saved to: $LOG_FILE"
    log_info "Setup and test execution finished successfully"
}

# Run main function
main "$@"

