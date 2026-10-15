#!/usr/bin/env sh

# Common environment for the terratraan helper scripts.
# Override any value before running a script, for example:
#   CLUSTER_NAME=my-cluster-prod BEGIN_TIME="2026-09-03 17:50:00" ./pull_cdc_log.sh

# Machine-specific settings (hostnames, cert paths, default cluster, Clinic token) live in a
# private file outside this repo, never in the scripts. Override its path with PINTEREST_CONF.
: "${PINTEREST_CONF:=$HOME/.config/pingcap/pinterest}"
if [ -r "$PINTEREST_CONF" ]; then
    _conf_perm="$(stat -c '%a' "$PINTEREST_CONF" 2>/dev/null || stat -f '%Lp' "$PINTEREST_CONF" 2>/dev/null)"
    case "$_conf_perm" in
        ""|*00) ;;
        *) echo "[WARN] $PINTEREST_CONF has permissions $_conf_perm; run: chmod 600 $PINTEREST_CONF" >&2 ;;
    esac
    unset _conf_perm
    . "$PINTEREST_CONF"
fi

: "${CLUSTER_NAME:=${TERRATRAAN_CLUSTER:?set TERRATRAAN_CLUSTER in $PINTEREST_CONF, or export CLUSTER_NAME}}"
# Previous window (NAID-12273): 2026-10-08 17:00:00 -> 2026-10-09 14:15:00
# NAID-12205: Rachel's most recent node_2425 attempt on the isolated 8.5.8 newarch TiCDC node.
# Her "Changefeed Checkpoint Lag" screenshot (EDT, UTC-4): lag rises ~15:02 EDT, all lines back to 0 by ~15:27 EDT
# = ~19:02 -> ~19:27 UTC. Margin added to catch changefeed creation and the aftermath. All times here are UTC.
: "${BEGIN_TIME:=2026-10-15 18:55:00}"
: "${END_TIME:=2026-10-15 19:35:00}"
: "${LOG_DIR:=/var/log/tidb}"
: "${DEBUG:=1}"
: "${INTERVAL_MINUTES:=20}"
# Optional awk regular expression matched against the TiKV instance name
# (infra-tidb-tikv-<cluster>-<id>). Only matching instances are collected by
# pull_tikv_log.sh and pull_rocksdb_log.sh. Empty = collect all TiKV instances.
: "${TIKV_INSTANCE_FILTER=0a03f078}"
# Optional awk regular expression. Matching CDC log lines are excluded from output.
: "${CDC_LOG_FILTER_PATTERN:=scan window local advance due to pending barrier}"

_terratraan_date_slash() {
    printf '%s\n' "$1" | tr 'T' ' ' | awk '{print $1}' | tr '-' '/'
}

_terratraan_date_hyphen() {
    printf '%s\n' "$1" | tr 'T' ' ' | awk '{print $1}' | tr '/' '-'
}

_terratraan_clock() {
    printf '%s\n' "$1" | tr 'T' ' ' | awk '{print $2}' | sed 's/Z$//' | sed 's/+00:00$//' | sed 's/\.[0-9][0-9]*$//'
}

_terratraan_begin_date="$(_terratraan_date_slash "$BEGIN_TIME")"
_terratraan_end_date="$(_terratraan_date_slash "$END_TIME")"
_terratraan_begin_date_hyphen="$(_terratraan_date_hyphen "$BEGIN_TIME")"
_terratraan_end_date_hyphen="$(_terratraan_date_hyphen "$END_TIME")"
_terratraan_begin_clock="$(_terratraan_clock "$BEGIN_TIME")"
_terratraan_end_clock="$(_terratraan_clock "$END_TIME")"

: "${BEGIN_TIME_SLASH:=${_terratraan_begin_date} ${_terratraan_begin_clock}}"
: "${END_TIME_SLASH:=${_terratraan_end_date} ${_terratraan_end_clock}}"
: "${BEGIN_TIME_ISO:=${_terratraan_begin_date_hyphen}T${_terratraan_begin_clock}Z}"
: "${END_TIME_ISO:=${_terratraan_end_date_hyphen}T${_terratraan_end_clock}Z}"

unset _terratraan_begin_date _terratraan_end_date
unset _terratraan_begin_date_hyphen _terratraan_end_date_hyphen
unset _terratraan_begin_clock _terratraan_end_clock

: "${TIUP_METRICS_SCRIPT:=${SCRIPT_DIR}/tiup_metrics.sh}"
