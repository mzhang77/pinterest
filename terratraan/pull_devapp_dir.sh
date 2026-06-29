

#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<EOF
Usage: $(basename "$0") <remote_path> [local_dir]

Copy a file or all files under a directory from devapp to local machine.

Arguments:
  remote_path  File or directory path on devapp
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

REMOTE_PATH="$1"
LOCAL_DIR="${2:-./devapp_files_$(date +%Y%m%d_%H%M%S)}"

mkdir -p "$LOCAL_DIR"

ARCHIVE_NAME="devapp_path_$(date +%Y%m%d_%H%M%S).tar.gz"
REMOTE_ARCHIVE="/tmp/${ARCHIVE_NAME}"
LOCAL_ARCHIVE="${LOCAL_DIR}/${ARCHIVE_NAME}"

cleanup_remote_archive() {
    ssh devapp "rm -f '${REMOTE_ARCHIVE}'" >/dev/null 2>&1 || true
}
trap cleanup_remote_archive EXIT

echo "Signing with gironde..."
gironde sign -ca github

echo "Compressing ${REMOTE_PATH} on devapp..."
ssh devapp "
set -euo pipefail
if [[ -d '${REMOTE_PATH}' ]]; then
    tar -czf '${REMOTE_ARCHIVE}' -C '${REMOTE_PATH}' .
elif [[ -f '${REMOTE_PATH}' ]]; then
    remote_parent=\$(dirname '${REMOTE_PATH}')
    remote_base=\$(basename '${REMOTE_PATH}')
    tar -czf '${REMOTE_ARCHIVE}' -C \"\${remote_parent}\" \"\${remote_base}\"
else
    echo 'Remote path does not exist or is not a regular file/directory: ${REMOTE_PATH}' >&2
    exit 1
fi
"

echo "Copying archive from devapp:${REMOTE_ARCHIVE} to ${LOCAL_ARCHIVE} ..."
scp "devapp:${REMOTE_ARCHIVE}" "${LOCAL_ARCHIVE}"

echo "Extracting archive to ${LOCAL_DIR} ..."
tar -xzf "${LOCAL_ARCHIVE}" -C "${LOCAL_DIR}"

echo "Removing local archive ${LOCAL_ARCHIVE} ..."
rm -f "${LOCAL_ARCHIVE}"

echo
echo "Done."
echo "Local directory: $LOCAL_DIR"