### Boot Configuration (not mounted)

The Unraid boot drive is **not mounted** in this container.
You cannot view or modify Unraid configuration, plugins, or templates directly.

The user can add a Path mount for `/boot` → `/host/boot` (read-only or read-write)
in the Docker template to enable this.
