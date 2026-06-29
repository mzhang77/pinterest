

#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<EOF
Usage: $(basename "$0") <remote_dir> [local_dir]

Copy all files under a directory from devapp to local machine.

Arguments:
  remote_dir   Directory path on devapp
  local_dir    Local output directory, default: ./devapp_files_<timestamp>

Example:
  $(basename "$0") /tmp/logs
  $(basename "$0") /var/log/tidb ./tidb_logs
EOF
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
    usage
    exit 1
fi

REMOTE_DIR="$1"
LOCAL_DIR="${2:-./devapp_files_$(date +%Y%m%d_%H%M%S)}"

mkdir -p "$LOCAL_DIR"

echo "Signing with gironde..."
gironde sign -ca github

echo "Copying files from devapp:${REMOTE_DIR} to ${LOCAL_DIR} ..."
scp -r "devapp:${REMOTE_DIR}/." "$LOCAL_DIR/"

echo
echo "Done."
echo "Local directory: $LOCAL_DIR"