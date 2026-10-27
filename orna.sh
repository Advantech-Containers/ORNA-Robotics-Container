#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPTS_DIR="${SCRIPT_DIR}/scripts"
readonly ORNA_TITLE="ORNA control"
readonly RUNTIME_ENV_FILE="${SCRIPT_DIR}/.env"
readonly -a NATIVE_SERVICE_NAMES=(
    orna-frontend.service
    orna-stack-backend.service
    orna-lifecycle-manager.service
    orna-observer.service
    ParameterServer_Service.service
    orna-grasp-point-server.service
    orna-gripper-command-bridge.service
    orna-ur-program-watchdog.service
)

if [[ -f "${SCRIPTS_DIR}/launch_app.sh" ]]; then
    # shellcheck disable=SC1090
    source "${SCRIPTS_DIR}/launch_app.sh"
else
    printf 'Error: launch_app.sh was not found in: %s\n' "${SCRIPTS_DIR}" >&2
    exit 1
fi

if [[ -f "${SCRIPTS_DIR}/orna_setup.sh" ]]; then
    # shellcheck disable=SC1090
    source "${SCRIPTS_DIR}/orna_setup.sh"
else
    printf 'Error: orna_setup.sh was not found in: %s\n' "${SCRIPTS_DIR}" >&2
    exit 1
fi

has_whiptail() {
    command -v whiptail >/dev/null 2>&1
}

show_msg() {
    if has_whiptail; then
        whiptail --title "$ORNA_TITLE" --msgbox "$1" 14 78
    else
        printf '%s\n' "$1"
    fi
}

show_error() {
    if has_whiptail; then
        whiptail --title "$ORNA_TITLE" --msgbox "Error:\n\n$1" 14 78
    else
        printf 'Error: %s\n' "$1" >&2
    fi
}

confirm_box() {
    if has_whiptail; then
        whiptail --title "$ORNA_TITLE" --yesno "$1" 14 78
    else
        read -r -p "$1 [y/N]: " reply
        [[ "${reply}" =~ ^[Yy]$ ]]
    fi
}

require_command() {
    command -v "$1" >/dev/null 2>&1
}

check_deps() {
    local missing=()

    if ! require_command docker; then
        missing+=("docker")
    fi

    if ! docker compose version >/dev/null 2>&1; then
        missing+=("docker compose")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        show_error "Missing dependencies:\n- ${missing[*]}"
        return 1
    fi

    show_msg "All required dependencies are available."
}

run_setup() {
    ensure_setup_deps
    show_resume_notice_if_needed
    setup_install
}

update_images() {
    update_orna_images
}

install_images() {
    install_system_images
}

app_start() {
    launch_app_start
}

app_stop() {
    launch_app_stop
}

app_stop_native_services() {
    if ! confirm_box "Stop and disable all ORNA native systemd services? Docker services will remain untouched."; then
        return 0
    fi

    sudo systemctl disable --now "${NATIVE_SERVICE_NAMES[@]}"
    show_msg "ORNA native systemd services were stopped and disabled. Docker services were not changed."
}

app_start_native_services() {
    local service
    local status_summary=""
    local systemctl_output=""

    if ! confirm_box "Enable and start all ORNA native systemd services? Stop the Docker application first to avoid conflicts."; then
        return 0
    fi

    if ! systemctl_output=$(sudo systemctl enable --now "${NATIVE_SERVICE_NAMES[@]}" 2>&1); then
        show_error "Failed to enable/start ORNA native services:\n\n${systemctl_output}"
        return 1
    fi

    for service in "${NATIVE_SERVICE_NAMES[@]}"; do
        status_summary+="${service}: $(systemctl is-active "${service}" 2>/dev/null || true)"$'\n'
    done

    show_msg "ORNA native systemd services were enabled and started.\n\n${status_summary}"
}

app_check_native_services() {
    local service
    local active_status
    local enabled_status
    local status_summary=""

    for service in "${NATIVE_SERVICE_NAMES[@]}"; do
        active_status=$(systemctl is-active "${service}" 2>/dev/null || true)
        enabled_status=$(systemctl is-enabled "${service}" 2>/dev/null || true)
        active_status=${active_status:-not-found}
        enabled_status=${enabled_status:-not-found}
        status_summary+="${service}: active=${active_status}, enabled=${enabled_status}"$'\n'
    done

    show_msg "ORNA native systemd service status:\n\n${status_summary}"
}

developer_tools_whiptail() {
    while true; do
        local choice

        choice=$(
            whiptail --title "$ORNA_TITLE - Developer tools" --menu "Choose an action:" 16 78 4 \
                "1" "Stop native services" \
                "2" "Start native services" \
                "3" "Check native services status" \
                "4" "Back" \
                3>&1 1>&2 2>&3
        ) || break

        case "$choice" in
            1) app_stop_native_services ;;
            2) app_start_native_services ;;
            3) app_check_native_services ;;
            4) break ;;
        esac
    done
}

developer_tools_cli() {
    while true; do
        printf '\nDeveloper tools\n'
        printf '1) Stop native services\n'
        printf '2) Start native services\n'
        printf '3) Check native services status\n'
        printf '4) Back\n'
        read -r -p "Choose an action [1-4]: " choice

        case "$choice" in
            1) app_stop_native_services ;;
            2) app_start_native_services ;;
            3) app_check_native_services ;;
            4) break ;;
            *) printf 'Invalid choice.\n' ;;
        esac
    done
}

app_remove() {
    if confirm_box "This will remove containers and volumes. Continue?"; then
        launch_app_remove
    fi
}

menu_whiptail() {
    while true; do
        local choice

        choice=$(
            whiptail --title "$ORNA_TITLE" --menu "Choose an action:" 18 78 9 \
                "1" "Check system dependencies" \
                "2" "Setup system" \
                "3" "Install ORNA images" \
                "4" "Update ORNA images" \
                "5" "Start application" \
                "6" "Stop application" \
                "7" "Remove containers/volumes" \
                "8" "Developer tools" \
                "9" "Exit" \
                3>&1 1>&2 2>&3
        ) || break

        case "$choice" in
            1) check_deps ;;
            2) run_setup ;;
            3) install_images ;;
            4) update_images ;;
            5) app_start ;;
            6) app_stop ;;
            7) app_remove ;;
            8) developer_tools_whiptail ;;
            9) break ;;
        esac
    done
}

menu_cli() {
    while true; do
        printf '\nORNA control\n'
        printf '1) Check system dependencies\n'
        printf '2) Setup system\n'
        printf '3) Install ORNA images\n'
        printf '4) Update ORNA images\n'
        printf '5) Start application\n'
        printf '6) Stop application\n'
        printf '7) Remove containers/volumes\n'
        printf '8) Developer tools\n'
        printf '9) Exit\n'
        read -r -p "Choose an action [1-9]: " choice

        case "$choice" in
            1) check_deps ;;
            2) run_setup ;;
            3) install_images ;;
            4) update_images ;;
            5) app_start ;;
            6) app_stop ;;
            7) app_remove ;;
            8) developer_tools_cli ;;
            9) break ;;
            *) printf 'Invalid choice.\n' ;;
        esac
    done
}

main() {
    if has_whiptail; then
        menu_whiptail
    else
        menu_cli
    fi
}

main "$@"
