### Boot Configuration (read-only)

The Unraid boot drive is mounted at `/host/boot` in **read-only** mode.
You can view plugins, templates, share configs, and the startup script,
but you cannot modify them.

To allow changes (plugin installs, template edits, config modifications),
the user must change the `/host/boot` mount to `rw` in the Docker template
and restart this container.
