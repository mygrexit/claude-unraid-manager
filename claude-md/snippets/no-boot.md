### Boot Configuration (not mounted)

The Unraid boot drive is **not mounted** in this container.
You cannot view or modify Unraid configuration, plugins, or templates
directly, and `host …` runs commands with `/boot` read-only, so writes there
fail with "Read-only file system".

The user can add a Path mount for `/boot` → `/host/boot` in the Docker
template: read-only to let you view it, read-write to let you change it
(each write then asks for approval).
