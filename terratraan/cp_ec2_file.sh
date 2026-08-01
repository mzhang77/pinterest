
#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

usage() {
  echo "Usage:"
  echo "  $(basename "$0") <host> <remote-path> [local-directory]"
  echo
  echo "Example:"
  echo "  $(basename "$0") infra-tidb-monitoring-bulbasaur-prod-0a01d166 \\"
  echo "    /mnt/pingcap_diag_data/diag-bulbasaur-prod-1785614626.diag"
  exit 1
}

if [[ $# -lt 2 || $# -gt 3 ]]; then
  usage
fi

HOST="$1"
REMOTE_PATH="$2"
LOCAL_DIR="${3:-.}"

if ! command -v gironde >/dev/null 2>&1; then
  echo "Error: gironde command was not found." >&2
  exit 1
fi

mkdir -p "$LOCAL_DIR"

REMOTE_DIR="$(dirname "$REMOTE_PATH")"
REMOTE_NAME="$(basename "$REMOTE_PATH")"

# Quote values so paths containing spaces or special characters are safe.
printf -v REMOTE_DIR_QUOTED '%q' "$REMOTE_DIR"
printf -v REMOTE_NAME_QUOTED '%q' "$REMOTE_NAME"

echo "Copying:"
echo "  Host:        $HOST"
echo "  Remote path: $REMOTE_PATH"
echo "  Local dir:   $(cd "$LOCAL_DIR" && pwd)"
echo

gironde ssh -T "$HOST" \
  "test -e $REMOTE_DIR_QUOTED/$REMOTE_NAME_QUOTED &&
   tar -C $REMOTE_DIR_QUOTED -cf - -- $REMOTE_NAME_QUOTED" |
  tar -C "$LOCAL_DIR" -xvf -

echo
echo "Copy completed:"
echo "  $LOCAL_DIR/$REMOTE_NAME"