#!/usr/bin/env bash

set -uo pipefail

###############################################################################
# Configuration
###############################################################################

cluster_name="pingraph-socialgraph-prod-eks"
namespace="pingraph-socialgraph-prod"

begin="2026-07-23 08:00:00"
end="2026-07-23 08:30:00"

# Interval in minutes.
interval=10

# Summary file containing each time range, local data directory, and Clinic URL.
summary_file="./diag_upload_summary_$(date '+%Y%m%d_%H%M%S').txt"


###############################################################################
# Validation
###############################################################################

if ! command -v tiup >/dev/null 2>&1; then
    echo "ERROR: tiup is not installed or is not in PATH." >&2
    exit 1
fi

if ! [[ "$interval" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: interval must be a positive integer representing minutes." >&2
    exit 1
fi

begin_epoch=$(date -d "$begin" '+%s' 2>/dev/null) || {
    echo "ERROR: Invalid begin time: $begin" >&2
    exit 1
}

end_epoch=$(date -d "$end" '+%s' 2>/dev/null) || {
    echo "ERROR: Invalid end time: $end" >&2
    exit 1
}

if (( begin_epoch >= end_epoch )); then
    echo "ERROR: begin must be earlier than end." >&2
    exit 1
fi

interval_seconds=$((interval * 60))


###############################################################################
# Initialization
###############################################################################

cat > "$summary_file" <<EOF
Cluster:   $cluster_name
Namespace: $namespace
Begin:     $begin
End:       $end
Interval:  $interval minutes

EOF

current_epoch=$begin_epoch
chunk_number=1
success_count=0
failure_count=0


###############################################################################
# Collection and upload loop
###############################################################################

while (( current_epoch < end_epoch )); do
    chunk_end_epoch=$((current_epoch + interval_seconds))

    # Do not go beyond the requested end time.
    if (( chunk_end_epoch > end_epoch )); then
        chunk_end_epoch=$end_epoch
    fi

    chunk_begin=$(date -d "@$current_epoch" '+%Y-%m-%d %H:%M:%S')
    chunk_end=$(date -d "@$chunk_end_epoch" '+%Y-%m-%d %H:%M:%S')

    echo
    echo "======================================================================"
    echo "Chunk $chunk_number"
    echo "Time range: $chunk_begin -> $chunk_end"
    echo "======================================================================"

    collect_log=$(mktemp "/tmp/diag_collect_${chunk_number}_XXXXXX.log")
    upload_log=$(mktemp "/tmp/diag_upload_${chunk_number}_XXXXXX.log")

    echo "Running collectk..."

    tiup diag collectk "$cluster_name" \
        --namespace "$namespace" \
        --from "$chunk_begin" \
        --to "$chunk_end" \
        -y 2>&1 | tee "$collect_log"

    collect_status=${PIPESTATUS[0]}

    if (( collect_status != 0 )); then
        echo "ERROR: collectk failed for $chunk_begin -> $chunk_end" >&2

        {
            echo "[$chunk_number] FAILED: collection"
            echo "Time range: $chunk_begin -> $chunk_end"
            echo "Collect log: $collect_log"
            echo
        } >> "$summary_file"

        rm -f "$upload_log"
        failure_count=$((failure_count + 1))
        current_epoch=$chunk_end_epoch
        chunk_number=$((chunk_number + 1))
        continue
    fi

    # Expected output:
    # Collected data are stored in /home/.../diag-cluster-xxxxxxxx
    data_dir=$(
        sed -n \
            's/^Collected data are stored in[[:space:]]\+//p' \
            "$collect_log" |
        tail -n 1
    )

    # Fallback for output such as:
    # These data will be stored in /home/.../diag-cluster-xxxxxxxx
    if [[ -z "$data_dir" ]]; then
        data_dir=$(
            sed -n \
                's/^These data will be stored in[[:space:]]\+//p' \
                "$collect_log" |
            tail -n 1
        )
    fi

    if [[ -z "$data_dir" ]]; then
        echo "ERROR: Could not determine the collected data directory." >&2

        {
            echo "[$chunk_number] FAILED: data directory not found"
            echo "Time range: $chunk_begin -> $chunk_end"
            echo "Collect log: $collect_log"
            echo
        } >> "$summary_file"

        rm -f "$upload_log"
        failure_count=$((failure_count + 1))
        current_epoch=$chunk_end_epoch
        chunk_number=$((chunk_number + 1))
        continue
    fi

    if [[ ! -d "$data_dir" ]]; then
        echo "ERROR: Collected data directory does not exist: $data_dir" >&2

        {
            echo "[$chunk_number] FAILED: data directory does not exist"
            echo "Time range: $chunk_begin -> $chunk_end"
            echo "Data directory: $data_dir"
            echo "Collect log: $collect_log"
            echo
        } >> "$summary_file"

        rm -f "$upload_log"
        failure_count=$((failure_count + 1))
        current_epoch=$chunk_end_epoch
        chunk_number=$((chunk_number + 1))
        continue
    fi

    echo
    echo "Collected data directory: $data_dir"
    echo "Uploading collected data..."

    tiup diag config clinic.token eyJrIjoiNmZpd3lOQUk0YVZqNjg3UiIsInUiOjUxOCwiaWQiOjEzNzI4MTMwODkxOTU2NTEyODZ9
    tiup diag config clinic.region US
    tiup diag upload "$data_dir" 2>&1 | tee "$upload_log"

    upload_status=${PIPESTATUS[0]}

    if (( upload_status != 0 )); then
        echo "ERROR: Upload failed for $data_dir" >&2

        {
            echo "[$chunk_number] FAILED: upload"
            echo "Time range: $chunk_begin -> $chunk_end"
            echo "Data directory: $data_dir"
            echo "Collect log: $collect_log"
            echo "Upload log: $upload_log"
            echo
        } >> "$summary_file"

        failure_count=$((failure_count + 1))
        current_epoch=$chunk_end_epoch
        chunk_number=$((chunk_number + 1))
        continue
    fi

    download_url=$(
        sed -n 's/^Download URL:[[:space:]]*//p' "$upload_log" |
        tail -n 1
    )

    echo
    echo "Chunk $chunk_number completed successfully."

    {
        echo "[$chunk_number] SUCCESS"
        echo "Time range: $chunk_begin -> $chunk_end"
        echo "Data directory: $data_dir"
        echo "Download URL: ${download_url:-Not found in upload output}"
        echo
    } >> "$summary_file"

    success_count=$((success_count + 1))
    current_epoch=$chunk_end_epoch
    chunk_number=$((chunk_number + 1))
done


###############################################################################
# Final result
###############################################################################

echo
echo "======================================================================"
echo "All requested time ranges have been processed."
echo "Successful chunks: $success_count"
echo "Failed chunks:     $failure_count"
echo "Summary file:      $summary_file"
echo "======================================================================"

if (( failure_count > 0 )); then
    exit 1
fi