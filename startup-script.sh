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

# Global log file for startup script
STARTUP_LOG_FILE=""

# Logging functions
log_info() {
    local msg="[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $1"
    echo -e "${GREEN}${msg}${NC}"
    if [ -n "$STARTUP_LOG_FILE" ]; then
        echo "$msg" >> "$STARTUP_LOG_FILE"
    fi
}

log_warn() {
    local msg="[WARN] $(date '+%Y-%m-%d %H:%M:%S') - $1"
    echo -e "${YELLOW}${msg}${NC}"
    if [ -n "$STARTUP_LOG_FILE" ]; then
        echo "$msg" >> "$STARTUP_LOG_FILE"
    fi
}

log_error() {
    local msg="[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $1"
    echo -e "${RED}${msg}${NC}"
    if [ -n "$STARTUP_LOG_FILE" ]; then
        echo "$msg" >> "$STARTUP_LOG_FILE"
    fi
}

# Function to check if running on GCP
is_gcp_instance() {
    curl -s -f -H "Metadata-Flavor: Google" \
        "http://metadata.google.internal/computeMetadata/v1/instance/id" >/dev/null 2>&1
}

# Function to get GCP instance metadata
# Falls back to environment variables if not running on GCP
get_metadata() {
    local key="$1"
    local default="${2:-}"
    
    # First try GCP metadata (if running on GCP)
    if is_gcp_instance; then
        local value
        value=$(curl -s -f -H "Metadata-Flavor: Google" \
            "http://metadata.google.internal/computeMetadata/v1/instance/attributes/${key}" 2>/dev/null || echo "")
        
        if [ -n "$value" ] && [ "$value" != "<!DOCTYPE html>" ]; then
            echo "$value"
            return
        fi
    fi
    
    # Fallback to environment variable (convert key to env var format: mqtt-host -> MQTT_HOST)
    local env_key
    env_key=$(echo "$key" | tr '[:lower:]' '[:upper:]' | tr '-' '_')
    if [ -n "${!env_key:-}" ]; then
        echo "${!env_key}"
        return
    fi
    
    # Return default if nothing found
    echo "$default"
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
                # Map debian versions to compatible builds
                # debian11 has GLIBC 2.31, debian12 builds need GLIBC 2.34
                # Use ubuntu20.04 for debian11 (compatible GLIBC)
                local debian_version="${VERSION_ID%%.*}"
                if [ "$debian_version" = "11" ]; then
                    # debian11 needs older GLIBC - use ubuntu20.04 build
                    echo "ubuntu20.04"
                elif [ "$debian_version" = "12" ]; then
                    echo "debian12"
                else
                    echo "ubuntu22.04"
                fi
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
    # Create log directory early
    LOG_DIR="/var/log/emqtt-bench"
    mkdir -p "$LOG_DIR"
    STARTUP_LOG_FILE="$LOG_DIR/startup-$(date +%Y%m%d-%H%M%S).log"
    
    # Log startup script execution
    {
        echo "=========================================="
        echo "MQTT Stress Test Startup Script"
        echo "Started: $(date)"
        echo "=========================================="
        echo ""
    } >> "$STARTUP_LOG_FILE"
    
    log_info "Starting MQTT stress testing setup..."
    log_info "Startup log: $STARTUP_LOG_FILE"
    
    # Check if running on GCP
    if is_gcp_instance; then
        log_info "Running on GCP instance - reading from metadata"
    else
        log_warn "Not running on GCP instance - using environment variables or defaults"
        log_warn "Set environment variables like: MQTT_HOST, MQTT_PORT, etc."
    fi
    
    # Read configuration from metadata (or environment variables)
    MQTT_HOST=$(get_metadata "mqtt-host" "")
    USE_SSL=$(get_metadata "use-ssl" "false")
    
    # Set default port based on SSL usage
    if [ "$USE_SSL" = "true" ]; then
        DEFAULT_PORT="8883"
    else
        DEFAULT_PORT="1883"
    fi
    
    MQTT_PORT=$(get_metadata "mqtt-port" "$DEFAULT_PORT")
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
    USE_WEBSOCKET=$(get_metadata "use-websocket" "false")
    
    # SSL Certificate paths (optional)
    SSL_CA_CERT=$(get_metadata "ssl-ca-cert" "")
    SSL_CERT=$(get_metadata "ssl-cert" "")
    SSL_KEY=$(get_metadata "ssl-key" "")
    SSL_VERSION=$(get_metadata "ssl-version" "")
    
    # Validate required parameters
    if [ -z "$MQTT_HOST" ]; then
        log_error "mqtt-host is required but not set"
        log_error "Set it via:"
        if is_gcp_instance; then
            log_error "  - GCP metadata: --metadata mqtt-host=your-host"
        else
            log_error "  - Environment variable: export MQTT_HOST=your-host"
        fi
        exit 1
    fi
    
    log_info "Configuration loaded:"
    log_info "  MQTT Host: $MQTT_HOST"
    log_info "  MQTT Port: $MQTT_PORT"
    log_info "  Use SSL: $USE_SSL"
    if [ "$USE_SSL" = "true" ]; then
        log_info "  SSL CA Cert: ${SSL_CA_CERT:-Not set (will skip verification)}"
        log_info "  SSL Cert: ${SSL_CERT:-Not set}"
        log_info "  SSL Key: ${SSL_KEY:-Not set}"
        if [ -n "$SSL_VERSION" ]; then
            log_info "  SSL Version: $SSL_VERSION"
        fi
    fi
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
    
    # Try multiple URL patterns for GitHub releases
    DOWNLOAD_URLS=(
        "https://github.com/emqx/emqtt-bench/releases/download/${EMQTT_VERSION}/emqtt-bench-${EMQTT_VERSION}-${OS}-${ARCH_SUFFIX}.tar.gz"
        "https://github.com/emqx/emqtt-bench/releases/download/${EMQTT_VERSION}/emqtt-bench-${EMQTT_VERSION}-${OS}-${ARCH_SUFFIX}-quic.tar.gz"
        "https://github.com/emqx/emqtt-bench/releases/download/${EMQTT_VERSION}/emqtt-bench-${EMQTT_VERSION}-linux-${ARCH_SUFFIX}.tar.gz"
    )
    
    # Add fallback URLs for better compatibility
    # Try ubuntu20.04 as universal fallback (older GLIBC, widely compatible)
    if [[ "$OS" != "ubuntu20.04" ]]; then
        DOWNLOAD_URLS+=(
            "https://github.com/emqx/emqtt-bench/releases/download/${EMQTT_VERSION}/emqtt-bench-${EMQTT_VERSION}-ubuntu20.04-${ARCH_SUFFIX}.tar.gz"
            "https://github.com/emqx/emqtt-bench/releases/download/${EMQTT_VERSION}/emqtt-bench-${EMQTT_VERSION}-ubuntu22.04-${ARCH_SUFFIX}.tar.gz"
        )
        log_info "Added ubuntu20.04/22.04 fallback URLs for GLIBC compatibility"
    fi
    
    DOWNLOAD_SUCCESS=false
    for DOWNLOAD_URL in "${DOWNLOAD_URLS[@]}"; do
        log_info "Trying to download from: ${DOWNLOAD_URL}..."
        if wget -q --timeout=30 --tries=2 -O emqtt-bench.tar.gz "$DOWNLOAD_URL" 2>/dev/null; then
            if [ -s emqtt-bench.tar.gz ]; then
                DOWNLOAD_SUCCESS=true
                log_info "Successfully downloaded emqtt-bench"
                break
            fi
        fi
        rm -f emqtt-bench.tar.gz
    done
    
    if [ "$DOWNLOAD_SUCCESS" = false ]; then
        log_error "Failed to download emqtt-bench from all attempted URLs"
        log_error "Please check:"
        log_error "  1. Version ${EMQTT_VERSION} exists at https://github.com/emqx/emqtt-bench/releases"
        log_error "  2. OS ${OS} and architecture ${ARCH_SUFFIX} combination is available"
        log_error "  3. Internet connectivity from this instance"
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
    
    # Build base command arguments (common for all test types)
    BASE_ARGS=(
        -h "$MQTT_HOST"
        -p "$MQTT_PORT"
        -c "$CONNECTIONS"
    )
    
    # Add optional authentication
    if [ -n "$MQTT_USERNAME" ]; then
        BASE_ARGS+=(-u "$MQTT_USERNAME")
    fi
    
    if [ -n "$MQTT_PASSWORD" ]; then
        BASE_ARGS+=(-P "$MQTT_PASSWORD")
    fi
    
    # Add SSL options
    if [ "$USE_SSL" = "true" ]; then
        BASE_ARGS+=(--ssl)
        
        if [ -n "$SSL_CA_CERT" ]; then
            BASE_ARGS+=(--cacertfile "$SSL_CA_CERT")
        fi
        
        if [ -n "$SSL_CERT" ]; then
            BASE_ARGS+=(--certfile "$SSL_CERT")
        fi
        
        if [ -n "$SSL_KEY" ]; then
            BASE_ARGS+=(--keyfile "$SSL_KEY")
        fi
        
        if [ -n "$SSL_VERSION" ]; then
            BASE_ARGS+=(--ssl-version "$SSL_VERSION")
        fi
    fi
    
    if [ "$USE_WEBSOCKET" = "true" ]; then
        BASE_ARGS+=(--ws)
    fi
    
    # Build test-specific arguments
    # For connect: only base args (no topic, interval, payload, qos)
    # For publish/subscribe/full: add topic, interval, payload, qos
    PUB_SUB_ARGS=(
        -t "$TOPIC"
        -i "$INTERVAL"
        -s "$PAYLOAD_SIZE"
        -q "$QOS"
    )
    
    # Test log file (separate from startup log)
    LOG_FILE="$LOG_DIR/test-$(date +%Y%m%d-%H%M%S).log"
    
    log_info "Test logs will be saved to: $LOG_FILE"
    log_info "Startup logs: $STARTUP_LOG_FILE"
    
    # Write test configuration to log file
    {
        echo "=========================================="
        echo "MQTT Stress Test Configuration"
        echo "Started: $(date)"
        echo "=========================================="
        echo "MQTT Host: $MQTT_HOST"
        echo "MQTT Port: $MQTT_PORT"
        echo "Use SSL: $USE_SSL"
        echo "Test Type: $TEST_TYPE"
        echo "Connections: $CONNECTIONS"
        echo "Interval: ${INTERVAL}ms"
        echo "Topic: $TOPIC"
        echo "Payload Size: $PAYLOAD_SIZE bytes"
        echo "QoS: $QOS"
        echo "Duration: ${DURATION}s"
        echo "=========================================="
        echo ""
    } >> "$LOG_FILE"
    
    # Execute test based on type
    log_info "Starting test type: $TEST_TYPE"
    
    TEST_EXIT_CODE=0
    case "$TEST_TYPE" in
        connect)
            log_info "Running connection test..."
            # For connect test: only use base args (no topic, interval, payload, qos)
            CONN_ARGS=("${BASE_ARGS[@]}")
            log_info "Command: $EMQTT_BENCH_BIN conn ${CONN_ARGS[*]}"
            if ! "$EMQTT_BENCH_BIN" conn "${CONN_ARGS[@]}" 2>&1 | tee -a "$LOG_FILE"; then
                TEST_EXIT_CODE=$?
                log_error "Connection test failed with exit code: $TEST_EXIT_CODE"
            else
                log_info "Connection test completed successfully"
            fi
            ;;
        publish)
            log_info "Running publish test..."
            # For publish: base args + topic, interval, payload, qos
            PUB_ARGS=("${BASE_ARGS[@]}" "${PUB_SUB_ARGS[@]}")
            # Calculate approximate message count based on duration
            MSG_COUNT=$((DURATION * 1000 / INTERVAL))
            if [ "$MSG_COUNT" -eq 0 ]; then
                MSG_COUNT=1
            fi
            PUB_ARGS+=(-L "$MSG_COUNT")
            log_info "Command: $EMQTT_BENCH_BIN pub ${PUB_ARGS[*]}"
            if ! "$EMQTT_BENCH_BIN" pub "${PUB_ARGS[@]}" 2>&1 | tee -a "$LOG_FILE"; then
                TEST_EXIT_CODE=$?
                log_error "Publish test failed with exit code: $TEST_EXIT_CODE"
            else
                log_info "Publish test completed successfully"
            fi
            ;;
        subscribe)
            log_info "Running subscribe test..."
            # For subscribe: base args + topic, interval, payload, qos
            SUB_ARGS=("${BASE_ARGS[@]}" "${PUB_SUB_ARGS[@]}")
            log_info "Command: timeout $DURATION $EMQTT_BENCH_BIN sub ${SUB_ARGS[*]}"
            if ! timeout "$DURATION" "$EMQTT_BENCH_BIN" sub "${SUB_ARGS[@]}" 2>&1 | tee -a "$LOG_FILE"; then
                TEST_EXIT_CODE=$?
                # Timeout exit code is 124, which is expected
                if [ "$TEST_EXIT_CODE" -eq 124 ]; then
                    log_info "Subscribe test completed (timeout after ${DURATION}s)"
                    TEST_EXIT_CODE=0
                else
                    log_error "Subscribe test failed with exit code: $TEST_EXIT_CODE"
                fi
            else
                log_info "Subscribe test completed successfully"
            fi
            ;;
        full)
            log_info "Running full test (publish + subscribe)..."
            
            # For full test: base args + topic, interval, payload, qos
            SUB_ARGS=("${BASE_ARGS[@]}" "${PUB_SUB_ARGS[@]}")
            PUB_ARGS=("${BASE_ARGS[@]}" "${PUB_SUB_ARGS[@]}")
            
            # Start subscribers in background
            log_info "Starting subscribers..."
            log_info "Subscriber command: $EMQTT_BENCH_BIN sub ${SUB_ARGS[*]}"
            "$EMQTT_BENCH_BIN" sub "${SUB_ARGS[@]}" >> "$LOG_DIR/subscribe.log" 2>&1 &
            SUB_PID=$!
            log_info "Subscriber started with PID: $SUB_PID"
            log_info "Subscriber logs: $LOG_DIR/subscribe.log"
            
            # Wait a bit for subscribers to connect
            sleep 5
            
            # Check if subscriber process is still running
            if ! kill -0 $SUB_PID 2>/dev/null; then
                log_error "Subscriber process failed to start"
                log_error "Check subscriber log: $LOG_DIR/subscribe.log"
                TEST_EXIT_CODE=1
            else
                # Start publishers
                log_info "Starting publishers..."
                MSG_COUNT=$((DURATION * 1000 / INTERVAL))
                if [ "$MSG_COUNT" -eq 0 ]; then
                    MSG_COUNT=1
                fi
                PUB_ARGS+=(-L "$MSG_COUNT")
                log_info "Publisher command: $EMQTT_BENCH_BIN pub ${PUB_ARGS[*]}"
                if ! "$EMQTT_BENCH_BIN" pub "${PUB_ARGS[@]}" 2>&1 | tee -a "$LOG_FILE"; then
                    TEST_EXIT_CODE=$?
                    log_error "Publish test failed with exit code: $TEST_EXIT_CODE"
                else
                    log_info "Publish test completed successfully"
                fi
                
                # Wait a bit then stop subscribers
                sleep 5
                if kill $SUB_PID 2>/dev/null; then
                    wait $SUB_PID 2>/dev/null || true
                    log_info "Subscribers stopped"
                fi
                
                # Append subscriber log to main log
                if [ -f "$LOG_DIR/subscribe.log" ]; then
                    {
                        echo ""
                        echo "=========================================="
                        echo "Subscriber Log"
                        echo "=========================================="
                        cat "$LOG_DIR/subscribe.log"
                    } >> "$LOG_FILE"
                fi
            fi
            ;;
        *)
            log_error "Unknown test type: $TEST_TYPE"
            log_info "Available test types: connect, publish, subscribe, full"
            exit 1
            ;;
    esac
    
    # Write summary to both logs
    {
        echo ""
        echo "=========================================="
        echo "Test Summary"
        echo "Completed: $(date)"
        echo "Exit Code: $TEST_EXIT_CODE"
        echo "Test Log: $LOG_FILE"
        echo "=========================================="
    } >> "$LOG_FILE"
    
    {
        echo ""
        echo "=========================================="
        echo "Startup Script Summary"
        echo "Completed: $(date)"
        echo "Test Exit Code: $TEST_EXIT_CODE"
        echo "Test Log: $LOG_FILE"
        echo "Startup Log: $STARTUP_LOG_FILE"
        echo "=========================================="
    } >> "$STARTUP_LOG_FILE"
    
    log_info "Test completed. Logs saved to: $LOG_FILE"
    log_info "Startup log saved to: $STARTUP_LOG_FILE"
    
    # List all log files
    log_info "All log files in $LOG_DIR:"
    ls -lh "$LOG_DIR" | tail -n +2 | while read -r line; do
        log_info "  $line"
    done
    
    if [ "$TEST_EXIT_CODE" -eq 0 ]; then
        log_info "Setup and test execution finished successfully"
    else
        log_error "Test execution finished with errors (exit code: $TEST_EXIT_CODE)"
        exit $TEST_EXIT_CODE
    fi
}

# Run main function
main "$@"

