
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${1:?Usage: $0 <ticdc_logs_dir> <pattern>}"
PATTERN="${2:?Usage: $0 <ticdc_logs_dir> <pattern>}"

find "$ROOT_DIR" -mindepth 2 -maxdepth 2 -type f -name "*.gz" | sort | while read -r file; do
  pod="$(basename "$(dirname "$file")")"
  fname="$(basename "$file")"

  zgrep -Hn -- "$PATTERN" "$file" | sed "s|^$file:|$pod/$fname:|" || true
done
