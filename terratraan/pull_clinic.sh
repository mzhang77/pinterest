#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "${SCRIPT_DIR}/env.sh"

cluster_name="$CLINIC_CLUSTER"
begin="$CLINIC_BEGIN_TIME"
end="$CLINIC_END_TIME"
interval="$CLINIC_INTERVAL_MINUTES"

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

    "$TIUP_METRICS_SCRIPT" "$cluster_name" "$current" "$next"

    current="$next"
done
