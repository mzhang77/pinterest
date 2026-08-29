#!/usr/bin/env bash

set -euo pipefail

cluster_name="pingraph-notifications-prod"
begin="2026-08-28 19:45:00"
end="2026-08-28 20:15:00"
interval=10

current="$begin"

while [[ "$current" < "$end" ]]; do
    next=$(
        python3 - "$current" "$interval" <<'PY'
import sys
from datetime import datetime, timedelta

current = datetime.strptime(sys.argv[1], "%Y-%m-%d %H:%M:%S")
interval_minutes = int(sys.argv[2])

if interval_minutes <= 0:
    raise SystemExit("interval must be a positive number of minutes")

next_time = current + timedelta(minutes=interval_minutes)

print(next_time.strftime("%Y-%m-%d %H:%M:%S"))
PY
    )

    if [[ "$next" > "$end" ]]; then
        next="$end"
    fi

    echo "Running: $cluster_name, $current -> $next"

    tiup_metrics.sh "$cluster_name" "$current" "$next"

    current="$next"
done