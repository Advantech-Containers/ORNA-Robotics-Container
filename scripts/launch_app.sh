#!/bin/bash

set -e

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly COMPOSE_FILE="${BASE_DIR}/docker-compose.yaml"

launch_app_action() {
    local docker_action="$1"
    local env_args=()

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
        sleep 2
        docker compose -f "$COMPOSE_FILE" "${env_args[@]}" exec orna_services orna-backendctl start
        docker compose -f "$COMPOSE_FILE" "${env_args[@]}" exec orna_services systemctl start orna-lifecycle-manager.service
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