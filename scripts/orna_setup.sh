#!/usr/bin/env bash

set -Eeuo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly BASE_DIR="$(cd "${BASE_DIR}/.." && pwd)"
readonly ORNA_SETUP_TITLE="ORNA setup assistant"
readonly APP_NAME="orna_app"
readonly HOST_ARCH="$([ "$(uname -m)" = "aarch64" ] && ([ -f "/etc/nv_tegra_release" ] && echo "jetson" || echo "arm64") || uname -m)"
readonly ORNA_PROJECT="harbor.edgesync.cloud/orna_system"
declare -A ORNA_IMAGES
declare -A ORNA_IMAGE_VERSIONS
IMAGES_VERSION="v0.2.0"

STATE_FILE="${BASE_DIR}/.orna_setup_state"
VERSION_FILE="${BASE_DIR}/.orna.version"

CURRENT_USER="${SUDO_USER:-$(id -un)}"

CURRENT_STEP="idle"
SETUP_IN_PROGRESS=0
RUNTIME_ENV_CREATED_THIS_RUN=0

load_orna_version() {
    if [[ ! -f "$VERSION_FILE" ]]; then
        return 0
    fi

    ORNA_IMAGE_VERSIONS[be]="$IMAGES_VERSION"
    ORNA_IMAGE_VERSIONS[fe]="$IMAGES_VERSION"
    ORNA_IMAGE_VERSIONS[ide]="$IMAGES_VERSION"

    while IFS='=' read -r key value; do
        if [[ -z "$key" || -z "$value" ]]; then
            continue
        fi
        case "$key" in
            be|fe|ide)
                ORNA_IMAGE_VERSIONS[$key]="$value"
                ;;
        esac
    done < "$VERSION_FILE"

    IMAGES_VERSION="${ORNA_IMAGE_VERSIONS[be]}"
}

save_orna_version() {
    printf 'be=%s\nfe=%s\nide=%s\n' \
        "${ORNA_IMAGE_VERSIONS[be]}" \
        "${ORNA_IMAGE_VERSIONS[fe]}" \
        "${ORNA_IMAGE_VERSIONS[ide]}" \
        > "$VERSION_FILE"
}

set_orna_images() {

    ORNA_IMAGE_VERSIONS[be]="${ORNA_IMAGE_VERSIONS[be]:-$IMAGES_VERSION}"
    ORNA_IMAGE_VERSIONS[fe]="${ORNA_IMAGE_VERSIONS[fe]:-$IMAGES_VERSION}"
    ORNA_IMAGE_VERSIONS[ide]="${ORNA_IMAGE_VERSIONS[ide]:-$IMAGES_VERSION}"

    ORNA_IMAGES[be]="${ORNA_PROJECT}/orna_service:${HOST_ARCH}-${ORNA_IMAGE_VERSIONS[be]}"
    ORNA_IMAGES[fe]="${ORNA_PROJECT}/orna_ui:${HOST_ARCH}-${ORNA_IMAGE_VERSIONS[fe]}"
    ORNA_IMAGES[ide]="${ORNA_PROJECT}/orna_ide:${HOST_ARCH}-${ORNA_IMAGE_VERSIONS[ide]}"

    save_orna_version
}

load_orna_version

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Error: required command not found: $1"
        exit 1
    }
}

show_msg() {
    if command -v whiptail >/dev/null 2>&1; then
        whiptail --title "$ORNA_SETUP_TITLE" --msgbox "$1" 14 78
    else
        printf '%s\n' "$1"
    fi
}

show_error() {
    if command -v whiptail >/dev/null 2>&1; then
        whiptail --title "$ORNA_SETUP_TITLE" --msgbox "Error:\n\n$1" 14 78
    else
        printf 'Error: %s\n' "$1" >&2
    fi
}

confirm_box() {
    if command -v whiptail >/dev/null 2>&1; then
        whiptail --title "$ORNA_SETUP_TITLE" --yesno "$1" 14 78
    else
        read -r -p "$1 [y/N]: " reply
        [[ "${reply}" =~ ^[Yy]$ ]]
    fi
}

