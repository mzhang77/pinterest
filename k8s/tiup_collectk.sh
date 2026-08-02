#!/usr/bin/env bash

set -uo pipefail

###############################################################################
# Configuration
###############################################################################

cluster_name="pingraph-shared5-prod-eks"
namespace="pingraph-shared5-prod"

begin="2026-07-29 11:30:00"
end="2026-07-30 11:30:00"

# Interval in minutes.
interval=10

# Upload switch. It can also be overridden when starting the script, for example:
# UPLOAD_ENABLED=true CLINIC_TOKEN_FILE=/path/to/token ./tiup_collectk.sh
upload_enabled="${UPLOAD_ENABLED:-false}"
clinic_region="${CLINIC_REGION:-US}"

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

case "$upload_enabled" in
    true|false)
        ;;
    *)
        echo "ERROR: UPLOAD_ENABLED must be either true or false." >&2
        exit 1
        ;;
esac

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

if [[ "$upload_enabled" == "true" ]]; then
    clinic_token="${CLINIC_TOKEN:-}"
    configure_clinic_token=false

    if [[ -n "${CLINIC_TOKEN_FILE:-}" ]]; then
        if [[ ! -e "$CLINIC_TOKEN_FILE" ]]; then
            echo "WARNING: Clinic token file does not exist: $CLINIC_TOKEN_FILE" >&2
            echo "WARNING: Assuming the Clinic token is already configured; continuing." >&2
        elif [[ ! -r "$CLINIC_TOKEN_FILE" ]]; then
            echo "WARNING: Clinic token file is not readable: $CLINIC_TOKEN_FILE" >&2
            echo "WARNING: Assuming the Clinic token is already configured; continuing." >&2
        else
            clinic_token=$(<"$CLINIC_TOKEN_FILE")

            if [[ -z "$clinic_token" ]]; then
                echo "WARNING: Clinic token file is empty: $CLINIC_TOKEN_FILE" >&2
                echo "WARNING: Assuming the Clinic token is already configured; continuing." >&2
            else
                configure_clinic_token=true
            fi
        fi
    elif [[ -n "$clinic_token" ]]; then
        configure_clinic_token=true
    else
        echo "WARNING: No Clinic token was provided." >&2
        echo "WARNING: Assuming the Clinic token is already configured; continuing." >&2
    fi

    if [[ "$configure_clinic_token" == "true" ]]; then
        if ! tiup diag config clinic.token "$clinic_token"; then
            echo "ERROR: Failed to configure the Clinic token." >&2
            exit 1
        fi
    fi

    if ! tiup diag config clinic.region "$clinic_region"; then
        echo "ERROR: Failed to configure Clinic region: $clinic_region" >&2
        exit 1
    fi

    # Do not leave the token in this shell's variables longer than necessary.
    unset clinic_token configure_clinic_token
fi


###############################################################################
# Initialization
###############################################################################

cat > "$summary_file" <<EOF
Cluster:   $cluster_name
Namespace: $namespace
Begin:     $begin
End:       $end
Interval:  $interval minutes
Upload:    $upload_enabled
$([[ "$upload_enabled" == "true" ]] && printf 'Region:    %s\n' "$clinic_region")

EOF

current_epoch=$begin_epoch
chunk_number=1
success_count=0
failure_count=0
upload_count=0
upload_skipped_count=0


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

    if ! collect_log=$(mktemp "${TMPDIR:-/tmp}/diag_collect_${chunk_number}.XXXXXX"); then
        echo "ERROR: Could not create a temporary collection log." >&2
        exit 1
    fi

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

        failure_count=$((failure_count + 1))
        current_epoch=$chunk_end_epoch
        chunk_number=$((chunk_number + 1))
        continue
    fi

    # Expected output:
    # Collected data are stored in /home/.../diag-cluster-xxxxxxxx
    data_dir=$(
        sed -n \
            's/^Collected data are stored in[[:space:]][[:space:]]*//p' \
            "$collect_log" |
        tail -n 1
    )

    # Fallback for output such as:
    # These data will be stored in /home/.../diag-cluster-xxxxxxxx
    if [[ -z "$data_dir" ]]; then
        data_dir=$(
            sed -n \
                's/^These data will be stored in[[:space:]][[:space:]]*//p' \
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

        failure_count=$((failure_count + 1))
        current_epoch=$chunk_end_epoch
        chunk_number=$((chunk_number + 1))
        continue
    fi

    echo
    echo "Collected data directory: $data_dir"

    if [[ "$upload_enabled" == "false" ]]; then
        echo "Upload is disabled; keeping the collected data locally."

        {
            echo "[$chunk_number] COLLECTED"
            echo "Time range: $chunk_begin -> $chunk_end"
            echo "Data directory: $data_dir"
            echo "Collect log: $collect_log"
            echo "Upload: skipped (disabled)"
            echo
        } >> "$summary_file"

        success_count=$((success_count + 1))
        upload_skipped_count=$((upload_skipped_count + 1))
        current_epoch=$chunk_end_epoch
        chunk_number=$((chunk_number + 1))
        continue
    fi

    if ! upload_log=$(mktemp "${TMPDIR:-/tmp}/diag_upload_${chunk_number}.XXXXXX"); then
        echo "ERROR: Could not create a temporary upload log." >&2
        exit 1
    fi

    echo "Uploading collected data..."

    echo "Uploading $data_dir..."
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
    upload_count=$((upload_count + 1))
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
echo "Uploaded chunks:   $upload_count"
echo "Uploads skipped:   $upload_skipped_count"
echo "Summary file:      $summary_file"
echo "======================================================================"

if (( failure_count > 0 )); then
    exit 1
fi
