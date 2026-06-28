
#!/usr/bin/env bash

set -euo pipefail

curl -sS -X GET \
    "http://localhost:4917/api/v1/collectors" \
    -H "accept: application/json" \
    | jq 'sort_by(.date)'