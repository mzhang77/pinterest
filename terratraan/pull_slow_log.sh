
#!/usr/bin/env bash
set -u

# ===== User variables =====
CLUSTER="bulbasaur-prod"

# UTC time range.
# Format must be: YYYY-MM-DDTHH:MM:SSZ
BEGIN_TIME="2026-06-26T08:00:00Z"
END_TIME="2026-06-26T08:30:00Z"

# Slow log location on TiDB SQL nodes.
LOG_DIR="/var/log/tidb"

# Set to 1 to print remote file-selection details to stderr.
# This does not pollute the gzip output.
DEBUG=1

# Local output directory
OUT_DIR="./tidb_slow_logs_${CLUSTER}_$(date +%Y%m%d_%H%M%S)"

# ==========================

TMP_INSTANCES="$(mktemp /tmp/collect_tidb_slow_logs.XXXXXX)"
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

# For comparison, use second-level UTC timestamp:
# 2026-06-26T08:00:00Z
begin_cmp="$begin"
end_cmp="$end"

shopt -s nullglob
rotated_files=( tidb-slow-*.log )

selected_files=()

# Slow log rotated file names look like:
# tidb-slow-2026-06-26T12-24-06.305.log
# The timestamp in the file name is approximately the last slow-log record timestamp in that file.
# Use it as the rotated file end time to skip obviously irrelevant old/new files.
tmp_list="/tmp/tidb_slow_log_files_$$.list"
: > "$tmp_list"

for f in "${rotated_files[@]}"; do
  if [[ "$f" =~ ^tidb-slow-([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2})-([0-9]{2})-([0-9]{2}) ]]; then
    file_end="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]}T${BASH_REMATCH[4]}:${BASH_REMATCH[5]}:${BASH_REMATCH[6]}Z"
    printf "%s %s\n" "$file_end" "$f" >> "$tmp_list"
  fi
done

sort -o "$tmp_list" "$tmp_list"

prev_end="0000-00-00T00:00:00Z"
last_rotated_end="0000-00-00T00:00:00Z"

while read -r file_end file_name; do
  [[ -z "$file_end" || -z "$file_name" ]] && continue

  last_rotated_end="$file_end"

  # A rotated file roughly covers: previous rotated end time -> this file end time.
  # It can overlap the query window if:
  #   file_end >= begin AND prev_end <= end
  if [[ "$file_end" > "$begin_cmp" || "$file_end" == "$begin_cmp" ]]; then
    if [[ "$prev_end" < "$end_cmp" || "$prev_end" == "$end_cmp" ]]; then
      selected_files+=( "$file_name" )
    fi
  fi

  prev_end="$file_end"
done < "$tmp_list"

rm -f "$tmp_list"

# The current tidb-slow.log has no timestamp in the file name.
# Always include it when it exists. The awk block filter will still keep only the requested window.
if [[ -f tidb-slow.log ]]; then
  selected_files+=( "tidb-slow.log" )
fi

if [[ "$debug" == "1" ]]; then
  echo "[remote-debug] begin=$begin end=$end" >&2
  echo "[remote-debug] rotated files: ${#rotated_files[@]}" >&2
  echo "[remote-debug] selected files: ${selected_files[*]}" >&2
fi

if (( ${#selected_files[@]} == 0 )); then
  exit 0
fi

tmp_out="/tmp/tidb_slow_filtered_$$.log"

awk -v begin="$begin_cmp" -v end="$end_cmp" '\''
  function flush_block() {
    if (has_block && keep) {
      printf "%s", block
    }
    block = ""
    keep = 0
    has_block = 0
  }

  function normalize_time(raw,    t) {
    # raw example: 2026-05-04T00:53:32.203724778Z
    # return:      2026-05-04T00:53:32Z
    t = raw
    sub(/\.[0-9]+Z$/, "Z", t)
    return t
  }

  /^# Time: / {
    flush_block()

    has_block = 1
    block = $0 "\n"

    raw_time = $3
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
      block = block $0 "\n"
    }
  }

  END {
    flush_block()
  }
'\'' "${selected_files[@]}" 2>/dev/null > "$tmp_out"

if [[ -s "$tmp_out" ]]; then
  gzip -c "$tmp_out"
fi

rm -f "$tmp_out"
'

mkdir -p "$OUT_DIR"

SUMMARY_FILE="${OUT_DIR}/collection_summary.txt"

{
  echo "cluster=${CLUSTER}"
  echo "begin_time=${BEGIN_TIME}"
  echo "end_time=${END_TIME}"
  echo "remote_log_dir=${LOG_DIR}"
  echo "output_dir=${OUT_DIR}"
  echo
} > "$SUMMARY_FILE"

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
    # Only keep exact SQL nodes for this cluster:
    # infra-tidb-sql-bulbasaur-prod-0a033ee1
    pattern = "^infra-tidb-sql-" cluster "-[A-Za-z0-9]+$"
  }

  $1 ~ pattern && $2 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {
    print $1, $2
  }
' > "$TMP_INSTANCES"

if [[ ! -s "$TMP_INSTANCES" ]]; then
  echo "No SQL instances found for cluster: ${CLUSTER}"
  exit 1
fi

echo "Matched SQL instances:"
cat "$TMP_INSTANCES"
echo

total="$(wc -l < "$TMP_INSTANCES" | tr -d ' ')"
count=0
success=0
failed=0
empty=0

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

  printf '%s\n' "$REMOTE_SCRIPT" \
    | gironde ssh "$NAME" "sudo -n bash -s -- ${REMOTE_LOG_DIR} ${REMOTE_BEGIN_TIME} ${REMOTE_END_TIME} ${DEBUG}" \
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
echo "Checked:   ${count}/${total}"
echo "Succeeded: ${success}"
echo "Empty:     ${empty}"
echo "Failed:    ${failed}"
echo "Output dir: ${OUT_DIR}"
echo "Summary: ${SUMMARY_FILE}"
