#!/usr/bin/env sh

# Common environment for the k8s helper scripts.
# Override any value before running a script, for example:
#   NAMESPACE=my-namespace BEGIN_TIME="2026-09-08 06:30:00" ./pull_tidb_log.sh

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

: "${NAMESPACE:=${K8S_NAMESPACE:?set K8S_NAMESPACE in $PINTEREST_CONF, or export NAMESPACE}}"
: "${CLUSTER_NAME:=${NAMESPACE}-eks}"

# Canonical input time format, in UTC:
#   YYYY-MM-DD HH:MM:SS
: "${BEGIN_TIME:=2026-10-01 16:00:00}"
: "${END_TIME:=2026-10-02 02:00:00}"
: "${TIMEZONE_OFFSET:=+00:00}"

: "${INTERVAL_MINUTES:=120}"
: "${DIAG_BASE_URL:=http://localhost:4917}"
: "${DIAG_NAMESPACE:=tidb-admin}"
: "${DIAG_SERVICE:=diag}"

_k8s_date_hyphen() {
    printf '%s\n' "$1" | tr 'T' ' ' | awk '{print $1}' | tr '/' '-'
}

_k8s_date_slash() {
    printf '%s\n' "$1" | tr 'T' ' ' | awk '{print $1}' | tr '-' '/'
}

_k8s_clock() {
    printf '%s\n' "$1" | tr 'T' ' ' | awk '{print $2}' | sed 's/\.[0-9][0-9]*$//'
}

_k8s_begin_date_hyphen="$(_k8s_date_hyphen "$BEGIN_TIME")"
_k8s_end_date_hyphen="$(_k8s_date_hyphen "$END_TIME")"
_k8s_begin_date_slash="$(_k8s_date_slash "$BEGIN_TIME")"
_k8s_end_date_slash="$(_k8s_date_slash "$END_TIME")"
_k8s_begin_clock="$(_k8s_clock "$BEGIN_TIME")"
_k8s_end_clock="$(_k8s_clock "$END_TIME")"

BEGIN_TIME_COLLECT="${_k8s_begin_date_hyphen} ${_k8s_begin_clock}"
END_TIME_COLLECT="${_k8s_end_date_hyphen} ${_k8s_end_clock}"

BEGIN_TIME_ISO="${_k8s_begin_date_hyphen}T${_k8s_begin_clock}"
END_TIME_ISO="${_k8s_end_date_hyphen}T${_k8s_end_clock}"

BEGIN_TIME_SLASH="${_k8s_begin_date_slash} ${_k8s_begin_clock}"
END_TIME_SLASH="${_k8s_end_date_slash} ${_k8s_end_clock}"

BEGIN_TIME_SLASH_TZ="${BEGIN_TIME_SLASH} ${TIMEZONE_OFFSET}"
END_TIME_SLASH_TZ="${END_TIME_SLASH} ${TIMEZONE_OFFSET}"

BEGIN_TIME_SLASH_MILLIS_TZ="${BEGIN_TIME_SLASH}.000 ${TIMEZONE_OFFSET}"
END_TIME_SLASH_MILLIS_TZ="${END_TIME_SLASH}.000 ${TIMEZONE_OFFSET}"

unset _k8s_begin_date_hyphen _k8s_end_date_hyphen
unset _k8s_begin_date_slash _k8s_end_date_slash
unset _k8s_begin_clock _k8s_end_clock
