#!/usr/bin/env sh

# Common environment for the terratraan helper scripts.
# Override any value before running a script, for example:
#   CDC_CLUSTER=foo-prod CDC_BEGIN_TIME="2026/09/03 17:50:00" ./pull_cdc_log.sh

: "${CDC_CLUSTER:=pingraph-notifications-prod}"
: "${CDC_BEGIN_TIME:=2026/09/03 17:50:00}"
: "${CDC_END_TIME:=2026/09/03 19:15:00}"
: "${CDC_LOG_DIR:=/var/log/tidb}"
: "${CDC_DEBUG:=1}"

: "${PD_CLUSTER:=ads-index-staging-prod}"
: "${PD_BEGIN_TIME:=2026/06/25 16:30:00}"
: "${PD_END_TIME:=2026/06/25 18:00:00}"
: "${PD_LOG_DIR:=/var/log/tidb}"

: "${SLOW_CLUSTER:=bulbasaur-prod}"
: "${SLOW_BEGIN_TIME:=2026-06-26T08:00:00Z}"
: "${SLOW_END_TIME:=2026-06-26T08:30:00Z}"
: "${SLOW_LOG_DIR:=/var/log/tidb}"
: "${SLOW_DEBUG:=1}"

: "${TIDB_CLUSTER:=ads-index-staging-prod}"
: "${TIDB_BEGIN_TIME:=2026/06/25 02:30:00}"
: "${TIDB_END_TIME:=2026/06/25 03:00:00}"
: "${TIDB_LOG_FILE:=/var/log/tidb/tidb.log}"

: "${CLINIC_CLUSTER:=pingraph-notifications-prod}"
: "${CLINIC_BEGIN_TIME:=2026-08-28 19:45:00}"
: "${CLINIC_END_TIME:=2026-08-28 20:15:00}"
: "${CLINIC_INTERVAL_MINUTES:=10}"
: "${TIUP_METRICS_SCRIPT:=${SCRIPT_DIR}/tiup_metrics.sh}"
