#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "${SCRIPT_DIR}/env.sh"

CLUSTER="$CLUSTER_NAME"

# Time range used to filter log records.
# Format must be: YYYY/MM/DD HH:MM:SS
BEGIN_TIME="$BEGIN_TIME_SLASH"
END_TIME="$END_TIME_SLASH"

# Local output directory
OUT_DIR="./tidb_sql_logs_${CLUSTER}_$(date +%Y%m%d_%H%M%S)"

# ==========================

TMP_INSTANCES="$(mktemp /tmp/collect_tidb_sql_logs.XXXXXX)"
trap 'rm -f "$TMP_INSTANCES"' EXIT

quote() {
  printf "%s" "$1" | sed "s/'/'\\\\''/g; s/^/'/; s/$/'/"
}

REMOTE_LOG_DIR="$(quote "$LOG_DIR")"
REMOTE_BEGIN_TIME="$(quote "$BEGIN_TIME")"
REMOTE_END_TIME="$(quote "$END_TIME")"

REMOTE_SCRIPT='log_dir="$1"
begin="$2"
end="$3"
debug="$4"

cd "$log_dir" || exit 10

shopt -s nullglob
# Only match tidb-<timestamp>.log, not tidb-slow-*.log.
rotated_files=( tidb-[0-9]*.log )

selected_files=()

# Rotated TiDB log file names look like:
#   tidb-2026-08-19T15-09-27.829.log
# The timestamp in the file name is the rotation time, i.e. approximately the
# timestamp of the last record in that file. A rotated file therefore roughly
# covers: previous rotated file time -> this file time.
# Build "YYYY/MM/DD HH:MM:SS file" lines so they compare directly with begin/end.
tmp_list="/tmp/tidb_log_files_$$.list"
: > "$tmp_list"

for f in "${rotated_files[@]}"; do
  if [[ "$f" =~ ^tidb-([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2})-([0-9]{2})-([0-9]{2}) ]]; then
    file_end="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}/${BASH_REMATCH[3]} ${BASH_REMATCH[4]}:${BASH_REMATCH[5]}:${BASH_REMATCH[6]}"
    printf "%s\t%s\n" "$file_end" "$f" >> "$tmp_list"
  fi
done

LC_ALL=C sort -o "$tmp_list" "$tmp_list"

prev_end="0000/00/00 00:00:00"
last_rotated_end="0000/00/00 00:00:00"

while IFS=$'\''\t'\'' read -r file_end file_name; do
  [[ -z "$file_end" || -z "$file_name" ]] && continue

  last_rotated_end="$file_end"

  # File overlaps the query window if: file_end >= begin AND prev_end <= end
  if [[ ! "$file_end" < "$begin" && ! "$prev_end" > "$end" ]]; then
    selected_files+=( "$file_name" )
  fi

  prev_end="$file_end"
done < "$tmp_list"

rm -f "$tmp_list"

# The current tidb.log only contains records written after the last rotation.
# Skip it when the last rotation already happened after the query window ends.
if [[ -f tidb.log && ! "$last_rotated_end" > "$end" ]]; then
  selected_files+=( "tidb.log" )
fi

if [[ "$debug" == "1" ]]; then
  echo "[remote-debug] begin=$begin end=$end" >&2
  echo "[remote-debug] rotated files: ${#rotated_files[@]}" >&2
  echo "[remote-debug] selected files: ${selected_files[*]}" >&2
fi

if (( ${#selected_files[@]} == 0 )); then
  exit 0
fi

# The TiDB log time format is like:
#   "time":"2026/06/25 02:37:59.325 +00:00"
# We compare only the first 19 chars: 2026/06/25 02:37:59
awk -v begin="$begin" -v end="$end" '\''
  match($0, /"time":"([0-9]{4}\/[0-9]{2}\/[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2})/, m) {
    t = m[1]
    if (t >= begin && t <= end) {
      print $0
    }
  }
'\'' "${selected_files[@]}" | gzip -c
'

mkdir -p "$OUT_DIR"

echo "Cluster:     ${CLUSTER}"
echo "Begin time:  ${BEGIN_TIME}"
echo "End time:    ${END_TIME}"
echo "Remote dir:  ${LOG_DIR}"
echo "Debug:       ${DEBUG}"
echo "Output dir:  ${OUT_DIR}"
echo

echo "Querying instances from getin..."
getin "$CLUSTER" | awk -v cluster="$CLUSTER" '
  BEGIN {
    # Only keep exact sql nodes for this cluster:
    # infra-tidb-sql-<cluster>-<id>
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

  printf '%s\n' "$REMOTE_SCRIPT" \
    | gironde ssh "$NAME" "sudo -n bash -s -- ${REMOTE_LOG_DIR} ${REMOTE_BEGIN_TIME} ${REMOTE_END_TIME} ${DEBUG}" \
    > "$OUT_FILE"

  rc=$?

  if [[ $rc -eq 0 ]]; then
    # A gzip stream of empty input is still non-empty, so check decompressed content.
    if [[ -s "$OUT_FILE" ]] && [[ "$(gzip -dc "$OUT_FILE" 2>/dev/null | head -c 1 | wc -c | tr -d ' ')" != "0" ]]; then
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
echo "Checked: ${count}/${total}"
echo "Succeeded: ${success}"
echo "Failed: ${failed}"
echo "Output dir: ${OUT_DIR}"
