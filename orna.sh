#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPTS_DIR="${SCRIPT_DIR}/scripts"
readonly ORNA_TITLE="ORNA control"
readonly RUNTIME_ENV_FILE="${SCRIPT_DIR}/.env"

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

app_remove() {
    if confirm_box "This will remove containers and volumes. Continue?"; then
        launch_app_remove
    fi
}

menu_whiptail() {
    while true; do
        local choice

        choice=$(
            whiptail --title "$ORNA_TITLE" --menu "Choose an action:" 18 78 8 \
                "1" "Check system dependencies" \
                "2" "Setup system" \
                "3" "Install ORNA images" \
                "4" "Update ORNA images" \
                "5" "Start application" \
                "6" "Stop application" \
                "7" "Remove containers/volumes" \
                "8" "Exit" \
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
            8) break ;;
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
        printf '8) Exit\n'
        read -r -p "Choose an action [1-8]: " choice

        case "$choice" in
            1) check_deps ;;
            2) run_setup ;;
            3) install_images ;;
            4) update_images ;;
            5) app_start ;;
            6) app_stop ;;
            7) app_remove ;;
            8) break ;;
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
