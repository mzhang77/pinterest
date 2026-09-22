#!/usr/bin/env sh

# Common environment for the terratraan helper scripts.
# Override any value before running a script, for example:
#   CLUSTER_NAME=foo-prod BEGIN_TIME="2026-09-03 17:50:00" ./pull_cdc_log.sh

: "${CLUSTER_NAME:=pingraph-richpins-prod}"
: "${BEGIN_TIME:=2026-09-21 22:00:00}"
: "${END_TIME:=2026-09-22 05:00:00}"
: "${LOG_DIR:=/var/log/tidb}"
: "${DEBUG:=1}"
: "${INTERVAL_MINUTES:=20}"

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
