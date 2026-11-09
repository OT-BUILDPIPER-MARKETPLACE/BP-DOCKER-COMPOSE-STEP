# BP-DOCKER-COMPOSE-STEP
BP bash step that SSHes from the BuildPiper server into an Ubuntu VM and runs a deploy script (e.g. `run.sh` doing `docker compose up -d`) or a docker compose command directly.

## Setup
* Generate (or reuse) a key pair for BuildPiper and add the **public** key to the target VM:
```
ssh-keygen -t ed25519 -N '' -f bp_deploy_key
ssh-copy-id -i bp_deploy_key.pub ubuntu@<vm-ip>     # or append it to ~/.ssh/authorized_keys on the VM
```
* Pass the **private** key to the step (`SSH_PRIVATE_KEY`, plain or `base64 -w0 bp_deploy_key`).
* The SSH user must be in the `docker` group on the VM (or set `USE_SUDO=true` with passwordless sudo).
* Build the docker image

```
git submodule init
git submodule update
docker build -t ot/docker-compose-step:0.1 .
```

## Variables
| Variable | Default | Description |
|---|---|---|
| SSH_HOST | - (required) | IP / hostname of the target VM |
| SSH_USER | ubuntu | SSH user |
| SSH_PORT | 22 | SSH port |
| SSH_PRIVATE_KEY | - | Private key, plain text or base64 encoded |
| SSH_PRIVATE_KEY_PATH | ~/.ssh/id_ed25519, ~/.ssh/id_rsa | Private key file mounted in the container (used when SSH_PRIVATE_KEY is empty) |
| SSH_KNOWN_HOSTS | - | known_hosts line(s) of the VM; when set, host key checking is strict |
| STRICT_HOST_KEY_CHECKING | accept-new | Used when SSH_KNOWN_HOSTS is not set |
| SSH_CONNECT_TIMEOUT | 20 | Seconds |
| INSTRUCTION | script | `script`, or a compose command: `up`, `down`, `pull`, `restart`, `ps` |
| REMOTE_WORKDIR | - | Directory on the VM to `cd` into first (`~/app` is allowed) |
| SCRIPT_SOURCE | remote | `remote`: script already on the VM. `workspace`: script from the BP workspace, streamed over SSH |
| REMOTE_SCRIPT_PATH | run.sh | Script path on the VM (relative to REMOTE_WORKDIR) |
| LOCAL_SCRIPT_PATH | run.sh | Script path relative to `$WORKSPACE/$CODEBASE_DIR` (SCRIPT_SOURCE=workspace) |
| SCRIPT_INTERPRETER | bash | Interpreter used to run the script |
| SCRIPT_ARGS | - | Arguments passed to the script as-is |
| REMOTE_ENV_VARS | - | Space-separated names of step variables to forward to the VM, e.g. `IMAGE_TAG APP_ENV` |
| COMPOSE_FILE | docker-compose.yml | Compose file used by compose instructions |
| COMPOSE_PROJECT_NAME | - | Optional `-p` value |
| COMPOSE_PULL | false | `true` pulls images before `up` |
| COMPOSE_EXTRA_ARGS | - | Extra args appended to the compose command |
| USE_SUDO | false | Run the script/compose with `sudo -n` |
| VALIDATION_FAILURE_ACTION | FAILURE | `FAILURE` fails the step when the remote command fails |

The step exits with the exit code of the remote script/compose command.

## Testing
* Run `run.sh` already present on the VM
```
docker run -it --rm \
  -e SSH_HOST=10.0.0.5 \
  -e SSH_PRIVATE_KEY="$(base64 -w0 bp_deploy_key)" \
  -e REMOTE_WORKDIR=/opt/app \
  -e REMOTE_ENV_VARS="IMAGE_TAG" -e IMAGE_TAG=1.0.3 \
  ot/docker-compose-step:0.1
```
* Run `docker compose up -d` directly
```
docker run -it --rm \
  -e SSH_HOST=10.0.0.5 -e SSH_PRIVATE_KEY="$(base64 -w0 bp_deploy_key)" \
  -e INSTRUCTION=up -e COMPOSE_PULL=true -e REMOTE_WORKDIR=/opt/app \
  ot/docker-compose-step:0.1
```
* Run a script from the code repository
```
docker run -it --rm -v $PWD:/src -e WORKSPACE=/src -e CODEBASE_DIR=code \
  -e SSH_HOST=10.0.0.5 -e SSH_PRIVATE_KEY="$(base64 -w0 bp_deploy_key)" \
  -e SCRIPT_SOURCE=workspace -e LOCAL_SCRIPT_PATH=deploy/run.sh -e REMOTE_WORKDIR=/opt/app \
  ot/docker-compose-step:0.1
```
* Unit tests (fake ssh, no VM needed)
```
bash tests/test_build_flow.sh
```
* Debug
```
docker run -it --rm --entrypoint sh ot/docker-compose-step:0.1
```