input_box() {
    local prompt="$1"
    local default_value="${2:-}"
    if command -v whiptail >/dev/null 2>&1; then
        whiptail --title "$ORNA_SETUP_TITLE" --inputbox "$prompt" 12 78 "$default_value" 3>&1 1>&2 2>&3
    else
        read -r -p "$prompt [$default_value]: " reply
        if [[ -z "$reply" ]]; then
            reply="$default_value"
        fi
        printf '%s' "$reply"
    fi
}

password_box() {
    local prompt="$1"
    if command -v whiptail >/dev/null 2>&1; then
        whiptail --title "$ORNA_SETUP_TITLE" --passwordbox "$prompt" 12 78 3>&1 1>&2 2>&3
    else
        local reply
        read -r -s -p "$prompt: " reply
        printf '\n' >&2
        printf '%s' "$reply"
    fi
}

write_state() {
    cat > "$STATE_FILE" <<EOF
SETUP_IN_PROGRESS=${SETUP_IN_PROGRESS}
CURRENT_STEP=${CURRENT_STEP}
EOF
}

clear_state() {
    rm -f "$STATE_FILE"
}

cleanup_on_interrupt() {
    local signal="${1:-INT}"

    if [[ "$SETUP_IN_PROGRESS" -eq 1 ]]; then
        case "$CURRENT_STEP" in
            create_runtime_env)
                if [[ "$RUNTIME_ENV_CREATED_THIS_RUN" -eq 1 ]]; then
                    rm -f "$RUNTIME_ENV_FILE"
                fi
                ;;
            docker_pull)
                # Keep runtime.env because setup may already be valid enough
                # for a rerun, and Docker safely resumes/reuses layers later.
                ;;
        esac

        clear_state

        show_error "Setup was interrupted by ${signal} during step:\n\n${CURRENT_STEP}\n\nYou can safely run the setup again."
    fi

    exit 130
}

on_error() {
    local exit_code=$?
    clear_state

    if [[ "$SETUP_IN_PROGRESS" -eq 1 ]]; then
        show_error "Setup failed during step:\n\n${CURRENT_STEP}\n\nExit code: ${exit_code}"
    fi

    exit "$exit_code"
}

trap 'cleanup_on_interrupt INT' INT
trap 'cleanup_on_interrupt TERM' TERM
trap 'on_error' ERR

write_runtime_env() {
    local env_hostname="${1:-$(hostname)}"
    
    set_orna_images
    
    tee  "$RUNTIME_ENV_FILE" > /dev/null <<EOF
HOSTNAME=${env_hostname}
ORNA_SERVICES_IMAGE=${ORNA_IMAGES[be]}
ORNA_UI_IMAGE=${ORNA_IMAGES[fe]}
EOF
}

create_runtime_env() {
    CURRENT_STEP="create_runtime_env"
    write_state

    write_runtime_env

    RUNTIME_ENV_CREATED_THIS_RUN=1
}

configure_docker_daemon() {
    CURRENT_STEP="configure_docker"
    write_state

    sudo systemctl stop docker || true
    sudo mkdir -p /etc/systemd/system/docker.service.d
    sudo mkdir -p /etc/docker

    sudo tee /etc/systemd/system/docker.service.d/99-orna.conf > /dev/null <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/dockerd
EOF

    ensure_docker_daemon_config

    sudo systemctl daemon-reexec
    sudo systemctl daemon-reload
    sudo systemctl restart docker
}

write_default_daemon_json() {
    cat <<'EOF'
{
    "runtimes": {
        "nvidia": {
            "args": [],
            "path": "nvidia-container-runtime"
        }
    },
    "default-runtime": "nvidia",
    "hosts": [
        "unix:///var/run/docker.sock",
        "tcp://127.0.0.1:1234"
    ]
}
EOF
}

