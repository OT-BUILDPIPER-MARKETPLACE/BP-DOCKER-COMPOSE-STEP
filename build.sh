#!/bin/bash

###############################################
# 🔹 Export Vars (Make them available Globally)
###############################################
export SSH_USERNAME="${SSH_USERNAME}"
export SSH_IP="${SSH_IP}"
export SSH_PORT="${SSH_PORT:-22}"
export COMPOSE_FILE="${COMPOSE_FILE}"
export SERVICE="${SERVICE}"
export NEW_IMAGE="${NEW_IMAGE}"

###############################################
# 🔹 Mandatory Variables Check
###############################################
if [ -z "$SSH_USERNAME" ]; then echo "❌ ERROR: SSH_USERNAME is not set"; exit 1; fi
if [ -z "$SSH_IP" ]; then echo "❌ ERROR: SSH_IP is not set"; exit 1; fi
if [ -z "$SSH_PORT" ]; then echo "❌ ERROR: SSH_PORT is not set"; exit 1; fi
if [ -z "$COMPOSE_FILE" ]; then echo "❌ ERROR: COMPOSE_FILE is not set"; exit 1; fi
if [ -z "$SERVICE" ]; then echo "❌ ERROR: SERVICE is not set"; exit 1; fi
if [ -z "$NEW_IMAGE" ]; then echo "❌ ERROR: NEW_IMAGE is not set"; exit 1; fi

###############################################
# 🔹 SSH Key
###############################################
KEY_FILE="key.pem"
chmod 400 $KEY_FILE

###############################################
# 🔹 SSH Command Wrapper
###############################################
SSH_CMD="ssh -i $KEY_FILE \
  -p $SSH_PORT \
  -o UserKnownHostsFile=/dev/null \
  -o StrictHostKeyChecking=no \
  $SSH_USERNAME@$SSH_IP"

###############################################
# 🔹 Handle Multiple Services (REMOTE EDIT)
###############################################
IFS=',' read -ra SERVICE_LIST <<< "$SERVICE"

for svc in "${SERVICE_LIST[@]}"; do
echo "🚀 Updating image for service: $svc on remote server"

$SSH_CMD "sed -i \"/^[[:space:]]*$svc:/,/image:/ s|image:.*|image: $NEW_IMAGE|\" $COMPOSE_FILE"
done

###############################################
# 🔹 Restart Services
###############################################
echo "🔄 Restarting services on remote server..."

$SSH_CMD "docker compose -f $COMPOSE_FILE pull"
$SSH_CMD "docker compose -f $COMPOSE_FILE up -d"

echo "✅ Deployment completed successfully!"
