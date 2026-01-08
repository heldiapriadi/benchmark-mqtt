#!/bin/bash
set -eux

META="http://metadata.google.internal/computeMetadata/v1/instance/attributes"
HDR="Metadata-Flavor: Google"

get_meta () {
  curl -sf -H "$HDR" "$META/$1"
}

LOG_FILE=/var/log/emqtt-bench.log
exec > >(tee -a $LOG_FILE) 2>&1

# ================= METADATA =================
TEST_MODE=$(get_meta test_mode)
BROKER_HOST=$(get_meta broker_host)
BROKER_PORT=$(get_meta broker_port)
USERNAME=$(get_meta username)
PASSWORD=$(get_meta password)
TOPIC=$(get_meta topic)
QOS=$(get_meta qos)

SSL_ENABLED=$(get_meta ssl_enabled || echo "true")
CLIENTS=$(get_meta clients || echo "1000")
RATE=$(get_meta rate || echo "100")
DURATION=$(get_meta duration || echo "60")
# ============================================

SSL_OPTS=""
[ "$SSL_ENABLED" = "true" ] && SSL_OPTS="--ssl"

# ---------- Install deps ----------
apt-get update -y
apt-get install -y git build-essential ca-certificates \
  erlang-base erlang-dev erlang-crypto

cd /opt
[ -d emqtt-bench ] || git clone https://github.com/emqx/emqtt-bench.git
cd emqtt-bench && make

BIN=./_build/default/bin/emqtt_bench

echo "=== TEST MODE: $TEST_MODE ==="

case "$TEST_MODE" in
  conn)
    $BIN conn \
      -h "$BROKER_HOST" \
      -p "$BROKER_PORT" \
      -c "$CLIENTS" \
      -u "$USERNAME" \
      -P "$PASSWORD" \
      $SSL_OPTS \
      --time "$DURATION"
    ;;

  pub)
    $BIN pub \
      -h "$BROKER_HOST" \
      -p "$BROKER_PORT" \
      -c "$CLIENTS" \
      -I "$RATE" \
      -t "$TOPIC" \
      -q "$QOS" \
      -u "$USERNAME" \
      -P "$PASSWORD" \
      $SSL_OPTS \
      --time "$DURATION"
    ;;

  sub)
    $BIN sub \
      -h "$BROKER_HOST" \
      -p "$BROKER_PORT" \
      -c "$CLIENTS" \
      -t "$TOPIC" \
      -q "$QOS" \
      -u "$USERNAME" \
      -P "$PASSWORD" \
      $SSL_OPTS \
      --time "$DURATION"
    ;;

  full)
    $BIN conn \
      -h "$BROKER_HOST" \
      -p "$BROKER_PORT" \
      -c "$CLIENTS" \
      -u "$USERNAME" \
      -P "$PASSWORD" \
      $SSL_OPTS \
      --time 10

    sleep 5

    $BIN pub \
      -h "$BROKER_HOST" \
      -p "$BROKER_PORT" \
      -c "$CLIENTS" \
      -I "$RATE" \
      -t "$TOPIC" \
      -q "$QOS" \
      -u "$USERNAME" \
      -P "$PASSWORD" \
      $SSL_OPTS \
      --time "$DURATION"

    sleep 5

    $BIN sub \
      -h "$BROKER_HOST" \
      -p "$BROKER_PORT" \
      -c "$CLIENTS" \
      -t "$TOPIC" \
      -q "$QOS" \
      -u "$USERNAME" \
      -P "$PASSWORD" \
      $SSL_OPTS \
      --time "$DURATION"
    ;;

  *)
    echo "INVALID test_mode: $TEST_MODE"
    exit 1
    ;;
esac

echo "=== TEST FINISHED ==="
