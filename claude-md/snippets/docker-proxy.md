### Docker Access (through the socket proxy)

This container does not have the Docker socket. It reaches Docker through a
filtering socket proxy (`DOCKER_HOST`), a separate container whose allowlist
is enforced outside this one and cannot be changed from here.

Allowed:
- `docker ps`, `docker images`, `docker version`, `docker info`, `docker events`
- `docker inspect <container>`, `docker image inspect <image>`,
  `docker stats --no-stream`, `docker top <container>`
- `docker logs` (read logs with `logs <container>`)
- `docker start`, `docker stop`, `docker restart <container>`

Everything else is refused with `Forbidden` or `Method Not Allowed`:
`docker exec`, `run`, `create`, `rm`, `pull`, `build`, `cp`, `export`,
`kill`, `update`, volumes, networks, prune. A refusal is the configured
boundary, not a fault. Do not look for another route (a raw socket, another
container's socket, the Unraid API, SSH, a script). Tell the user what you
wanted to do and why, and let them do it from the Unraid GUI.

`docker inspect` output includes each container's environment variables,
which often hold passwords and API keys. Ask for the fields you need with
`--format`, and never repeat a secret value.

`host` is not available in this mode: it starts a privileged helper
container, which the proxy refuses. Storage, VM, plugin and network details
from the host are therefore missing below.
