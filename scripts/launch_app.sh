#!/bin/bash

set -e

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly COMPOSE_FILE="${BASE_DIR}/docker-compose.yaml"

launch_app_action() {
    local docker_action="$1"
    local env_args=()

    if [ "$docker_action" = "start" ] && [ -f "${BASE_DIR}/.native-only" ]; then
        echo "Docker ORNA startup is disabled on this edge; use the native services."
        return 1
    fi

    if [ "$docker_action" != "start" ] && [ "$docker_action" != "stop" ] && [ "$docker_action" != "remove" ]; then
        echo "Usage: launch_app_action [start|stop|remove]"
        return 1
    fi

    if [ ! -f "$COMPOSE_FILE" ]; then
        echo "docker-compose.yaml was not found in: $BASE_DIR"
        return 1
    fi

    if [ -f "$RUNTIME_ENV_FILE" ]; then
        env_args=("--env-file" "$RUNTIME_ENV_FILE")
    fi

    if [ "$docker_action" = "stop" ] || [ "$docker_action" = "remove" ]; then
        mapfile -t backend_containers_array < <(docker ps -a --filter "name=^orna" --format '{{.ID}} {{.Labels}}' \
            | grep -v 'com.docker.compose.project' \
            | awk '{print $1}')

        if [ ${#backend_containers_array[@]} -gt 0 ]; then
            docker rm -f "${backend_containers_array[@]}"
        fi
        if [ "$docker_action" = "stop" ]; then
            docker compose -f "$COMPOSE_FILE" "${env_args[@]}" down
        else
            docker compose -f "$COMPOSE_FILE" "${env_args[@]}" down -v
        fi
    else
        docker compose -f "$COMPOSE_FILE" "${env_args[@]}" up -d

        # Stream container logs to the terminal so the operator can watch backendctl
        # install + FoundationPose engine build progress (trtexec %, retry rounds) live.
        local startup_log="/tmp/orna_startup_$(date +%s).log"
        echo "==> Tailing orna_services logs (backendctl install + FP engine build). Ctrl-C stops the tail only, not the container."
        docker compose -f "$COMPOSE_FILE" "${env_args[@]}" logs -f orna_services 2>&1 | tee -a "$startup_log" &
        local tail_pid=$!

        echo "Waiting for container systemd to become ready (backendctl install can take several minutes)..."
        local systemd_ready=0
        for _ in $(seq 1 600); do
            if docker compose -f "$COMPOSE_FILE" "${env_args[@]}" exec -T orna_services systemctl is-system-running 2>/dev/null | grep -Eq "^(running|degraded)$"; then
                systemd_ready=1
                break
            fi
            sleep 1
        done
        if [ "$systemd_ready" -ne 1 ]; then
            kill "$tail_pid" 2>/dev/null || true
            echo "Container systemd did not become ready within 10 minutes (see log above)." >&2
            return 1
        fi

        # Image entrypoint installs orna-backendctl automatically after systemd (PID1) is up.
        echo "Waiting for orna-backendctl services to become active..."
        local installed=0
        for _ in $(seq 1 300); do
            if docker compose -f "$COMPOSE_FILE" "${env_args[@]}" exec -T orna_services \
                bash -c 'for u in orna-stack-backend orna-lifecycle-manager orna-observer ParameterServer_Service; do systemctl is-active "$u.service" 2>/dev/null | grep -qx active || exit 1; done' 2>/dev/null; then
                installed=1
                break
            fi
            sleep 2
        done
        if [ "$installed" -ne 1 ]; then
            kill "$tail_pid" 2>/dev/null || true
            echo "[WARN] orna-backendctl services did not become active within 10 minutes (see log above)." >&2
            return 1
        fi

        # FP engine build runs AFTER backendctl and can take minutes (TensorRT score+refine).
        # restart: always means a hard-fail/OOM auto-restarts and retries, so keep watching
        # the log until it reports success or failure.
        echo "Waiting for FoundationPose engine build to complete (see log above for progress)..."
        local fp_result=0
        for _ in $(seq 1 900); do
            if grep -q "FoundationPose engines built successfully" "$startup_log" 2>/dev/null; then
                fp_result=1; break
            fi
            if grep -qE "FoundationPose engine build FAILED|halting container \(no inference|FoundationPose model dir missing" "$startup_log" 2>/dev/null; then
                fp_result=2; break
            fi
            sleep 2
        done
        kill "$tail_pid" 2>/dev/null || true

        if [ "$fp_result" -eq 1 ]; then
            echo "[OK] FoundationPose engines built successfully. Stack is ready."
        elif [ "$fp_result" -eq 2 ]; then
            echo "[ERROR] FoundationPose engine build FAILED (container halting / will auto-restart per restart:always) - see log above." >&2
            return 1
        else
            echo "[WARN] FoundationPose engine build did not report completion within the timeout; check: docker compose logs orna_services" >&2
        fi
        return 0
    fi
}

launch_app_start() {
    launch_app_action start
}

launch_app_stop() {
    launch_app_action stop
}

launch_app_remove() {
    launch_app_action remove
}