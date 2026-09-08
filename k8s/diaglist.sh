
#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "${SCRIPT_DIR}/env.sh"

curl -sS -X GET \
    "${DIAG_BASE_URL}/api/v1/collectors" \
    -H "accept: application/json" \
    | jq 'sort_by(.date)'
