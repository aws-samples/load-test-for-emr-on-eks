#!/usr/bin/env bash
# Keep a Grafana port-forward alive until explicitly stopped.
#
# Grafana is ClusterIP-only (no public ingress), so it is reached over a
# `kubectl port-forward`. A single port-forward dies on pod restarts or idle
# timeouts, so this wrapper runs it in a reconnect loop and records its PID,
# giving a session that survives drops and stays up until you stop it.
#
# Usage:
#   ./grafana-portforward.sh start     # start detached, keeps reconnecting
#   ./grafana-portforward.sh stop      # stop the session
#   ./grafana-portforward.sh status    # is it running?
#
# Then open http://localhost:3000 (user: admin). Override the local port with
# GRAFANA_LOCAL_PORT=8080 ./grafana-portforward.sh start
set -uo pipefail

NAMESPACE="${GRAFANA_NAMESPACE:-prometheus}"
SERVICE="${GRAFANA_SERVICE:-prometheus-grafana}"
LOCAL_PORT="${GRAFANA_LOCAL_PORT:-3000}"
REMOTE_PORT="${GRAFANA_REMOTE_PORT:-80}"
PID_FILE="${TMPDIR:-/tmp}/grafana-portforward-${LOCAL_PORT}.pid"
LOG_FILE="${TMPDIR:-/tmp}/grafana-portforward-${LOCAL_PORT}.log"

is_running() { [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; }

case "${1:-}" in
  start)
    if is_running; then
      echo "Already running (pid $(cat "$PID_FILE")) on http://localhost:${LOCAL_PORT}"
      exit 0
    fi
    # Detach a supervisor loop that restarts the port-forward whenever it drops.
    nohup bash -c '
      while true; do
        kubectl port-forward -n "'"$NAMESPACE"'" "svc/'"$SERVICE"'" \
          "'"$LOCAL_PORT"':'"$REMOTE_PORT"'" --address 127.0.0.1
        echo "[$(date)] port-forward exited, reconnecting in 2s..." >&2
        sleep 2
      done
    ' >"$LOG_FILE" 2>&1 &
    echo $! >"$PID_FILE"
    sleep 4
    if is_running; then
      echo "Started (pid $(cat "$PID_FILE")). Grafana: http://localhost:${LOCAL_PORT}"
      echo "Log: $LOG_FILE   Stop with: $0 stop"
    else
      echo "Failed to start; see $LOG_FILE"; exit 1
    fi
    ;;
  stop)
    if is_running; then
      PID="$(cat "$PID_FILE")"
      # Kill the supervisor and any child kubectl it spawned.
      pkill -P "$PID" 2>/dev/null
      kill "$PID" 2>/dev/null
      rm -f "$PID_FILE"
      echo "Stopped."
    else
      echo "Not running."
      rm -f "$PID_FILE"
    fi
    ;;
  status)
    if is_running; then
      echo "Running (pid $(cat "$PID_FILE")) on http://localhost:${LOCAL_PORT}"
    else
      echo "Not running."
    fi
    ;;
  *)
    echo "Usage: $0 {start|stop|status}"; exit 1;;
esac