ensure_top_level_key() {
    local key="$1"
    local entry="$2"
    local file="$3"
    local tmp

    if grep -q "\"${key}\"" "$file"; then
        return 0
    fi

    tmp="$(mktemp)"
    awk -v entry="$entry" '
        { lines[NR] = $0 }
        END {
            last = NR - 1
            for (i = NR - 1; i >= 1; i--) {
                if (lines[i] ~ /[^[:space:]]/) {
                    last = i
                    break
                }
            }

            if (lines[last] !~ /[{[][[:space:]]*$/ && lines[last] !~ /,[[:space:]]*$/) {
                lines[last] = lines[last] ","
            }

            for (i = 1; i < NR; i++) {
                print lines[i]
            }
            print comma entry
            print lines[NR]
        }
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
}

insert_after_pattern_once() {
    local file="$1"
    local pattern="$2"
    local insert_line="$3"
    local tmp

    tmp="$(mktemp)"
    awk -v pattern="$pattern" -v insert_line="$insert_line" '
        { print }
        $0 ~ pattern && !done {
            print insert_line
            done = 1
        }
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
}

ensure_nvidia_runtime() {
    local file="$1"

    if ! grep -q '"runtimes"' "$file"; then
        ensure_top_level_key "runtimes" '    "runtimes": {
        "nvidia": {
            "args": [],
            "path": "nvidia-container-runtime"
        }
    }' "$file"
        return 0
    fi

    if grep -q '"nvidia-container-runtime"' "$file"; then
        return 0
    fi

    if grep -q '"runtimes"[[:space:]]*:[[:space:]]*{[[:space:]]*}' "$file"; then
        local tmp
        tmp="$(mktemp)"
        awk '
            {
                if ($0 ~ /"runtimes"[[:space:]]*:[[:space:]]*{[[:space:]]*}/) {
                    print "    \"runtimes\": {"
                    print "        \"nvidia\": {"
                    print "            \"args\": [],"
                    print "            \"path\": \"nvidia-container-runtime\""
                    print "        }"
                    print "    }"
                    next
                }
                print
            }
        ' "$file" > "$tmp"
        mv "$tmp" "$file"
        return 0
    fi

    insert_after_pattern_once "$file" '"runtimes"[[:space:]]*:[[:space:]]*{' '        "nvidia": {
            "args": [],
            "path": "nvidia-container-runtime"
        },'
}

ensure_hosts() {
    local file="$1"
    local host
    local hosts=(
        "unix:///var/run/docker.sock"
        "tcp://127.0.0.1:1234"
    )

    if ! grep -q '"hosts"' "$file"; then
        ensure_top_level_key "hosts" '    "hosts": [
        "unix:///var/run/docker.sock",
        "tcp://127.0.0.1:1234"
    ]' "$file"
        return 0
    fi

    if grep -q '"hosts"' "$file"; then
        local missing=0
        for host in "${hosts[@]}"; do
            if ! grep -q "\"${host}\"" "$file"; then
                missing=1
                break
            fi
        done

        if [[ "$missing" -eq 0 ]]; then
            return 0
        fi

        local tmp
        tmp="$(mktemp)"
        awk '
            {
                if ($0 ~ /"hosts"[[:space:]]*:[[:space:]]*\[/) {
                    print "    \"hosts\": ["
                    print "        \"unix:///var/run/docker.sock\"," 
                    print "        \"tcp://127.0.0.1:1234\""
                    print "    ]"
                    in_hosts = 1
                    next
                }
                if (in_hosts) {
                    if ($0 ~ /\]/) {
                        in_hosts = 0
                    }
                    next
                }
                print
            }
        ' "$file" > "$tmp"
        mv "$tmp" "$file"
        return 0
    fi

    ensure_top_level_key "hosts" '    "hosts": [
        "unix:///var/run/docker.sock",
        "tcp://127.0.0.1:1234"
    ]' "$file"
}

ensure_docker_daemon_config() {
    local daemon_file="/etc/docker/daemon.json"
    local tmp

    tmp="$(mktemp)"
    if sudo test -s "$daemon_file"; then
        sudo cat "$daemon_file" > "$tmp"
    else
        write_default_daemon_json > "$tmp"
    fi

    ensure_nvidia_runtime "$tmp"
    ensure_top_level_key "default-runtime" '    "default-runtime": "nvidia"' "$tmp"
    ensure_hosts "$tmp"

    sudo tee "$daemon_file" > /dev/null < "$tmp"
    rm -f "$tmp"
}

