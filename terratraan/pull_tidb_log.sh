
#!/usr/bin/env bash
set -u

# ===== User variables =====
CLUSTER="ads-index-staging-prod"
BEGIN_TIME="2026/06/25 02:30:00"
END_TIME="2026/06/25 03:00:00"

# TiDB SQL log path on sql nodes
LOG_FILE="/var/log/tidb/tidb.log"

# Local output directory
OUT_DIR="./tidb_sql_logs_${CLUSTER}_$(date +%Y%m%d_%H%M%S)"

# ==========================

TMP_INSTANCES="$(mktemp /tmp/collect_tidb_sql_logs.XXXXXX)"
trap 'rm -f "$TMP_INSTANCES"' EXIT

quote() {
  printf "%s" "$1" | sed "s/'/'\\\\''/g; s/^/'/; s/$/'/"
}

REMOTE_LOG_FILE="$(quote "$LOG_FILE")"
REMOTE_BEGIN_TIME="$(quote "$BEGIN_TIME")"
REMOTE_END_TIME="$(quote "$END_TIME")"

mkdir -p "$OUT_DIR"

echo "Cluster:     ${CLUSTER}"
echo "Begin time:  ${BEGIN_TIME}"
echo "End time:    ${END_TIME}"
echo "Remote log:  ${LOG_FILE}"
echo "Output dir:  ${OUT_DIR}"
echo

echo "Querying instances from getin..."
getin "$CLUSTER" | awk -v cluster="$CLUSTER" '
  BEGIN {
    # Only keep exact sql nodes for this cluster:
    # infra-tidb-sql-ads-index-staging-prod-0a019223
    pattern = "^infra-tidb-sql-" cluster "-[A-Za-z0-9]+$"
  }

  $1 ~ pattern && $2 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {
    print $1, $2
  }
' > "$TMP_INSTANCES"

if [[ ! -s "$TMP_INSTANCES" ]]; then
  echo "No sql instances found for cluster: ${CLUSTER}"
  exit 1
fi

echo "Matched sql instances:"
cat "$TMP_INSTANCES"
echo

total="$(wc -l < "$TMP_INSTANCES" | tr -d ' ')"
count=0
success=0
failed=0

while read -r NAME IP; do
  [[ -z "$NAME" || -z "$IP" ]] && continue
  count=$((count + 1))

  OUT_FILE="${OUT_DIR}/${NAME}.tidb.log.${BEGIN_TIME//[\/: ]/-}_to_${END_TIME//[\/: ]/-}.gz"

  echo "============================================================"
  echo "[$count/$total] Instance: ${NAME}"
  echo "IP:            ${IP}"
  echo "Output:        ${OUT_FILE}"
  echo "============================================================"

  # The TiDB log time format is like:
  # "time":"2026/06/25 02:37:59.325 +00:00"
  #
  # We compare only the first 19 chars:
  # 2026/06/25 02:37:59
  #
  # BEGIN_TIME and END_TIME must use:
  # YYYY/MM/DD HH:MM:SS
  gironde ssh "$NAME" "
    sudo -n awk -v begin=${REMOTE_BEGIN_TIME} -v end=${REMOTE_END_TIME} '
      match(\$0, /\"time\":\"([0-9]{4}\/[0-9]{2}\/[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2})/, m) {
        t = m[1]
        if (t >= begin && t <= end) {
          print \$0
        }
      }
    ' ${REMOTE_LOG_FILE} | gzip -c
  " > "$OUT_FILE" < /dev/null

  rc=$?

  if [[ $rc -eq 0 ]]; then
    if [[ -s "$OUT_FILE" ]]; then
      echo "Collected successfully."
      success=$((success + 1))
    else
      echo "Command succeeded but output is empty."
      # Keep the empty gzip? Usually not useful.
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
