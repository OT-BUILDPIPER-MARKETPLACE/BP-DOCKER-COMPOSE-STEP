#!/bin/bash

SSH_AUTH_DIR="${SSH_AUTH_DIR:-}"

validate_inputs() {
    local failed=0

    if [[ -z "${SSH_HOST:-}" ]]; then
        logErrorMessage "SSH_HOST is not available"
        failed=1
    fi

    if [[ ! "${SSH_PORT}" =~ ^[0-9]+$ ]]; then
        logErrorMessage "SSH_PORT must be a number"
        failed=1
    fi

    case "$INSTRUCTION" in
        script)
            if [[ "$SCRIPT_SOURCE" == "workspace" ]]; then
                if [[ ! -f "$(local_script_path)" ]]; then
                    logErrorMessage "Local script not found at [$(local_script_path)]"
                    failed=1
                fi
            elif [[ "$SCRIPT_SOURCE" != "remote" ]]; then
                logErrorMessage "SCRIPT_SOURCE must be either remote or workspace"
                failed=1
            elif [[ -z "${REMOTE_SCRIPT_PATH:-}" ]]; then
                logErrorMessage "REMOTE_SCRIPT_PATH is not available"
                failed=1
            fi
            ;;
        up|down|pull|restart|ps)
            ;;
        *)
            logErrorMessage "Not a valid INSTRUCTION [$INSTRUCTION]. Use script, up, down, pull, restart or ps"
            failed=1
            ;;
    esac

    return "$failed"
}

local_script_path() {
    printf '%s\n' "${WORKSPACE}/${CODEBASE_DIR}/${LOCAL_SCRIPT_PATH}"
}

write_private_key() {
    local key_file="$1"
    local key_value
    local default_key

    if [[ -n "${SSH_PRIVATE_KEY:-}" ]]; then
        key_value="$SSH_PRIVATE_KEY"

        # The key can be passed as plain PEM/OpenSSH text or base64 encoded
        if [[ "$key_value" != *"PRIVATE KEY"* ]]; then
            key_value="$(printf '%s' "$key_value" | base64 -d 2>/dev/null)" || {
                logErrorMessage "SSH_PRIVATE_KEY is neither a private key nor valid base64"
                return 1
            }
        fi

        # Variables flattened to a single line keep literal \n separators
        key_value="${key_value//\\n/$'\n'}"
        printf '%s\n' "$key_value" | tr -d '\r' > "$key_file"
        return 0
    fi

    if [[ -z "${SSH_PRIVATE_KEY_PATH:-}" ]]; then
        for default_key in "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_rsa"; do
            if [[ -r "$default_key" ]]; then
                SSH_PRIVATE_KEY_PATH="$default_key"
                break
            fi
        done
    fi

    if [[ -z "${SSH_PRIVATE_KEY_PATH:-}" ]]; then
        logErrorMessage "SSH_PRIVATE_KEY or SSH_PRIVATE_KEY_PATH is not available"
        return 1
    fi

    if [[ ! -r "$SSH_PRIVATE_KEY_PATH" ]]; then
        logErrorMessage "SSH private key is not readable at [$SSH_PRIVATE_KEY_PATH]"
        return 1
    fi

    tr -d '\r' < "$SSH_PRIVATE_KEY_PATH" > "$key_file"
}

