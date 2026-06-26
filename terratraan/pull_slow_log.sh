
#!/usr/bin/env bash
set -u

# ===== User variables =====
CLUSTER="bulbasaur-prod"

# UTC time range.
# Format must be: YYYY-MM-DDTHH:MM:SSZ
BEGIN_TIME="2026-06-26T08:00:00Z"
END_TIME="2026-06-26T08:30:00Z"

# Slow log location on TiDB SQL nodes.
# TiDB may rotate slow logs into files such as:
#   tidb-slow-2026-06-26T05-10-10.449.log
# We scan both the current tidb-slow.log and archived tidb-slow-*.log files.
LOG_DIR="/var/log/tidb"
LOG_GLOB="tidb-slow*.log"

# Local output directory
OUT_DIR="./tidb_slow_logs_${CLUSTER}_$(date +%Y%m%d_%H%M%S)"

# ==========================

TMP_INSTANCES="$(mktemp /tmp/collect_tidb_slow_logs.XXXXXX)"
trap 'rm -f "$TMP_INSTANCES"' EXIT

quote() {
  printf "%s" "$1" | sed "s/'/'\\\\''/g; s/^/'/; s/$/'/"
}

REMOTE_LOG_DIR="$(quote "$LOG_DIR")"
REMOTE_LOG_GLOB="$(quote "$LOG_GLOB")"
REMOTE_BEGIN_TIME="$(quote "$BEGIN_TIME")"
REMOTE_END_TIME="$(quote "$END_TIME")"

mkdir -p "$OUT_DIR"

echo "Cluster:     ${CLUSTER}"
echo "Begin time:  ${BEGIN_TIME}"
echo "End time:    ${END_TIME}"
echo "Remote logs: ${LOG_DIR}/${LOG_GLOB}"
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

safe_begin="${BEGIN_TIME//[:\/ ]/-}"
safe_begin="${safe_begin//T/_}"
safe_begin="${safe_begin//Z/}"

safe_end="${END_TIME//[:\/ ]/-}"
safe_end="${safe_end//T/_}"
safe_end="${safe_end//Z/}"

while read -r NAME IP; do
  [[ -z "$NAME" || -z "$IP" ]] && continue
  count=$((count + 1))

  OUT_FILE="${OUT_DIR}/${NAME}.tidb-slow.log.${safe_begin}_to_${safe_end}.gz"

  echo "============================================================"
  echo "[$count/$total] Instance: ${NAME}"
  echo "IP:            ${IP}"
  echo "Output:        ${OUT_FILE}"
  echo "============================================================"

  # tidb-slow.log format:
  #
  # # Time: 2026-05-04T00:53:32.203724778Z
  # # Txn_start_ts: ...
  # ...
  # SQL text, possibly multi-line
  #
  # A record starts at "# Time:" and ends right before the next "# Time:".
  # We keep the full block if the block timestamp is within [begin, end].
  #
  # For comparison, only keep the first second-level timestamp:
  # 2026-05-04T00:53:32Z
  #
  gironde ssh "$NAME" "
    sudo -n find ${REMOTE_LOG_DIR} -maxdepth 1 -type f -name ${REMOTE_LOG_GLOB} -print \
      | sort \
      | sudo -n xargs -r awk -v begin=${REMOTE_BEGIN_TIME} -v end=${REMOTE_END_TIME} '
        function flush_block() {
          if (has_block && keep) {
            printf \"%s\", block
          }
          block = \"\"
          keep = 0
          has_block = 0
        }

        function normalize_time(raw,    t) {
          # raw example: 2026-05-04T00:53:32.203724778Z
          # return:      2026-05-04T00:53:32Z
          t = raw
          sub(/\\.[0-9]+Z$/, \"Z\", t)
          return t
        }

        /^# Time: / {
          flush_block()

          has_block = 1
          block = \$0 \"\n\"

          raw_time = \$3
          t = normalize_time(raw_time)

          if (t >= begin && t <= end) {
            keep = 1
          } else {
            keep = 0
          }

          next
        }

        {
          if (has_block) {
            block = block \$0 \"\n\"
          }
        }

        END {
          flush_block()
        }
      ' | gzip -c
  " > "$OUT_FILE" < /dev/null

  rc=$?

  if [[ $rc -eq 0 ]]; then
    if [[ -s "$OUT_FILE" ]]; then
      echo "Collected successfully."
      success=$((success + 1))
    else
      echo "Command succeeded but output is empty."
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
echo "Checked:   ${count}/${total}"
echo "Succeeded: ${success}"
echo "Failed:    ${failed}"
echo "Output dir: ${OUT_DIR}"
