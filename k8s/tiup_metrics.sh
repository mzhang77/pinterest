
#!/bin/bash

usage() {
    cat <<EOF
Usage: $(basename "$0") <cluster> [from] [to] [prom|vm|k8s]

Upload TiDB Clinic metrics data to PingCap.

Arguments:
  cluster      Cluster name (required)
  from         Start time: relative offset (e.g. -7h) or absolute (e.g. 2026-01-28T01:59:00Z) (default: -1h)
  to           End time: relative offset (e.g. -4h) or absolute (e.g. 2026-01-28T03:30:00Z) (default: -0h)
  prom|vm|k8s  Metrics backend (default: auto-detect prom/vm, k8s must be specified)
               - prom: Prometheus on bare-metal/VM (localhost:9090/_/tsdb)
               - vm:   VictoriaMetrics on bare-metal/VM (localhost:8428)
               - k8s:  TiDB Operator on Kubernetes (via clinic diag API)

Examples:
  Bare-metal / VM:
  $(basename "$0") shared-vanilla-prod -7h -4h                                          # relative time, auto-detect
  $(basename "$0") shared-vanilla-prod -7h -4h vm                                       # relative time, force VM
  $(basename "$0") shared-vanilla-prod -7h -4h prom                                     # relative time, force Prom
  $(basename "$0") pikachu-prod "2026-01-28T01:59:00Z" "2026-01-28T03:30:00Z"           # absolute time (UTC)
  $(basename "$0") pikachu-prod "2026-01-28T09:59:00+08:00" "2026-01-28T11:30:00+08:00" # absolute time (CST)

  Kubernetes (TiDB Operator):
  $(basename "$0") pingraph-board-prod-eks -7h -4h k8s                                  # relative time
  $(basename "$0") pingraph-board-prod-eks "2026-03-18T16:30:00Z" "2026-03-18T17:30:00Z" k8s  # absolute time

Prerequisites:
  Bare-metal/VM: Run 'hologram use engineer' before executing.
  K8s: Requires kubectl access to the tidb-admin namespace.
EOF
    exit 0
}

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    usage
fi

cluster=$1
if ! [[ $cluster ]]
then
    usage
fi
shift
is_metrics_type() { [[ "$1" == "prom" || "$1" == "vm" || "$1" == "k8s" ]]; }
if is_metrics_type "$1"; then
    metrics_type=$1; shift; from=-1h; to=-0h
elif [[ $1 ]]; then
    from=$1; shift
    if is_metrics_type "$1"; then
        metrics_type=$1; shift; to=-0h
    elif [[ $1 ]]; then
        to=$1; shift
        metrics_type=${1:-auto}; shift 2>/dev/null
    else
        to=-0h; metrics_type=auto
    fi
else
    from=-1h; to=-0h; metrics_type=auto
fi
if [[ "$metrics_type" != "auto" && "$metrics_type" != "prom" && "$metrics_type" != "vm" && "$metrics_type" != "k8s" ]]; then
    echo >&2 "[ERROR] invalid metrics type '$metrics_type', must be 'prom', 'vm', 'k8s', or omitted for auto-detect"
    exit 1
fi
printf 'Dumping metrics for cluster %s...\n' "$cluster" >&2
printf 'from %s...\n' "$from" >&2
printf 'to %s...\n' "$to" >&2

