#!/bin/bash
#
# Generates 1MB Kubernetes Secrets to fill etcd storage.
# Simulates a customer workload creating many large secrets
# (e.g., misconfigured cert rotation, CI/CD pipeline leak).
#
# Environment variables:
#   SECRET_SIZE_BYTES - Size of each secret's data (default: 1048576 = 1MB)
#   SECRET_PREFIX     - Name prefix for secrets (default: pressure-test)
#   NAMESPACE         - Target namespace (default: default)
#   KUBEAPI_HOST      - Kubernetes API host (default: https://kubernetes.default.svc)
#   MAX_SECRETS       - Stop after this many secrets (default: 0 = unlimited)
#   CONCURRENCY       - Number of parallel requests (default: 10)
#
# Runs until stopped (Ctrl+C) or MAX_SECRETS is reached.

set -euo pipefail

SECRET_SIZE_BYTES="${SECRET_SIZE_BYTES:-1048576}"
SECRET_PREFIX="${SECRET_PREFIX:-pressure-test}"
NAMESPACE="${NAMESPACE:-default}"
KUBEAPI_HOST="${KUBEAPI_HOST:-https://kubernetes.default.svc}"
MAX_SECRETS="${MAX_SECRETS:-0}"
CONCURRENCY="${CONCURRENCY:-10}"

TOKEN_FILE="/var/run/secrets/kubernetes.io/serviceaccount/token"
CA_FILE="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"

if [ ! -f "$TOKEN_FILE" ]; then
  echo "Error: Service account token not found at $TOKEN_FILE"
  echo "This tool must run inside a Kubernetes pod with a service account."
  exit 1
fi

TOKEN=$(cat "$TOKEN_FILE")
API_URL="${KUBEAPI_HOST}/api/v1/namespaces/${NAMESPACE}/secrets"

# Pre-generate the static tail (everything after the secret name).
# Each request prepends a small header with the unique name.
TAIL_FILE="/tmp/tail.json"
RESULTS_DIR="/tmp/results"
mkdir -p "$RESULTS_DIR"
trap "rm -rf $TAIL_FILE $RESULTS_DIR /tmp/body-*" EXIT

RAW_BYTES=$(( SECRET_SIZE_BYTES * 3 / 4 ))
printf '","labels":{"app":"etcd-secret-generator"}},"data":{"payload":"' > "$TAIL_FILE"
head -c "$RAW_BYTES" /dev/urandom | base64 -w 0 >> "$TAIL_FILE"
printf '"}}' >> "$TAIL_FILE"

echo "Starting secret generation:"
echo "  Size:        ${SECRET_SIZE_BYTES} bytes per secret"
echo "  Prefix:      ${SECRET_PREFIX}"
echo "  Namespace:   ${NAMESPACE}"
echo "  Max:         ${MAX_SECRETS:-unlimited}"
echo "  Concurrency: ${CONCURRENCY}"
echo ""

created=0
errors=0
start_time=$(date +%s)

create_secret() {
  local secret_name="$1"
  local slot="$2"
  local body_file="/tmp/body-${slot}"

  printf '{"apiVersion":"v1","kind":"Secret","metadata":{"name":"%s' "$secret_name" > "$body_file"
  cat "$TAIL_FILE" >> "$body_file"

  curl -s -o /dev/null -w "%{http_code}" \
    --cacert "$CA_FILE" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -X POST "${API_URL}" \
    -d @"$body_file" > "$RESULTS_DIR/$secret_name"
}

count=0
batch=0

while true; do
  # Launch a batch of concurrent requests
  pids=()
  batch_names=()

  for ((slot=0; slot<CONCURRENCY; slot++)); do
    count=$((count + 1))

    if [ "$MAX_SECRETS" -gt 0 ] && [ "$count" -gt "$MAX_SECRETS" ]; then
      break
    fi

    secret_name="${SECRET_PREFIX}-$(printf '%05d' $count)"
    batch_names+=("$secret_name")
    create_secret "$secret_name" "$slot" &
    pids+=($!)
  done

  # Wait for all in this batch
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done

  # Collect results
  for name in "${batch_names[@]}"; do
    if [ -f "$RESULTS_DIR/$name" ]; then
      code=$(cat "$RESULTS_DIR/$name")
      if [ "$code" = "201" ]; then
        created=$((created + 1))
      else
        errors=$((errors + 1))
        echo "  Error creating ${name}: HTTP ${code}"
      fi
      rm -f "$RESULTS_DIR/$name"
    fi
  done

  batch=$((batch + 1))
  if [ $((batch % 10)) -eq 0 ]; then
    elapsed=$(( $(date +%s) - start_time ))
    total_mb=$(( created * SECRET_SIZE_BYTES / 1048576 ))
    rate=0
    if [ "$elapsed" -gt 0 ]; then
      rate=$(( created / elapsed ))
    fi
    echo "Progress: ${created} created, ${errors} errors, ${total_mb}MB total, ${elapsed}s elapsed (~${rate}/s)"
  fi

  if [ "$MAX_SECRETS" -gt 0 ] && [ "$count" -ge "$MAX_SECRETS" ]; then
    break
  fi
done

elapsed=$(( $(date +%s) - start_time ))
total_mb=$(( created * SECRET_SIZE_BYTES / 1048576 ))
echo ""
echo "Done: ${created} secrets created (${errors} errors), ${total_mb}MB total, ${elapsed}s elapsed"
