
#!/bin/bash
set -u

BEGIN_TIME="2025/06/14 00:00:00 +00:00"
END_TIME="2027/06/15 00:00:00 +00:00"

NS="bulk-ingestion-prod"
REMOTE_LOG_DIR="/var/log/tidb"
REMOTE_TMP_BASE="/tmp/tikv-log-collect"
LOCAL_OUT_DIR="./tikv_logs_$(date +%Y%m%d_%H%M%S)"

mkdir -p "$LOCAL_OUT_DIR"

SUMMARY_FILE="${LOCAL_OUT_DIR}/collection_summary.txt"

{
    echo "namespace=${NS}"
    echo "begin_time=${BEGIN_TIME}"
    echo "end_time=${END_TIME}"
    echo
} > "$SUMMARY_FILE"

pods=$(kubectl get pod -n "$NS" -o name | grep 'tikv-' | sed 's#pod/##')

for pod in $pods; do
    echo "===== Processing $pod ====="

    remote_tmp="${REMOTE_TMP_BASE}/${pod}"
    local_pod_dir="${LOCAL_OUT_DIR}/${pod}"

    mkdir -p "$local_pod_dir"

    kubectl exec -n "$NS" "$pod" -- bash -c "
        rm -rf '${remote_tmp}'
        mkdir -p '${remote_tmp}'
    " || {
        echo "WARN: failed to prepare remote tmp for $pod"
        continue
    }

    files=$(
        kubectl exec -n "$NS" "$pod" -- bash -c "
            cd '${REMOTE_LOG_DIR}' || exit 1

            if [ -f tikv.log ]; then
                echo tikv.log
            fi

            ls -1t tikv*.log 2>/dev/null \
                | grep -v '^tikv.log$' \
                | grep -v '^tikv-slow.log$' || true
        " | sed '/^Defaulted container /d'
    )

    for f in $files; do
        echo "[$pod] filtering and compressing $f"

        remote_gz="${remote_tmp}/${f}.filtered.gz"

        kubectl exec -n "$NS" "$pod" -- bash -c "
            cd '${REMOTE_LOG_DIR}' &&
            awk -v begin='${BEGIN_TIME}' -v end='${END_TIME}' '
                match(\$0, /\"time\":\"[^\"]+\"/) {
                    t = substr(\$0, RSTART + 8, RLENGTH - 8)
                    if (t >= begin && t <= end) {
                        print
                    }
                }
            ' '$f' | gzip -c > '${remote_gz}'
        "

        if [ $? -ne 0 ]; then
            echo "WARN: failed to filter/gzip $pod/$f, skip"
            continue
        fi

        echo "[$pod] copying filtered $f"

        kubectl cp \
            -n "$NS" \
            "${pod}:${remote_gz}" \
            "${local_pod_dir}/${f}.filtered.gz"

        if [ $? -ne 0 ]; then
            echo "WARN: failed to copy $pod/$f.filtered.gz, continue"
            rm -f "${local_pod_dir}/${f}.filtered.gz"
            continue
        fi

        kubectl exec -n "$NS" "$pod" -- rm -f "${remote_gz}" >/dev/null 2>&1 || true
    done

    kubectl exec -n "$NS" "$pod" -- rm -rf "$remote_tmp" >/dev/null 2>&1 || true

    echo "Done: $pod"
    echo
done

{
    echo "All copied files:"
    find "$LOCAL_OUT_DIR" -type f -name '*.gz' -ls
} | tee -a "$SUMMARY_FILE"

echo "Summary written to: $SUMMARY_FILE"