contaner_registry_login()
{
    local registry="$1"
    local registry_username="$2"
    local registry_token="$3"
    CURRENT_STEP="registry_login"
    write_state
    printf '%s' "$registry_token" | docker login "$registry" -u "$registry_username" --password-stdin
}

container_registry_logout() {
    local registry="$1"

    if [[ -n "$registry" ]]; then
        docker logout "$registry" >/dev/null 2>&1 || true
    fi
}

image_pull() {

    local orna_image="$1"

    CURRENT_STEP="image_pull"
    write_state
    docker pull "${orna_image}"

    if [[ "$orna_image" == "${ORNA_IMAGES[ide]}" ]]; then
        docker tag "${ORNA_IMAGES[ide]}" "orna-code-server:latest"
    fi
}

update_runtime_env_images() {
    local env_hostname=""

    if [[ -f "$RUNTIME_ENV_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$RUNTIME_ENV_FILE" || true
        env_hostname="${HOSTNAME:-}"
    fi

    write_runtime_env "$env_hostname"
}


install_system_images() {
    local dockerhub_username
    local dockerhub_token
    local registry_host

    dockerhub_username="$(input_box "Enter registry username:")" || return 0
    dockerhub_token="$(password_box "Enter registry access token:")" || return 0

    if [[ -z "$dockerhub_username" || -z "$dockerhub_token" ]]; then
        show_error "Contaner Registry username, and password are required."
        return 1
    fi

    set_orna_images 
    registry_host="${ORNA_PROJECT}"
    contaner_registry_login "$registry_host" "$dockerhub_username" "$dockerhub_token"

    for orna_image in "${ORNA_IMAGES[@]}"; do
        image_pull "$orna_image"
    done

    container_registry_logout "$registry_host"

    show_msg "Images installed successfully."
}

update_orna_images() {
    local be_version
    local fe_version
    local ide_version

    be_version="$(input_box "Enter backend image version tag:" "${ORNA_IMAGE_VERSIONS[be]:-$IMAGES_VERSION}")" || return 0
    fe_version="$(input_box "Enter UI image version tag:" "${ORNA_IMAGE_VERSIONS[fe]:-$IMAGES_VERSION}")" || return 0
    ide_version="$(input_box "Enter IDE image version tag:" "${ORNA_IMAGE_VERSIONS[ide]:-$IMAGES_VERSION}")" || return 0

    ORNA_IMAGE_VERSIONS[be]="$be_version"
    ORNA_IMAGE_VERSIONS[fe]="$fe_version"
    ORNA_IMAGE_VERSIONS[ide]="$ide_version"

    set_orna_images
    update_runtime_env_images
    install_system_images

    show_msg "Images updated successfully."
}

setup_install() {
    local dockerhub_username
    local dockerhub_token

    if ! confirm_box "This will:\n\n1. Create runtime.env\n2. Reconfigure Docker daemon\n3. Run docker login\n\nDo you want to continue?"; then
        return 0
    fi

    SETUP_IN_PROGRESS=1
    CURRENT_STEP="starting"
    write_state

    create_runtime_env
    
    configure_docker_daemon

    SETUP_IN_PROGRESS=0
    CURRENT_STEP="completed"
    clear_state

    show_msg "Setup completed successfully.\n\nCreated:\n${RUNTIME_ENV_FILE}"
}


show_resume_notice_if_needed() {
    if [[ -f "$STATE_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$STATE_FILE" || true

        if [[ "${SETUP_IN_PROGRESS:-0}" -eq 1 ]]; then
            show_msg "A previous setup did not finish.\n\nLast known step:\n${CURRENT_STEP:-unknown}\n\nYou can run Setup / Install again."
            clear_state
        fi
    fi
}

ensure_setup_deps() {
    # require_command whiptail
    require_command bash
    require_command sudo
    require_command docker
    require_command tee
    require_command systemctl
}
