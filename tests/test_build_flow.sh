#!/bin/bash

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURE_DIR="$(mktemp -d)"

cleanup() {
    rm -rf -- "$FIXTURE_DIR"
}
trap cleanup EXIT

mkdir -p "$FIXTURE_DIR/bin" "$FIXTURE_DIR/workspace/code/deploy"

# Fake ssh: records the key file, target and remote command of every call
cat > "$FIXTURE_DIR/bin/ssh" <<'EOF'
#!/bin/bash

key_file=""
args=("$@")
for (( i = 0; i < ${#args[@]}; i++ )); do
    [[ "${args[$i]}" == "-i" ]] && key_file="${args[$((i + 1))]}"
done

[[ -f "$key_file" ]] || exit 41
[[ "$(stat -c '%a' "$key_file")" == "600" ]] || exit 42
printf '%s\n' "$key_file" > "$SSH_MARKER.keyfile"

remote_command="${args[-1]}"
target="${args[-2]}"

if [[ "$remote_command" == "true" ]]; then
    printf '%s\n' "$target" > "$SSH_MARKER.connect"
    exit "${FAKE_CONNECT_STATUS:-0}"
fi

printf '%s\n' "$remote_command" > "$SSH_MARKER.command"
cat > "$SSH_MARKER.stdin"
exit "${FAKE_REMOTE_STATUS:-0}"
EOF
chmod 700 "$FIXTURE_DIR/bin/ssh"

printf '#!/bin/bash\necho deploying\n' > "$FIXTURE_DIR/workspace/code/deploy/run.sh"
ssh-keygen -q -t ed25519 -N '' -C test -f "$FIXTURE_DIR/test_key" > /dev/null

logInfoMessage() {
    printf '[INFO] %s\n' "$*"
}

logErrorMessage() {
    printf '[ERROR] %s\n' "$*" >&2
}

logWarningMessage() {
    printf '[WARNING] %s\n' "$*" >&2
}

saveTaskStatus() {
    printf '%s\n' "$1" > "$SSH_MARKER.status"
}

export -f logInfoMessage logErrorMessage logWarningMessage saveTaskStatus

export PATH="$FIXTURE_DIR/bin:$PATH"
export WORKSPACE="$FIXTURE_DIR/workspace"
export CODEBASE_DIR="code"
export SLEEP_DURATION=0
export SSH_HOST="10.0.0.5"
export SSH_MARKER="$FIXTURE_DIR/ssh"

failed=0

check() {
    local description="$1"
    shift

    if "$@"; then
        printf 'PASS: %s\n' "$description"
    else
        printf 'FAIL: %s\n' "$description" >&2
        failed=1
    fi
}

contains() {
    [[ "$1" == *"$2"* ]]
}

not_contains() {
    [[ "$1" != *"$2"* ]]
}

run_build() {
    rm -f "$SSH_MARKER".*
    output="$(cd "$PROJECT_DIR" && env "$@" bash ./build.sh 2>&1)"
    status=$?
}

# 1. Remote run.sh with base64 key and forwarded variables
run_build \
    SSH_PRIVATE_KEY="$(base64 -w0 < "$FIXTURE_DIR/test_key")" \
    REMOTE_WORKDIR="~/app" \
    REMOTE_ENV_VARS="IMAGE_TAG" \
    IMAGE_TAG="1.2 beta" \
    SCRIPT_ARGS="--env prod"
command_sent="$(cat "$SSH_MARKER.command" 2>/dev/null)"

check "remote script run succeeds" test "$status" -eq 0
check "connects as default ubuntu user" grep -qx "ubuntu@10.0.0.5" "$SSH_MARKER.connect"
check "changes into the remote workdir" contains "$command_sent" 'cd "$HOME"/app'
check "runs run.sh with args and forwarded env" \
    contains "$command_sent" 'env IMAGE_TAG=1.2\ beta bash run.sh --env prod'
check "temporary key is removed after the run" test ! -e "$(cat "$SSH_MARKER.keyfile")"
check "private key is not printed" not_contains "$output" "PRIVATE KEY"

# 2. Local workspace script streamed over stdin with a key file path
run_build \
    SSH_PRIVATE_KEY_PATH="$FIXTURE_DIR/test_key" \
    SCRIPT_SOURCE=workspace \
    LOCAL_SCRIPT_PATH=deploy/run.sh \
    USE_SUDO=true
check "workspace script run succeeds" test "$status" -eq 0
check "workspace script is sent over stdin" grep -q "echo deploying" "$SSH_MARKER.stdin"
check "sudo runs bash -s" grep -q "sudo -n env bash -s --" "$SSH_MARKER.command"

# 3. docker compose up
run_build \
    SSH_PRIVATE_KEY="$(cat "$FIXTURE_DIR/test_key")" \
    INSTRUCTION=up \
    COMPOSE_PULL=true \
    REMOTE_WORKDIR=/opt/app
command_sent="$(cat "$SSH_MARKER.command" 2>/dev/null)"
check "compose up succeeds" test "$status" -eq 0
check "compose pulls before up" contains "$command_sent" '$DC -f docker-compose.yml pull; env $DC -f docker-compose.yml up -d'

# 4. Failures
run_build SSH_PRIVATE_KEY_PATH="$FIXTURE_DIR/test_key" FAKE_REMOTE_STATUS=7
check "remote script failure is returned" test "$status" -eq 7
check "failure is saved as task status" grep -qx 7 "$SSH_MARKER.status"

run_build SSH_PRIVATE_KEY_PATH="$FIXTURE_DIR/test_key" FAKE_CONNECT_STATUS=255
check "connection failure stops the step" test "$status" -eq 1
check "nothing runs when connection fails" test ! -e "$SSH_MARKER.command"

run_build SSH_HOST= SSH_PRIVATE_KEY_PATH="$FIXTURE_DIR/test_key"
check "missing SSH_HOST fails" test "$status" -eq 1

run_build SSH_PRIVATE_KEY="not-a-key" HOME="$FIXTURE_DIR"
check "invalid key fails" test "$status" -eq 1

exit "$failed"