setup_ssh_auth() {
    set +x

    SSH_AUTH_DIR="$(mktemp -d /tmp/bp-ssh-auth.XXXXXX)" || {
        logErrorMessage "Failed to create the temporary SSH authentication directory"
        return 1
    }
    chmod 700 "$SSH_AUTH_DIR"

    SSH_KEY_FILE="$SSH_AUTH_DIR/id_key"
    SSH_KNOWN_HOSTS_FILE="$SSH_AUTH_DIR/known_hosts"

    ( umask 077 && write_private_key "$SSH_KEY_FILE" ) || return 1
    chmod 600 "$SSH_KEY_FILE"

    if ! ssh-keygen -y -f "$SSH_KEY_FILE" > /dev/null 2>&1; then
        logErrorMessage "SSH private key is invalid or protected by a passphrase"
        return 1
    fi

    local host_key_checking="${STRICT_HOST_KEY_CHECKING}"
    if [[ -n "${SSH_KNOWN_HOSTS:-}" ]]; then
        printf '%s\n' "$SSH_KNOWN_HOSTS" > "$SSH_KNOWN_HOSTS_FILE"
        host_key_checking="yes"
    else
        : > "$SSH_KNOWN_HOSTS_FILE"
        logWarningMessage "SSH_KNOWN_HOSTS is not set, host key of [$SSH_HOST] will be trusted on first use"
    fi

    SSH_OPTS=(
        -i "$SSH_KEY_FILE"
        -p "$SSH_PORT"
        -o BatchMode=yes
        -o IdentitiesOnly=yes
        -o ConnectTimeout="$SSH_CONNECT_TIMEOUT"
        -o ServerAliveInterval=30
        -o ServerAliveCountMax=6
        -o StrictHostKeyChecking="$host_key_checking"
        -o UserKnownHostsFile="$SSH_KNOWN_HOSTS_FILE"
        -o LogLevel=ERROR
    )
}

cleanup_ssh_auth() {
    set +x

    if [[ -n "${SSH_AUTH_DIR:-}" && -d "$SSH_AUTH_DIR" ]]; then
        rm -rf -- "$SSH_AUTH_DIR"
    fi

    unset SSH_AUTH_DIR SSH_KEY_FILE SSH_KNOWN_HOSTS_FILE
}

remote_ssh() {
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SSH_HOST}" "$@"
}

quote_remote_dir() {
    local dir="$1"

    # Keep ~ expandable on the remote side, quote everything else
    if [[ "$dir" == "~" ]]; then
        printf '"$HOME"'
    elif [[ "$dir" == "~/"* ]]; then
        printf '"$HOME"/%q' "${dir#\~/}"
    else
        printf '%q' "$dir"
    fi
}

build_remote_env() {
    local env_assignments=""
    local var_name

    for var_name in ${REMOTE_ENV_VARS:-}; do
        if [[ ! "$var_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            logErrorMessage "Invalid variable name [$var_name] in REMOTE_ENV_VARS"
            return 1
        fi
        env_assignments+=" $(printf '%s=%q' "$var_name" "${!var_name:-}")"
    done

    printf '%s' "$env_assignments"
}

build_remote_command() {
    local env_assignments
    local runner
    local remote_cmd="set -e"

    env_assignments="$(build_remote_env)" || return 1

    runner="env${env_assignments}"
    if [[ "$USE_SUDO" == "true" ]]; then
        runner="sudo -n ${runner}"
    fi

    if [[ -n "${REMOTE_WORKDIR:-}" ]]; then
        remote_cmd+="; cd $(quote_remote_dir "$REMOTE_WORKDIR")"
    fi

    case "$INSTRUCTION" in
        script)
            if [[ "$SCRIPT_SOURCE" == "workspace" ]]; then
                remote_cmd+="; ${runner} ${SCRIPT_INTERPRETER} -s -- ${SCRIPT_ARGS}"
            else
                remote_cmd+="; ${runner} ${SCRIPT_INTERPRETER} $(quote_remote_dir "$REMOTE_SCRIPT_PATH") ${SCRIPT_ARGS}"
            fi
            ;;
        *)
            local compose_args="-f $(printf '%q' "$COMPOSE_FILE")"
            if [[ -n "${COMPOSE_PROJECT_NAME:-}" ]]; then
                compose_args+=" -p $(printf '%q' "$COMPOSE_PROJECT_NAME")"
            fi

            remote_cmd+='; if docker compose version >/dev/null 2>&1; then DC="docker compose"; else DC="docker-compose"; fi'

            if [[ "$INSTRUCTION" == "up" ]]; then
                if [[ "$COMPOSE_PULL" == "true" ]]; then
                    remote_cmd+="; ${runner} \$DC ${compose_args} pull"
                fi
                remote_cmd+="; ${runner} \$DC ${compose_args} up -d ${COMPOSE_EXTRA_ARGS}"
            else
                remote_cmd+="; ${runner} \$DC ${compose_args} ${INSTRUCTION} ${COMPOSE_EXTRA_ARGS}"
            fi
            ;;
    esac

    printf '%s\n' "$remote_cmd"
}
