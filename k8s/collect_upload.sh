
#!/usr/bin/env bash
set -euo pipefail

BASE_URL="http://localhost:4917"
CLUSTER_NAME="pingraph-shared4-prod-eks"
NAMESPACE="pingraph-shared4-prod"

START="2026-06-26 22:30:00"
END="2026-06-26 23:30:00"
STEP_MINUTES=10

current="$START"

while [[ "$current" < "$END" ]]; do
  ts=$(date -d "$current" +%s)
  next=$(date -d "@$((ts + STEP_MINUTES * 60))" "+%Y-%m-%d %H:%M:%S")

  echo "Collecting from $current to $next"


  resp=$(curl -s "$BASE_URL/api/v1/collectors" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "{\"clusterName\":\"$CLUSTER_NAME\",\"namespace\":\"$NAMESPACE\",\"from\":\"$current\",\"to\":\"$next\"}")

  id=$(echo "$resp" | jq -r '.id')
  if [[ -z "$id" || "$id" == "null" ]]; then
    echo "Failed to create collector:"
    echo "$resp" | jq .
    exit 1
  fi
  echo "Collector id: $id"

  while true; do
    status=$(curl -s "$BASE_URL/api/v1/collectors/$id" \
      -H "accept: application/json" | jq -r '.status')

    echo "Collector status: $status"

    if [[ "$status" == "finished" ]]; then
      break
    elif [[ "$status" == "failed" || "$status" == "error" ]]; then
      echo "Collector failed: $id"
      exit 1
    fi

    sleep 60
  done

  echo "Uploading $id"

#  upload_start_resp=$(curl -s -X POST "$BASE_URL/api/v1/data/$id/upload?rebuild=false" \
  upload_start_resp=$(curl -s -X POST "$BASE_URL/api/v1/data/$id/upload" \
    -H "accept: application/json")

  echo "$upload_start_resp" | jq .

  while true; do
    upload_resp=$(curl -s "$BASE_URL/api/v1/data/$id/upload" \
      -H "accept: application/json")

    upload_status=$(echo "$upload_resp" | jq -r '.status')
    echo "Upload status: $upload_status"

    if [[ "$upload_status" == "finished" ]]; then
      echo "$upload_resp" | jq .
      break
    elif [[ "$upload_status" == "failed" || "$upload_status" == "error" ]]; then
      echo "Upload failed: $id"
      echo "$upload_resp" | jq .
      exit 1
    fi

    sleep 60
  done

  current="$next"
done
