### Docker Access

Docker socket is mounted. You can manage all containers on this server:
`docker ps`, `docker logs`, `docker inspect`, `docker stop/start/restart`,
`docker pull`, `docker create`, `docker rm`, `docker exec`.

Host-level commands run through the `host` wrapper:
```
host zpool status
host sh -c 'ls /boot/config/plugins/*.plg'
```
