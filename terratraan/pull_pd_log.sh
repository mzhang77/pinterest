
#!/usr/bin/env bash
set -u

# ===== User variables =====
CLUSTER="ads-index-staging-prod"
BEGIN_TIME="2026/06/25 16:30:00"
END_TIME="2026/06/25 18:00:00"

# PD log directory on pd nodes
LOG_DIR="/var/log/tidb"

# Local output directory
OUT_DIR="./pd_logs_${CLUSTER}_$(date +%Y%m%d_%H%M%S)"

# ==========================

TMP_INSTANCES="$(mktemp /tmp/collect_pd_logs.XXXXXX)"
trap 'rm -f "$TMP_INSTANCES"' EXIT

quote() {
  printf "%s" "$1" | sed "s/'/'\\\\''/g; s/^/'/; s/$/'/"
}

REMOTE_BEGIN_TIME="$(quote "$BEGIN_TIME")"
REMOTE_END_TIME="$(quote "$END_TIME")"

mkdir -p "$OUT_DIR"

echo "Cluster:     ${CLUSTER}"
echo "Begin time:  ${BEGIN_TIME}"
echo "End time:    ${END_TIME}"
echo "Remote dir:  ${LOG_DIR}"
echo "Output dir:  ${OUT_DIR}"
echo

echo "Querying instances from getin..."
getin "$CLUSTER" | awk -v cluster="$CLUSTER" '
  BEGIN {
    # Only keep exact pd nodes for this cluster:
    # infra-tidb-pd-ads-index-staging-prod-0a019fa2
    pattern = "^infra-tidb-pd-" cluster "-[A-Za-z0-9]+$"
  }

  $1 ~ pattern && $2 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {
    print $1, $2
  }
' > "$TMP_INSTANCES"

if [[ ! -s "$TMP_INSTANCES" ]]; then
  echo "No pd instances found for cluster: ${CLUSTER}"
  exit 1
fi

echo "Matched pd instances:"
cat "$TMP_INSTANCES"
echo

total="$(wc -l < "$TMP_INSTANCES" | tr -d ' ')"
count=0
success=0
failed=0

while read -r NAME IP; do
  [[ -z "$NAME" || -z "$IP" ]] && continue
  count=$((count + 1))

  SAFE_BEGIN="${BEGIN_TIME//[\/: ]/-}"
  SAFE_END="${END_TIME//[\/: ]/-}"
  OUT_FILE="${OUT_DIR}/${NAME}.pd.log.${SAFE_BEGIN}_to_${SAFE_END}.gz"

  echo "============================================================"
  echo "[$count/$total] Instance: ${NAME}"
  echo "IP:            ${IP}"
  echo "Output:        ${OUT_FILE}"
  echo "============================================================"

  # PD log time format is like:
  # "time":"2026/06/25 18:15:40.183 +00:00"
  #
  # We compare only the first 19 chars:
  # 2026/06/25 18:15:40
  #
  # BEGIN_TIME and END_TIME must use:
  # YYYY/MM/DD HH:MM:SS
  #
  # PD logs may include both current and rotated files:
  # /var/log/tidb/pd.log
  # /var/log/tidb/pd-2026-06-17T21-43-02.904.log
  #
  # We scan all pd*.log files under LOG_DIR.
  gironde ssh "$NAME" "
    set -o pipefail

    find '$LOG_DIR' -maxdepth 1 -type f -name 'pd*.log' -print0 |
    while IFS= read -r -d '' f; do
      sudo -n awk -v begin=${REMOTE_BEGIN_TIME} -v end=${REMOTE_END_TIME} -v file=\"\$f\" '
        match(\$0, /\"time\":\"([0-9]{4}\/[0-9]{2}\/[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2})/, m) {
          t = m[1]
          if (t >= begin && t <= end) {
            print file \":\" \$0
          }
        }
      ' \"\$f\"
    done | gzip -c
  " > "$OUT_FILE" < /dev/null

  rc=$?

  if [[ $rc -eq 0 ]]; then
    if gzip -cd "$OUT_FILE" | head -n 1 | grep -q .; then
      echo "Collected successfully."
      success=$((success + 1))
    else
      echo "Command succeeded but output has no matched log lines."
      rm -f "$OUT_FILE"
      success=$((success + 1))
    fi
  else
    echo "Failed to collect from ${NAME} (${IP}), exit code: ${rc}"
    rm -f "$OUT_FILE"
    failed=$((failed + 1))
  fi

  echo
done < "$TMP_INSTANCES"

echo "Done."
echo "Checked: ${count}/${total}"
echo "Succeeded: ${success}"
echo "Failed: ${failed}"
echo "Output dir: ${OUT_DIR}"
