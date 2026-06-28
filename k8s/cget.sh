
#!/usr/bin/env bash

set -euo pipefail

id="${1:-}"

if [[ -z "$id" ]]; then
    echo "Usage: $(basename "$0") <collector_id>"
    exit 1
fi

curl -sS -X GET \
    "http://localhost:4917/api/v1/collectors/${id}" \
    -H "accept: application/json" | jq