#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "${SCRIPT_DIR}/env.sh"

CLUSTER="$CLUSTER_NAME"
BEGIN_TIME="$BEGIN_TIME_SLASH"
END_TIME="$END_TIME_SLASH"

# TiKV log directory on TiKV nodes.
# Set DEBUG=1 to print remote file-selection details to stderr.
OUT_DIR="./tikv_logs_${CLUSTER}_$(date +%Y%m%d_%H%M%S)"

# ==========================

TMP_INSTANCES="$(mktemp /tmp/collect_tikv_logs.XXXXXX)"
trap 'rm -f "$TMP_INSTANCES"' EXIT

quote() {
  printf "%s" "$1" | sed "s/'/'\\\\''/g; s/^/'/; s/$/'/"
}

REMOTE_LOG_DIR="$(quote "$LOG_DIR")"
REMOTE_BEGIN_TIME="$(quote "$BEGIN_TIME")"
REMOTE_END_TIME="$(quote "$END_TIME")"

# The file name of a rotated TiKV log contains the approximate end time of
# that file. Use it to avoid scanning files that cannot overlap the query
# window. The final awk pass remains the source of truth.
REMOTE_SCRIPT='log_dir="$1"
begin="$2"
end="$3"
debug="$4"

cd "$log_dir" || exit 10

begin_cmp="${begin:0:19}"
end_cmp="${end:0:19}"

shopt -s nullglob
# Restrict the glob to timestamped TiKV logs. This excludes tikv-slow.log
# before any remote file inspection takes place.
rotated_files=( tikv-[0-9][0-9][0-9][0-9]-*.log )
selected_files=()

tmp_list="/tmp/tikv_log_files_$$.list"
trap '\''rm -f "$tmp_list"'\'' EXIT
: > "$tmp_list"

for f in "${rotated_files[@]}"; do
  if [[ "$f" =~ ^tikv-([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2})-([0-9]{2})-([0-9]{2}) ]]; then
    file_end="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}/${BASH_REMATCH[3]} ${BASH_REMATCH[4]}:${BASH_REMATCH[5]}:${BASH_REMATCH[6]}"
    printf "%s %s\n" "$file_end" "$f" >> "$tmp_list"
  fi
done

sort -o "$tmp_list" "$tmp_list"

prev_end="0000/00/00 00:00:00"
while read -r file_date file_time file_name; do
  [[ -z "$file_date" || -z "$file_time" || -z "$file_name" ]] && continue

  file_end="$file_date $file_time"

  # A rotated file roughly covers the time between the previous rotation
  # and this rotation. Keep files whose range can overlap the query window.
  if [[ ( "$file_end" > "$begin_cmp" || "$file_end" == "$begin_cmp" ) &&
        ( "$prev_end" < "$end_cmp" || "$prev_end" == "$end_cmp" ) ]]; then
    selected_files+=( "$file_name" )
  fi

  prev_end="$file_end"
done < "$tmp_list"

rm -f "$tmp_list"

# The active file has no timestamp in its name, so always inspect it when it
# exists. tikv-slow.log is intentionally not included in the glob above.
if [[ -f tikv.log ]]; then
  selected_files+=( "tikv.log" )
fi

if [[ "$debug" == "1" ]]; then
  echo "[remote-debug] begin=$begin end=$end" >&2
  echo "[remote-debug] rotated files: ${#rotated_files[@]}" >&2
  echo "[remote-debug] selected files: ${selected_files[*]}" >&2
fi

if (( ${#selected_files[@]} == 0 )); then
  exit 0
fi

tmp_out="/tmp/tikv_filtered_$$.log"
trap '\''rm -f "$tmp_out"'\'' EXIT

awk -v begin="$begin_cmp" -v end="$end_cmp" '\''
  match($0, /"time":"[0-9][0-9][0-9][0-9]\/[0-9][0-9]\/[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]/) {
    t = substr($0, RSTART + 8, 19)
    if (t >= begin && t <= end) {
      print $0
    }
  }
'\'' "${selected_files[@]}" 2>/dev/null > "$tmp_out"

if [[ -s "$tmp_out" ]]; then
  gzip -c "$tmp_out"
fi
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
    # Only keep exact TiKV nodes for this cluster:
    # infra-tidb-tikv-bulbasaur-prod-0a0116df
    pattern = "^infra-tidb-tikv-" cluster "-[A-Za-z0-9]+$"
  }

  $1 ~ pattern && $2 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {
    print $1, $2
  }
' > "$TMP_INSTANCES"

if [[ ! -s "$TMP_INSTANCES" ]]; then
  echo "No TiKV instances found for cluster: ${CLUSTER}"
  exit 1
fi

echo "Matched TiKV instances:"
cat "$TMP_INSTANCES"
echo

total="$(wc -l < "$TMP_INSTANCES" | tr -d ' ')"
count=0
success=0
failed=0
empty=0

safe_begin="${BEGIN_TIME//[:\/ ]/-}"
safe_end="${END_TIME//[:\/ ]/-}"

while read -r NAME IP; do
  [[ -z "$NAME" || -z "$IP" ]] && continue
  count=$((count + 1))

  OUT_FILE="${OUT_DIR}/${NAME}.tikv.log.${safe_begin}_to_${safe_end}.gz"

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
echo "Checked: ${count}/${total}"
echo "Succeeded: ${success}"
echo "Empty: ${empty}"
echo "Failed: ${failed}"
echo "Output dir: ${OUT_DIR}"
echo "Summary: ${SUMMARY_FILE}"