# ── K8s mode (TiDB Operator) ──
if [[ "$metrics_type" == "k8s" ]]; then
    namespace="${cluster%-eks}"
    printf 'Mode: k8s\n' >&2
    printf 'Namespace: %s\n' "$namespace" >&2

    # Start port-forward (suppress "Handling connection" noise, keep errors)
    printf 'Starting kubectl port-forward...\n' >&2
    kubectl port-forward -n tidb-admin svc/diag 4917:4917 2>&1 | grep -v 'Handling connection' >&2 &
    pf_pid=$!
    trap "kill $pf_pid 2>/dev/null" EXIT
    # Wait for port-forward to be ready
    for i in $(seq 1 10); do
        if curl -s -o /dev/null http://localhost:4917/ 2>/dev/null; then
            printf '\r  port-forward ready.          \n' >&2
            break
        fi
        if ! kill -0 "$pf_pid" 2>/dev/null; then
            echo >&2 "[ERROR] kubectl port-forward failed to start"
            exit 1
        fi
        printf '\r  waiting for port-forward... (%ds)' "$i" >&2
        sleep 1
    done

    # Create collector
    printf 'Creating collector...\n' >&2
    create_resp=$(curl -s http://localhost:4917/api/v1/collectors -X POST \
        -H "Content-Type: application/json" \
        -d "{\"clusterName\": \"$cluster\", \"namespace\": \"$namespace\", \"from\": \"$from\", \"to\": \"$to\"}")
    collector_id=$(echo "$create_resp" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

    if [[ -z "$collector_id" ]]; then
        echo >&2 "[ERROR] failed to create collector. Response: $create_resp"
        exit 1
    fi
    printf 'Collector created: %s\n' "$collector_id" >&2

    # Poll collector status
    poll_interval=10
    elapsed=0
    while true; do
        status_resp=$(curl -s "http://localhost:4917/api/v1/collectors/$collector_id")
        status=$(echo "$status_resp" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
        printf '\r  [%ds] collecting: %s    ' "$elapsed" "$status" >&2
        if [[ "$status" == "finished" ]]; then
            printf '\n' >&2
            break
        elif [[ "$status" == "failed" ]]; then
            printf '\n' >&2
            echo >&2 "[ERROR] collector failed. Response: $status_resp"
            exit 1
        fi
        sleep "$poll_interval"
        elapsed=$((elapsed + poll_interval))
    done

    # Upload
    curl -s "http://localhost:4917/api/v1/data/$collector_id/upload" -X POST >/dev/null
    elapsed=0
    while true; do
        upload_resp=$(curl -s "http://localhost:4917/api/v1/data/$collector_id/upload")
        upload_status=$(echo "$upload_resp" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
        printf '\r  [%ds] uploading: %s    ' "$elapsed" "$upload_status" >&2
        if [[ "$upload_status" == "finished" ]]; then
            printf '\n' >&2
            break
        elif [[ "$upload_status" == "failed" ]]; then
            printf '\n' >&2
            echo >&2 "[ERROR] upload failed. Response: $upload_resp"
            exit 1
        fi
        sleep "$poll_interval"
        elapsed=$((elapsed + poll_interval))
    done

    clinic_url=$(echo "$upload_resp" | grep -o '"result":"[^"]*"' | head -1 | cut -d'"' -f4)
    printf 'Done! Clinic data uploaded for %s\n' "$cluster" >&2
    if [[ -n "$clinic_url" ]]; then
        printf 'Clinic link: %s\n' "$clinic_url" >&2
    fi
    exit 0
fi

# ── Bare-metal / VM mode ──
metrics_host=$( getin -H monitoring-"$cluster" )
if ! [[ $metrics_host ]]
then
    echo >&2 "[ERROR] could not identify monitoring host for cluster $cluster"
    exit 1
fi

if [[ "$metrics_type" == "auto" ]]; then
    printf 'Auto-detecting metrics backend on %s...\n' "$metrics_host" >&2
    ps_output=$(gironde ssh "$metrics_host" ps -ef 2>/dev/null)
    if [[ -z "$ps_output" ]]; then
        echo >&2 "[ERROR] failed to get process list from $metrics_host"
        exit 1
    fi
    if echo "$ps_output" | grep -q 'victoria-metrics-prod'; then
        metrics_type="vm"
    elif echo "$ps_output" | grep -q 'prometheus'; then
        metrics_type="prom"
    else
        echo >&2 "[ERROR] could not detect metrics backend on $metrics_host (neither prometheus nor victoria-metrics-prod found)"
        exit 1
    fi
    printf 'Detected metrics backend: %s\n' "$metrics_type" >&2
fi

if [[ "$metrics_type" == "vm" ]]; then
    prometheus_addr="localhost:8428"
else
    prometheus_addr="localhost:9090/_/tsdb"
fi
clinic_token=eyJrIjoiNmZpd3lOQUk0YVZqNjg3UiIsInUiOjUxOCwiaWQiOjEzNzI4MTMwODkxOTU2NTEyODZ9
if ! [[ $clinic_token ]]
then
    echo >&2 "[ERROR] could not find PingCAP clinic token - please set PINGCAP_CLINIC_TOKEN"
    exit 1
fi

output_dir="diag-$cluster-$(date -u +%s)"
pd_host_name=$(getin -H pd-"$cluster" | head -n1)
if ! [[ $pd_host_name ]]
then
    echo >&2 "[ERROR] could not identify PD host for cluster $cluster"
    exit 1
fi
pd_host="$pd_host_name.ec2.pin220.com:2379"

remote_script=$(cat <<EoSH
if ! [[ -f ~/.tiup/bin/tiup ]]
then
    curl --proto '=https' --tlsv1.2 -sSf https://tiup-mirrors.pingcap.com/install.sh | sh
fi
sudo mkdir /mnt/pingcap_diag_data
sudo chmod go+rw /mnt/pingcap_diag_data
cd /mnt/pingcap_diag_data
mkdir "$output_dir"
~/.tiup/bin/tiup diag config clinic.region US
~/.tiup/bin/tiup diag config clinic.token "$clinic_token"
~/.tiup/bin/tiup diag util metricdump --name $cluster \
    --pd="$pd_host" \
    --prometheus="$prometheus_addr" \
    --metricsfilter="node,process,probe,tidb,process,go_,tikv,pd,grpc,etcd,tiflash,binlog,ticdc,br,lightning,net_conntrack,os_fd,scrape,unistore,up" \
    --ca-file /var/lib/normandie/fuse/ca/root \
    --cert-file /var/lib/normandie/fuse/chain/generic \
    --key-file /var/lib/normandie/fuse/key/generic \
    --output "$output_dir" \
    --from "$from" --to "$to" --yes
~/.tiup/bin/tiup diag upload "$output_dir"
EoSH
)

gironde ssh "$metrics_host" bash -s <<<"$remote_script"