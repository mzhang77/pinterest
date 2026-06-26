#!/usr/bin/env bash
set -u

# ===== User variables =====
CLUSTER="bulbasaur-prod"
BEGIN_TIME="2026/06/26 08:00:00"
END_TIME="2026/06/26 08:30:00"

# TiCDC log directory on ticdc nodes
LOG_DIR="/var/log/tidb"

# Include current ticdc.log and rotated ticdc-*.log files
LOG_GLOB="ticdc*.log"

# Local output directory
OUT_DIR="./ticdc_logs_${CLUSTER}_$(date +%Y%m%d_%H%M%S)"

# ==========================

TMP_INSTANCES="$(mktemp /tmp/collect_ticdc_logs.XXXXXX)"
trap 'rm -f "$TMP_INSTANCES"' EXIT

quote() {
  printf "%s" "$1" | sed "s/'/'\\\\''/g; s/^/'/; s/$/'/"
}

REMOTE_LOG_DIR="$(quote "$LOG_DIR")"
REMOTE_LOG_GLOB="$(quote "$LOG_GLOB")"
REMOTE_BEGIN_TIME="$(quote "$BEGIN_TIME")"
REMOTE_END_TIME="$(quote "$END_TIME")"

REMOTE_SCRIPT='log_dir="$1"
log_glob="$2"
begin="$3"
end="$4"

cd "$log_dir" || exit 10

shopt -s nullglob
files=( $log_glob )

if (( ${#files[@]} == 0 )); then
  exit 0
fi

awk -v begin="$begin" -v end="$end" '\''
  match($0, /^\[([0-9]{4}\/[0-9]{2}\/[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2})/, m) {
    t = m[1]
    if (t >= begin && t <= end) {
      print $0
    }
  }
'\'' "${files[@]}" 2>/dev/null | gzip -c
'

mkdir -p "$OUT_DIR"

SUMMARY_FILE="${OUT_DIR}/collection_summary.txt"

{
  echo "cluster=${CLUSTER}"
  echo "begin_time=${BEGIN_TIME}"
  echo "end_time=${END_TIME}"
  echo "remote_log_dir=${LOG_DIR}"
  echo "remote_log_glob=${LOG_GLOB}"
  echo "output_dir=${OUT_DIR}"
  echo
} > "$SUMMARY_FILE"

echo "Cluster:     ${CLUSTER}"
echo "Begin time:  ${BEGIN_TIME}"
echo "End time:    ${END_TIME}"
echo "Remote dir:  ${LOG_DIR}"
echo "Log pattern: ${LOG_GLOB}"
echo "Output dir:  ${OUT_DIR}"
echo

echo "Querying instances from getin..."
getin "$CLUSTER" | awk -v cluster="$CLUSTER" '
  BEGIN {
    # Only keep exact TiCDC nodes for this cluster:
    # infra-tidb-ticdc-bulbasaur-prod-0a0116df
    pattern = "^infra-tidb-ticdc-" cluster "-[A-Za-z0-9]+$"
  }

  $1 ~ pattern && $2 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {
    print $1, $2
  }
' > "$TMP_INSTANCES"

if [[ ! -s "$TMP_INSTANCES" ]]; then
  echo "No TiCDC instances found for cluster: ${CLUSTER}"
  exit 1
fi

echo "Matched TiCDC instances:"
cat "$TMP_INSTANCES"
echo

total="$(wc -l < "$TMP_INSTANCES" | tr -d ' ')"
count=0
success=0
failed=0
empty=0

safe_begin="${BEGIN_TIME//[\/: ]/-}"
safe_end="${END_TIME//[\/: ]/-}"

while read -r NAME IP; do
  [[ -z "$NAME" || -z "$IP" ]] && continue
  count=$((count + 1))

  OUT_FILE="${OUT_DIR}/${NAME}.ticdc.log.${safe_begin}_to_${safe_end}.gz"

  echo "============================================================"
  echo "[$count/$total] Instance: ${NAME}"
  echo "IP:            ${IP}"
  echo "Output:        ${OUT_FILE}"
  echo "============================================================"

  printf '%s\n' "$REMOTE_SCRIPT" \
    | gironde ssh "$NAME" "sudo -n bash -s -- ${REMOTE_LOG_DIR} ${REMOTE_LOG_GLOB} ${REMOTE_BEGIN_TIME} ${REMOTE_END_TIME}" \
    > "$OUT_FILE"

  rc=$?

  if [[ $rc -eq 0 ]]; then
    if [[ -s "$OUT_FILE" ]]; then
      echo "Collected successfully."
      success=$((success + 1))
    else
      echo "Command succeeded but output is empty."
      rm -f "$OUT_FILE"
      success=$((success + 1))
      empty=$((empty + 1))
    fi
  else
    echo "Failed to collect from ${NAME} (${IP}), exit code: ${rc}"
    rm -f "$OUT_FILE"
    failed=$((failed + 1))
  fi

  {
    echo "instance=${NAME} ip=${IP} rc=${rc} output=${OUT_FILE}"
  } >> "$SUMMARY_FILE"

  echo
done < "$TMP_INSTANCES"

{
  echo
  echo "checked=${count}/${total}"
  echo "succeeded=${success}"
  echo "empty=${empty}"
  echo "failed=${failed}"
} >> "$SUMMARY_FILE"

echo "Done."
echo "Checked: ${count}/${total}"
echo "Succeeded: ${success}"
echo "Empty: ${empty}"
echo "Failed: ${failed}"
echo "Output dir: ${OUT_DIR}"
echo "Summary: ${SUMMARY_FILE}"