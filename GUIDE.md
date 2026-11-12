# BP-DOCKER-COMPOSE-STEP — Complete Guide

This step runs inside a Docker container on your BuildPiper server.
It SSHes into a remote VM and either executes a script or runs a `docker compose` command directly — all driven by environment variables.

---

## Table of Contents

1. [How it works](#1-how-it-works)
2. [Prerequisites](#2-prerequisites)
3. [SSH Authentication Setup](#3-ssh-authentication-setup)
4. [Environment Variables Reference](#4-environment-variables-reference)
5. [Use Cases](#5-use-cases)
   - [Run a remote script](#51-run-a-script-already-on-the-vm)
   - [Stream a workspace script](#52-stream-a-script-from-your-workspace)
   - [Docker Compose up](#53-docker-compose-up)
   - [Docker Compose down / restart / ps](#54-docker-compose-down--restart--ps)
6. [BuildPiper Platform Configuration](#6-buildpiper-platform-configuration)
7. [Running Locally with Docker](#7-running-locally-with-docker)
8. [Expected Log Output](#8-expected-log-output)
9. [Troubleshooting](#9-troubleshooting)

---

## 1. How it works

```
BuildPiper Server
  └── Docker container (BP-DOCKER-COMPOSE-STEP image)
        │
        │  SSH (using private key from env var or mounted file)
        ▼
  Remote VM (EC2 / any Ubuntu VM)
        └── Runs script or docker compose command
```

Execution flow inside the container:

1. Reads and validates all input environment variables
2. Writes the SSH private key to a secure temp file (`/tmp/bp-ssh-auth.XXXXXX/`)
3. Verifies SSH connectivity with a no-op test connection
4. Builds the remote shell command
5. SSHes into the VM and runs the command
6. Reports success or failure, then deletes the temp key file

---

## 2. Prerequisites

### On the remote VM

- SSH server running on port 22 (or custom port)
- The BuildPiper server's **public key** present in `~/.ssh/authorized_keys`
- For `docker compose` instructions: Docker and docker compose plugin installed
- For `USE_SUDO=true`: the SSH user must have passwordless sudo configured

### On the BuildPiper server

- Docker installed and running
- The step image available: `registry.buildpiper.in/impl/rems-event-update:v55-compose`
- SSH key pair available (either mounted via `SSH_FOLDER` or passed as `SSH_PRIVATE_KEY`)

---

## 3. SSH Authentication Setup

This is a one-time setup. There are two authentication approaches:

### Approach A — SSH_PRIVATE_KEY_PATH (recommended for BuildPiper)

The BuildPiper server already has SSH keys at `~/.ssh/`. The `SSH_FOLDER` mount makes them available inside the container at `/home/buildpiper/.ssh/`.

**Step 1 — Get the BuildPiper server's public key:**
```bash
cat ~/.ssh/id_ed25519.pub
```

**Step 2 — Add it to the remote VM's authorized_keys (do this once):**
```bash
# On the remote VM
echo "ssh-ed25519 AAAA...your-key..." >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

**Step 3 — Set this env var in the step:**
```
SSH_PRIVATE_KEY_PATH = /home/buildpiper/.ssh/id_ed25519
```

No base64 encoding needed. The SSH_FOLDER mount handles everything.

---

### Approach B — SSH_PRIVATE_KEY (base64 encoded)

Use this when you want to pass the key directly as an environment variable (useful for external VMs or when the key is stored in a secret manager).

**Step 1 — Generate a dedicated key pair:**
```bash
ssh-keygen -t ed25519 -N '' -f bp_deploy_key
```

**Step 2 — Add the public key to the remote VM:**
```bash
cat bp_deploy_key.pub
# Copy output and on the remote VM run:
echo "ssh-ed25519 AAAA..." >> ~/.ssh/authorized_keys
```

**Step 3 — Base64 encode the private key:**
```bash
cat bp_deploy_key | base64 | tr -d '\n'
```

**Step 4 — Store that value as a Secret in BuildPiper and pass it as:**
```
SSH_PRIVATE_KEY = <base64-encoded-value>   (type: Secret)
```

---

## 4. Environment Variables Reference

### Required

| Variable | Description |
|---|---|
| `SSH_HOST` | IP or hostname of the remote VM |

### SSH Authentication

| Variable | Default | Description |
|---|---|---|
| `SSH_USER` | `ubuntu` | SSH username on the remote VM |
| `SSH_PORT` | `22` | SSH port |
| `SSH_PRIVATE_KEY` | - | Private key — plain PEM text or base64 encoded. Store as **Secret** |
| `SSH_PRIVATE_KEY_PATH` | `~/.ssh/id_ed25519` or `~/.ssh/id_rsa` | Path to key file inside the container (used when `SSH_PRIVATE_KEY` is empty) |
| `SSH_KNOWN_HOSTS` | - | Known hosts entry for strict host key checking. If not set, host is trusted on first use |
| `STRICT_HOST_KEY_CHECKING` | `accept-new` | Used when `SSH_KNOWN_HOSTS` is not set |
| `SSH_CONNECT_TIMEOUT` | `20` | SSH connection timeout in seconds |

### Execution

| Variable | Default | Description |
|---|---|---|
| `INSTRUCTION` | `script` | What to run: `script`, `up`, `down`, `pull`, `restart`, `ps` |
| `REMOTE_WORKDIR` | - | Directory on the VM to `cd` into before running. Supports `~/path` |
| `USE_SUDO` | `false` | Run the command with `sudo -n` on the remote VM |
| `REMOTE_ENV_VARS` | - | Space-separated list of variable names to forward to the VM e.g. `IMAGE_TAG APP_ENV` |

### Script mode (`INSTRUCTION=script`)

| Variable | Default | Description |
|---|---|---|
| `SCRIPT_SOURCE` | `remote` | `remote`: script already exists on the VM. `workspace`: script is streamed from the BuildPiper workspace over SSH |
| `REMOTE_SCRIPT_PATH` | `run.sh` | Path to script on the VM (relative to `REMOTE_WORKDIR`) |
| `LOCAL_SCRIPT_PATH` | `run.sh` | Path to script relative to `$WORKSPACE/$CODEBASE_DIR` (only for `SCRIPT_SOURCE=workspace`) |
| `SCRIPT_INTERPRETER` | `bash` | Interpreter used to run the script |
| `SCRIPT_ARGS` | - | Arguments passed to the script |

### Compose mode (`INSTRUCTION=up/down/pull/restart/ps`)

| Variable | Default | Description |
|---|---|---|
| `COMPOSE_FILE` | `docker-compose.yml` | Compose file name on the remote VM |
| `COMPOSE_PROJECT_NAME` | - | Optional compose project name (`-p` flag) |
| `COMPOSE_PULL` | `false` | Pull latest images before `up` |
| `COMPOSE_EXTRA_ARGS` | - | Extra arguments appended to the compose command |

### Platform

| Variable | Default | Description |
|---|---|---|
| `VALIDATION_FAILURE_ACTION` | `FAILURE` | `FAILURE` fails the pipeline step on error. Any other value logs a warning but continues |
| `SLEEP_DURATION` | `5s` | Wait time before execution starts |

---

## 5. Use Cases

### 5.1 Run a script already on the VM

The script (`ex.sh`) already exists on the remote VM at `/home/ubuntu/compose-test/`.

```bash
docker run -it --rm \
  -e SSH_HOST=15.206.146.144 \
  -e SSH_USER=ubuntu \
  -e SSH_PRIVATE_KEY_PATH=/home/buildpiper/.ssh/id_ed25519 \
  -e REMOTE_WORKDIR=/home/ubuntu/compose-test \
  -e REMOTE_SCRIPT_PATH=ex.sh \
  registry.buildpiper.in/impl/rems-event-update:v55-compose
```

With environment variable forwarding:
```bash
docker run -it --rm \
  -e SSH_HOST=15.206.146.144 \
  -e SSH_USER=ubuntu \
  -e SSH_PRIVATE_KEY_PATH=/home/buildpiper/.ssh/id_ed25519 \
  -e REMOTE_WORKDIR=/home/ubuntu/app \
  -e REMOTE_SCRIPT_PATH=deploy.sh \
  -e REMOTE_ENV_VARS="IMAGE_TAG APP_ENV" \
  -e IMAGE_TAG=1.0.5 \
  -e APP_ENV=production \
  registry.buildpiper.in/impl/rems-event-update:v55-compose
```

---

### 5.2 Stream a script from your workspace

The script lives in your code repository. It is streamed from the BuildPiper workspace to the VM over SSH stdin — the script does not need to exist on the VM.

```bash
docker run -it --rm \
  -v /path/to/workspace:/src \
  -e WORKSPACE=/src \
  -e CODEBASE_DIR=. \
  -e SSH_HOST=15.206.146.144 \
  -e SSH_USER=ubuntu \
  -e SSH_PRIVATE_KEY_PATH=/home/buildpiper/.ssh/id_ed25519 \
  -e SCRIPT_SOURCE=workspace \
  -e LOCAL_SCRIPT_PATH=scripts/deploy.sh \
  -e REMOTE_WORKDIR=/home/ubuntu/app \
  registry.buildpiper.in/impl/rems-event-update:v55-compose
```

---

### 5.3 Docker Compose up

Runs `docker compose up -d` on the remote VM. Optionally pulls latest images first.

```bash
docker run -it --rm \
  -e SSH_HOST=15.206.146.144 \
  -e SSH_USER=ubuntu \
  -e SSH_PRIVATE_KEY_PATH=/home/buildpiper/.ssh/id_ed25519 \
  -e INSTRUCTION=up \
  -e COMPOSE_PULL=true \
  -e REMOTE_WORKDIR=/home/ubuntu/compose-test \
  -e COMPOSE_FILE=docker-compose.yml \
  registry.buildpiper.in/impl/rems-event-update:v55-compose
```

---

### 5.4 Docker Compose down / restart / ps

Change `INSTRUCTION` to any supported compose command:

```bash
# Bring services down
-e INSTRUCTION=down

# Restart services
-e INSTRUCTION=restart

# Check running services
-e INSTRUCTION=ps
```

---

## 6. BuildPiper Platform Configuration

### Runtime tab

| Field | Value |
|---|---|
| Step Type | Dockerize |
| Docker Image With Tag | `registry.buildpiper.in/impl/rems-event-update:v55-compose` |
| Entry Commands | *(leave empty — image has its own entrypoint)* |

---

### Mounts tab

These mounts should already be present. Do not remove them:

| Mount Name | Source | Destination |
|---|---|---|
| Workspace Directory | `$WORKSPACE` | `/bp/workspace` |
| Docker Socket file | `/var/run/docker.sock` | `/var/run/docker.sock` |
| SSH_FOLDER | `$HOME/.ssh` | `/home/buildpiper/.ssh` |
| AWS_FOLDER | `$HOME/.aws` | `/home/buildpiper/.aws` |
| Docker daemon file | `/etc/docker` | `/etc/docker` |
| Docker Config Folder | `$HOME/.docker` | `/home/buildpiper/.docker` |

The `SSH_FOLDER` mount is what makes `SSH_PRIVATE_KEY_PATH` work — it makes the BuildPiper server's SSH keys available inside the container.

---

### Inputs tab

Add these environment variables:

| Variable Name | Default Value | Type | Required | Overridable |
|---|---|---|---|---|
| `SSH_HOST` | `15.206.146.144` | Text | Yes | Yes |
| `SSH_USER` | `ubuntu` | Text | Yes | Yes |
| `SSH_PRIVATE_KEY` | *(base64 value)* | **Secret** | No* | Yes |
| `SSH_PRIVATE_KEY_PATH` | `/home/buildpiper/.ssh/id_ed25519` | Text | No* | Yes |
| `REMOTE_WORKDIR` | `/home/ubuntu/compose-test` | Text | Yes | Yes |
| `REMOTE_SCRIPT_PATH` | `ex.sh` | Text | Yes | Yes |

*Use either `SSH_PRIVATE_KEY` or `SSH_PRIVATE_KEY_PATH` — not both.

---

### Outputs tab

Leave empty — this step does not produce output variables.

---

## 7. Running Locally with Docker

### Build the image

```bash
cd BP-DOCKER-COMPOSE-STEP
git submodule init && git submodule update
docker build -t ot/docker-compose-step:test .
```

### Run unit tests (no VM needed)

```bash
bash tests/test_build_flow.sh
```

All 17 tests should show `PASS`.

### Run against a local VM

```bash
# Generate a key pair
ssh-keygen -t ed25519 -N '' -f bp_deploy_key

# Add public key to local machine
cat bp_deploy_key.pub >> ~/.ssh/authorized_keys

# Run the step
docker run -it --rm \
  -e SSH_HOST=$(hostname -I | awk '{print $1}') \
  -e SSH_USER=$USER \
  -e SSH_PRIVATE_KEY="$(base64 -w0 bp_deploy_key)" \
  -e REMOTE_WORKDIR=~/app \
  -e REMOTE_SCRIPT_PATH=run.sh \
  ot/docker-compose-step:test
```

### Debug inside the container

```bash
docker run -it --rm --entrypoint sh \
  registry.buildpiper.in/impl/rems-event-update:v55-compose
```

---

## 8. Expected Log Output

A successful run looks like this:

```
[INFO] ========================================
[INFO] BP-DOCKER-COMPOSE-STEP starting
[INFO] ========================================
[INFO] Host       : ubuntu@15.206.146.144:22
[INFO] Instruction: script
[INFO] Script     : ex.sh (remote)
[INFO] Work Dir   : /home/ubuntu/compose-test
[INFO] ========================================
[WARNING] SSH_KNOWN_HOSTS is not set, host key will be trusted on first use
[INFO] SSH auth   : using key file [/home/buildpiper/.ssh/id_ed25519]
[INFO] Checking SSH connectivity to [15.206.146.144]...
[INFO] SSH connectivity to [15.206.146.144]... OK
[INFO] ----------------------------------------
[INFO] Executing [script] on remote VM [ubuntu@15.206.146.144]
[INFO] ----------------------------------------
Running ex.sh on ip-172-31-14-44
nginx installed successfully!
nginx version: nginx/1.24.0 (Ubuntu)
[INFO] ----------------------------------------
[INFO] Remote execution completed in [11s]
[INFO] ========================================
[INFO] Congratulations BP-DOCKER-COMPOSE-STEP succeeded!!!
```

---

## 9. Troubleshooting

| Error | Cause | Fix |
|---|---|---|
| `SSH_HOST is not available` | `SSH_HOST` env var not set | Add `SSH_HOST` to the step inputs |
| `Connection refused` on port 22 | SSH server not running on the VM | Run `sudo systemctl start ssh` on the VM |
| `Permission denied (publickey)` | Public key not in VM's `authorized_keys` | Add the BuildPiper server's public key to `~/.ssh/authorized_keys` on the VM |
| `SSH private key is invalid or protected by a passphrase` | Wrong key or passphrase-protected key | Use a key with no passphrase. Regenerate with `ssh-keygen -t ed25519 -N ''` |
| `SSH_PRIVATE_KEY is neither a private key nor valid base64` | Incomplete or malformed base64 value | Re-run `cat key \| base64 \| tr -d '\n'` and paste the full single-line output |
| `No such file or directory` for script | Wrong `REMOTE_SCRIPT_PATH` or `REMOTE_WORKDIR` | SSH into the VM and verify the path exists |
| `sudo: a password is required` | `USE_SUDO=true` but sudo requires a password | Configure passwordless sudo on the VM for the SSH user |
| `docker: command not found` on VM | Docker not installed on the VM | Install Docker on the VM and add the user to the `docker` group |
| Compose file not found | Wrong `COMPOSE_FILE` or `REMOTE_WORKDIR` | Verify `docker-compose.yml` exists at `REMOTE_WORKDIR` on the VM |
