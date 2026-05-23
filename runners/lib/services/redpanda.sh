#!/usr/bin/env bash
# Sourced when an example's manifest entry has `redpanda` in its `services` list.
# Starts a single-broker Redpanda (Kafka API at localhost:9092) in a Docker
# container. Used by the example-kafka-worker-* examples; their client code
# hardcodes localhost:9092 with no SASL.

REDPANDA_IMAGE="${REDPANDA_IMAGE:-docker.redpanda.com/redpandadata/redpanda:v24.3.5}"
REDPANDA_CONTAINER="${REDPANDA_CONTAINER:-redpanda-ci}"

start_redpanda() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "redpanda: docker not in PATH" >&2
    return 1
  fi

  # Defensive: a previous (failed) run may have left the container around.
  docker rm -f "$REDPANDA_CONTAINER" >/dev/null 2>&1 || true

  docker run -d --rm --name "$REDPANDA_CONTAINER" \
    -p 9092:9092 \
    "$REDPANDA_IMAGE" \
    redpanda start \
    --smp=1 \
    --reserve-memory=0M \
    --overprovisioned \
    --node-id=0 \
    --check=false \
    --kafka-addr=0.0.0.0:9092 \
    --advertise-kafka-addr=localhost:9092 \
    > /tmp/redpanda.start.log 2>&1
  if [ $? -ne 0 ]; then
    echo "redpanda: docker run failed" >&2
    cat /tmp/redpanda.start.log >&2 2>/dev/null || true
    return 1
  fi

  # Wait for the Kafka API to actually accept connections. Port-open is not
  # enough — Redpanda binds the listener before it's ready to serve metadata.
  # `rpk cluster info` is the lightest "cluster is up" probe.
  local i
  for i in $(seq 1 60); do
    if docker exec "$REDPANDA_CONTAINER" rpk cluster info --brokers localhost:9092 >/dev/null 2>&1; then
      echo "redpanda: ready (container=$REDPANDA_CONTAINER)" >&2
      return 0
    fi
    # Surface a fast-fail if the container died.
    if ! docker inspect -f '{{.State.Running}}' "$REDPANDA_CONTAINER" 2>/dev/null | grep -q true; then
      echo "redpanda: container exited before ready" >&2
      docker logs "$REDPANDA_CONTAINER" 2>&1 | tail -n 50 >&2 || true
      return 1
    fi
    sleep 1
  done

  echo "redpanda: did not become ready within 60s" >&2
  docker logs "$REDPANDA_CONTAINER" 2>&1 | tail -n 50 >&2 || true
  return 1
}

stop_redpanda() {
  docker rm -f "$REDPANDA_CONTAINER" >/dev/null 2>&1 || true
}
