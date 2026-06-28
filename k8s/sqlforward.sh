
#!/usr/bin/env bash
set -euo pipefail

LOCAL_PORT="14000"
REMOTE_PORT="4000"
OUT_FILE="pf14000.out"
PID_FILE=".pf14000.pid"

get_namespace() {
    ns="$(kubectl config view --minify --output 'jsonpath={..namespace}')"
    if [[ -z "$ns" ]]; then
        ns="default"
    fi
    echo "$ns"
}

get_service_name() {
    ns="$(get_namespace)"
    echo "${ns}-eks-tidb"
}

usage() {
    echo "Usage: $(basename "$0") start|stop|status"
}

start() {
    SVC="$(get_service_name)"

    if ! kubectl get svc "$SVC" >/dev/null 2>&1; then
        echo "Service not found: $SVC"
        echo "Current namespace: $(get_namespace)"
        echo
        echo "Available tidb services:"
        kubectl get svc | grep -- '-tidb' || true
        return 1
    fi

    if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo "port-forward is already running. PID=$(cat "$PID_FILE")"
        return 0
    fi

    echo "Current namespace: $(get_namespace)"
    echo "Starting port-forward: localhost:${LOCAL_PORT} -> svc/${SVC}:${REMOTE_PORT}"

    nohup kubectl port-forward "svc/${SVC}" "${LOCAL_PORT}:${REMOTE_PORT}" > "$OUT_FILE" 2>&1 &
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
    SVC="$(get_service_name)"

    if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        pid="$(cat "$PID_FILE")"
        echo "Stopping port-forward. PID=$pid"
        kill "$pid"
        rm -f "$PID_FILE"
        echo "Stopped."
        return 0
    fi

    echo "No PID file or process not running. Trying to find matching kubectl port-forward process..."

    pids=$(pgrep -f "kubectl port-forward svc/${SVC} ${LOCAL_PORT}:${REMOTE_PORT}" || true)

    if [[ -z "$pids" ]]; then
        echo "No matching port-forward process found."
        rm -f "$PID_FILE"
        return 0
    fi

    echo "$pids" | xargs kill
    rm -f "$PID_FILE"
    echo "Stopped matching process: $pids"
}

status() {
    SVC="$(get_service_name)"

    if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo "Running. PID=$(cat "$PID_FILE")"
        echo "Service: svc/${SVC}"
        echo "Local port: ${LOCAL_PORT}"
        return 0
    fi

    pids=$(pgrep -f "kubectl port-forward svc/${SVC} ${LOCAL_PORT}:${REMOTE_PORT}" || true)

    if [[ -n "$pids" ]]; then
        echo "Running, but PID file is missing or stale."
        echo "PID=$pids"
        echo "Service: svc/${SVC}"
    else
        echo "Not running."
        echo "Expected service: svc/${SVC}"
        echo "Current namespace: $(get_namespace)"
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