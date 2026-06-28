#!/usr/bin/env bash
set -euo pipefail

nohup kubectl port-forward -n tidb-admin svc/diag 4917:4917 &