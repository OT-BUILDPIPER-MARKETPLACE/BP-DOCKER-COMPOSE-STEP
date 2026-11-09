#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source /opt/buildpiper/shell-functions/functions.sh
source /opt/buildpiper/shell-functions/log-functions.sh
source /opt/buildpiper/shell-functions/str-functions.sh
source "$SCRIPT_DIR/getDynamicVars.sh"

trap cleanup_ssh_auth EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

ACTIVITY_SUB_TASK_CODE="${ACTIVITY_SUB_TASK_CODE:-BP-DOCKER-COMPOSE-STEP}"
INSTRUCTION="${INSTRUCTION:-script}"
SSH_USER="${SSH_USER:-ubuntu}"
SSH_PORT="${SSH_PORT:-22}"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-20}"
STRICT_HOST_KEY_CHECKING="${STRICT_HOST_KEY_CHECKING:-accept-new}"
SCRIPT_SOURCE="${SCRIPT_SOURCE:-remote}"
REMOTE_SCRIPT_PATH="${REMOTE_SCRIPT_PATH:-run.sh}"
LOCAL_SCRIPT_PATH="${LOCAL_SCRIPT_PATH:-run.sh}"
SCRIPT_INTERPRETER="${SCRIPT_INTERPRETER:-bash}"
SCRIPT_ARGS="${SCRIPT_ARGS:-}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
COMPOSE_PULL="${COMPOSE_PULL:-false}"
COMPOSE_EXTRA_ARGS="${COMPOSE_EXTRA_ARGS:-}"
USE_SUDO="${USE_SUDO:-false}"

logInfoMessage "I'll run [$INSTRUCTION] on [${SSH_USER}@${SSH_HOST}:${SSH_PORT}]"
sleep "$SLEEP_DURATION"

validate_inputs || {
  saveTaskStatus 1 "$ACTIVITY_SUB_TASK_CODE"
  exit 1
}

setup_ssh_auth || {
  saveTaskStatus 1 "$ACTIVITY_SUB_TASK_CODE"
  exit 1
}

logInfoMessage "Checking SSH connectivity to [$SSH_HOST]"
if ! remote_ssh true < /dev/null; then
  logErrorMessage "Unable to SSH into [${SSH_USER}@${SSH_HOST}:${SSH_PORT}]. Make sure the public key is present in the VM's authorized_keys"
  saveTaskStatus 1 "$ACTIVITY_SUB_TASK_CODE"
  exit 1
fi

remote_command="$(build_remote_command)" || {
  saveTaskStatus 1 "$ACTIVITY_SUB_TASK_CODE"
  exit 1
}

logInfoMessage "Running below command on the remote VM"
logInfoMessage "$remote_command"

if [[ "$INSTRUCTION" == "script" && "$SCRIPT_SOURCE" == "workspace" ]]; then
  logInfoMessage "Streaming local script [$(local_script_path)] to the remote VM"
  remote_ssh "$remote_command" < "$(local_script_path)"
else
  remote_ssh "$remote_command" < /dev/null
fi
TASK_STATUS=$?

saveTaskStatus "$TASK_STATUS" "$ACTIVITY_SUB_TASK_CODE"
exit "$TASK_STATUS"
