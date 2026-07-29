
#!/bin/bash

set -u

NS="catalog-dev"
REMOTE_LOG_DIR="/var/log/tidb"
REMOTE_TMP_BASE="/tmp/ticdc-log-collect"
LOCAL_OUT_DIR="./ticdc_logs_$(date +%Y%m%d_%H%M%S)"

# UTC time, same format as ticdc log header
BEGIN_TIME="2026/07/29 11:30:00"
END_TIME="2026/07/29 17:30:00"

mkdir -p "$LOCAL_OUT_DIR"

SUMMARY_FILE="${LOCAL_OUT_DIR}/collection_summary.txt"

{
    echo "namespace=${NS}"
    echo "begin_time=${BEGIN_TIME}"
    echo "end_time=${END_TIME}"
    echo
} > "$SUMMARY_FILE"

pods=$(kubectl get pod -n "$NS" -o name | grep 'ticdc-' | sed 's#pod/##')

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
            if [ -f ticdc.log ]; then echo ticdc.log; fi
            ls -1t ticdc*.log 2>/dev/null | grep -v '^ticdc.log$' || true
        " | sed '/^Defaulted container /d'
    )

    for f in $files; do
        echo "[$pod] filtering and compressing $f"

        kubectl exec -n "$NS" "$pod" -- bash -c "
            cd '${REMOTE_LOG_DIR}' &&
            awk -v begin='${BEGIN_TIME}' -v end='${END_TIME}' '
                /^\[[0-9]{4}\/[0-9]{2}\/[0-9]{2} / {
                    ts = substr(\$0, 2, 23)
                    keep = (ts >= begin && ts <= end)
                }
                keep
            ' '$f' | gzip -c > '${remote_tmp}/${f}.gz'
        "

        if [ $? -ne 0 ]; then
            echo "WARN: failed to filter/gzip $pod/$f, skip"
            continue
        fi

        echo "[$pod] copying $f.gz"

        kubectl cp \
            -n "$NS" \
            "${pod}:${remote_tmp}/${f}.gz" \
            "${local_pod_dir}/${f}.gz"

        if [ $? -ne 0 ]; then
            echo "WARN: failed to copy $pod/$f.gz, continue"
            rm -f "${local_pod_dir}/${f}.gz"
            continue
        fi

        kubectl exec -n "$NS" "$pod" -- rm -f "${remote_tmp}/${f}.gz" >/dev/null 2>&1 || true
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
