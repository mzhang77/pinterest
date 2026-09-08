
#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "${SCRIPT_DIR}/env.sh"

id="${1:-}"

if [[ -z "$id" ]]; then
    echo "Usage: $(basename "$0") <collector_id>"
    exit 1
fi

curl -sS -X GET \
    "${DIAG_BASE_URL}/api/v1/collectors/${id}" \
    -H "accept: application/json" | jq
