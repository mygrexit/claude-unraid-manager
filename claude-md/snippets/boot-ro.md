### Boot Configuration (read-only)

The Unraid boot drive is mounted at `/host/boot` in **read-only** mode.
You can view plugins, templates, share configs, and the startup script,
but you cannot modify them. `host …` is not a way around this: it runs
commands with `/boot` read-only too, so writes fail with "Read-only file
system".

To allow changes (plugin installs, template edits, config modifications),
the user changes the `/host/boot` mount to Read/Write in the Docker template
and applies; the container restarts and such writes then ask for approval.
