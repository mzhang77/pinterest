#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="tidb-admin"
SVC="diag"
LOCAL_PORT="4917"
REMOTE_PORT="4917"
OUT_FILE="diagforward.out"
PID_FILE=".diagforward.pid"

usage() {
    echo "Usage: $(basename "$0") start|stop|status"
}

start() {
    if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo "diag port-forward is already running. PID=$(cat "$PID_FILE")"
        return 0
    fi

    if ! kubectl get svc -n "$NAMESPACE" "$SVC" >/dev/null 2>&1; then
        echo "Service not found: svc/${SVC} in namespace ${NAMESPACE}"
        return 1
    fi

    echo "Starting port-forward: localhost:${LOCAL_PORT} -> ${NAMESPACE}/svc/${SVC}:${REMOTE_PORT}"

    nohup kubectl port-forward -n "$NAMESPACE" "svc/${SVC}" "${LOCAL_PORT}:${REMOTE_PORT}" > "$OUT_FILE" 2>&1 &
    echo $! > "$PID_FILE"

    sleep 1

    if kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo "Started. PID=$(cat "$PID_FILE")"
        echo "Log: $OUT_FILE"
    else
        echo "Failed to start. Check $OUT_FILE"
        rm -f "$PID_FILE"
        return 1
    fi
}

stop() {
    if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        pid="$(cat "$PID_FILE")"
        echo "Stopping diag port-forward. PID=$pid"
        kill "$pid"
        rm -f "$PID_FILE"
        echo "Stopped."
        return 0
    fi

    echo "No PID file or process not running. Trying to find matching kubectl port-forward process..."

    pids=$(pgrep -f "kubectl port-forward -n ${NAMESPACE} svc/${SVC} ${LOCAL_PORT}:${REMOTE_PORT}" || true)

    if [[ -z "$pids" ]]; then
        echo "No matching diag port-forward process found."
        rm -f "$PID_FILE"
        return 0
    fi

    echo "$pids" | xargs kill
    rm -f "$PID_FILE"
    echo "Stopped matching process: $pids"
}

status() {
    if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo "Running. PID=$(cat "$PID_FILE")"
        echo "Forward: localhost:${LOCAL_PORT} -> ${NAMESPACE}/svc/${SVC}:${REMOTE_PORT}"
        return 0
    fi

    pids=$(pgrep -f "kubectl port-forward -n ${NAMESPACE} svc/${SVC} ${LOCAL_PORT}:${REMOTE_PORT}" || true)

    if [[ -n "$pids" ]]; then
        echo "Running, but PID file is missing or stale. PID=$pids"
        echo "Forward: localhost:${LOCAL_PORT} -> ${NAMESPACE}/svc/${SVC}:${REMOTE_PORT}"
    else
        echo "Not running."
    fi
}

case "${1:-}" in
    start)
        start
        ;;
    stop)
        stop
        ;;
    status)
        status
        ;;
    *)
        usage
        exit 1
        ;;
esac