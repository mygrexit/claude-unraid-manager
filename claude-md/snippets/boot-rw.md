### Boot Configuration (read-write)

The Unraid boot drive is mounted at `/host/boot` with **read-write** access.
You can modify plugins, templates, share configs, and the startup script.

Key paths:
- `/host/boot/config/go` — boot startup script
- `/host/boot/config/plugins/` — plugin configs and packages
- `/host/boot/config/plugins/dockerMan/templates-user/` — Docker container templates
- `/host/boot/config/shares/` — share definitions
- `/host/boot/config/smb-extra.conf` — custom SMB shares
- `/host/boot/config/ssh/` — SSH host keys and authorized_keys

**Always read before writing. Always show the user what will change.**
