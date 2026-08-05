# Service enablement

Both packages enable the API endpoint and the netavark DHCP proxy on install. This is a deliberate deviation from Debian's own podman
packaging, which enables neither.

|                                      | Debian                                    | Alpine                                                   |
|--------------------------------------|-------------------------------------------|----------------------------------------------------------|
| API endpoint                         | `podman.socket` (socket-activated)        | `/etc/init.d/podman` running `podman system service`     |
| DHCP proxy                           | `netavark-dhcp-proxy.socket` + `.service` | `/etc/init.d/netavark-dhcp-proxy`                        |
| Restore rules after firewalld reload | `netavark-firewalld-reload.service`       | `/etc/init.d/netavark-firewalld-reload`                  |
| Restore rules after nftables reload  | `netavark-nftables-reload.service`        | `/etc/init.d/netavark-nftables-reload` (netlink watcher) |

Left disabled on Debian: `podman.service` (socket-activated, so enabling it directly would run the API server permanently),
`podman-auto-update.service`/`.timer` (would pull and restart containers on a timer),
`podman-restart.service`, `podman-clean-transient.service`, `podman-kube@.service`.

## The reload services

The reload services matter more than they look. `nftables` is a hard dependency, and reloading it flushes netavark's rules; without
something to re-apply them, container networking silently stops working. Despite the symmetric names the two are different shapes:

- `netavark-nftables-reload.service` is `Type=oneshot`, running `netavark firewall-reload` once. systemd couples it to nftables with
  `PartOf=`/`WantedBy=nftables.service`.
- `netavark-firewalld-reload.service` is `Type=simple`, running `netavark firewalld-reload` — a **long-running zbus listener** on
  firewalld's `org.fedoraproject.FirewallD1` `Reloaded` signal.

Both are enabled but not *started* at install: the wants symlink is what couples them to nftables/firewalld, which is upstream's intent.
Starting the firewalld listener on a host without firewalld would just fail immediately.

## How each ports to OpenRC

The OpenRC services are ours (Alpine's netavark aport ships no DHCP proxy service at all) and are added to the default runlevel by a melange
`post-install` scriptlet, which no-ops cleanly when `rc-update` is absent — as it is inside a container image build. Because OpenRC has no
socket activation, both run as supervised long-lived daemons; the DHCP proxy therefore omits upstream's `-a 30` activity timeout, which only
makes sense when something can re-activate an exited daemon.

The **firewalld** listener ports directly: its trigger is a D-Bus signal, which owes nothing to systemd. It runs as a supervised daemon,
enabled by the post-install scriptlet *only when firewalld is actually installed* — mirroring
`WantedBy=firewalld.service`, and avoiding a supervisor that endlessly restarts a process with no firewalld on the bus to listen to.

The **nftables** one has no direct equivalent. nf_tables is a kernel subsystem: it broadcasts ruleset changes over **netlink**
(`NETLINK_NETFILTER`), not D-Bus, and netavark ships no netlink watcher — only the oneshot `firewall-reload`. systemd bridges that gap
declaratively with `PartOf=`/`WantedBy=nftables.service`; OpenRC has no way to express "run this after another service reloads".

### The nftables monitor

So Alpine gets `/usr/libexec/podman/netavark-nftables-monitor`, a small POSIX-sh watcher supervised by
`/etc/init.d/netavark-nftables-reload`. What makes it tractable is that `nft monitor tables` filters kernel-side:
ordinary container churn adds and removes rules and chains *inside* netavark's table and produces no output whatsoever, while
`nft flush ruleset` — what an nftables reload does — emits exactly `delete table inet netavark`. That is an unambiguous single-event
trigger, verified empirically rather than assumed. nft line-buffers the stream through a pipe, so no `stdbuf` is needed, and `jq` is not
required.

Because it runs as root, it is guarded three ways so it can never spin: a debounce that collapses a burst from one flush into one reload, a
re-check that skips if something else already rebuilt the table, and a hard cooldown floor. `netavark
firewall-reload` is idempotent, so a spurious run on a host with no container networks is a no-op. Knobs live in
`/etc/conf.d/netavark-nftables-reload`.

The acceptance suite asserts both directions — that container churn does *not* trigger a reload, and that a real `nft
flush ruleset` does restore the rules.

This is a stopgap. The right home for it is netavark itself, which already has the netlink crates and a
`firewalld-reload` listener that this would sit beside; an upstream `nftables-reload` subcommand would serve every non-systemd distro rather
than just this package.

## Related

- [Rootless storage on Alpine](rootless-storage.md) — the other Alpine-only fix the package ships
- [Acceptance suite](acceptance.md) — the behavioural tests covering both reload directions
