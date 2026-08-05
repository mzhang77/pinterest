
#!/bin/bash

set -euo pipefail

NS="pingraph-socialgraph-prod"

BEGIN_TIME="2026/08/05 11:00:00.000 +00:00"
END_TIME="2026/08/05 11:30:00.000 +00:00"

OUT_DIR="pd_logs_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUT_DIR"

SUMMARY_FILE="${OUT_DIR}/collection_summary.txt"

{
    echo "namespace=${NS}"
    echo "begin_time=${BEGIN_TIME}"
    echo "end_time=${END_TIME}"
    echo
} > "$SUMMARY_FILE"

pods=$(
    kubectl get pod -n "$NS" -o name \
    | grep -E 'pd-[0-9]+$' \
    | sed 's#pod/##'
)

for pod in $pods; do
    echo "===== $pod ====="

    outfile="${OUT_DIR}/${pod}.log"

    kubectl logs \
        -n ${NS} \
        -c pd \
        "$pod" \
    | awk -v begin="$BEGIN_TIME" -v end="$END_TIME" '
    {
        if (match($0, /^\[[0-9]{4}\/[0-9]{2}\/[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3} \+00:00\]/)) {
            ts = substr($0, RSTART + 1, RLENGTH - 2)

            if (ts >= begin && ts <= end) {
                print
            }
        }
    }' > "$outfile"

    lines=$(wc -l < "$outfile")

    if [ "$lines" -eq 0 ]; then
        rm -f "$outfile"
    else
        gzip "$outfile"
        echo "saved ${outfile}.gz ($lines lines)"
    fi
done

echo
echo "Done."

