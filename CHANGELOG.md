# Changelog

All notable changes to server-setup. Versions follow [semantic versioning](https://semver.org/); every version is a git tag (`v0.7.0`, …).

## [0.7.0] - 2026-11-25

First public release.

### Changed
- **No default mirror.** The mirror is now optional and empty by default: on a server with internet access every source is used directly. In an internal network, give your own Nexus URL during setup or with `server-setup mirror set`. Servers already set up keep the mirror saved in their config.
- A source set to `mirror` while no mirror is configured now stops with a clear message instead of building an invalid URL. A route that still pointed at a removed mirror is decided again.
- `status`, `mirror show`, `mirror test` and the setup plan say "none (direct only)" when no mirror is set.

### Added
- MIT license, this changelog, and release downloads with a `SHA256SUMS` file.

## [0.6.5] - 2026-11-24
### Fixed
- The stale-sshd check from 0.6.4 counted systemd's own socket and blocked SSH hardening on fresh Ubuntu 24.04 installs. It now looks only at sshd's own processes and runs after the restart and cleanup.

## [0.6.4] - 2026-11-24
### Security
- After the switch from `ssh.socket` to `ssh.service`, an old sshd could keep port 22 with the **pre-hardening config** (root login still worked). Leftover sshd listeners are now stopped after every sshd restart; if one survives, the change is rolled back, and `status` warns about it.

## [0.6.3] - 2026-11-24
### Fixed
- An SSH rollback now closes the ports the rejected change opened in the firewall and restores the saved ports.

## [0.6.2] - 2026-11-24
### Fixed
- A Docker restart (for example when switching to Swarm mode) left every container stopped. Containers with a restart policy and the monitoring stack are now brought back.

## [0.6.1] - 2026-11-24
### Fixed
- Fleet: a deadlock when the hub is a member of its own fleet.
- Read-only fleet views no longer rewrite the report.

## [0.6.0] - 2026-11-24
### Added
- **Under pressure:** every workload runs in `apps.slice` with memory limits and low CPU/IO weight; SSH and admin sessions get priority and guaranteed memory; systemd-oomd watches only the apps; a disk ballast file.
- `rescue` command: diagnose, freeze/thaw every app and container, free disk space, stop apps, kill. Works on a full disk.
### Fixed
- Docker's config is refreshed on a re-run.

## [0.5.2] - 2026-11-24
### Fixed
- Docker published ports: `-p 8080:80` was reachable whenever port 80 was open. Only the open host ports pass now.
- The monitoring step failed on non-hub servers.
- Container metrics: cAdvisor needs root.

## [0.5.1] - 2026-11-24
### Fixed
- SSH could end up open to everyone after it had been limited to given IPs.
- A firewall reset could run more than once and drop the Docker and Swarm rules.
- Fleet agent side effects (run lock, report rewrites); Grafana dashboard permissions.

## [0.5.0] - 2026-11-24
### Added
- **fleet:** manage many servers from one, through an SSH key forced to a single program (`brief`, `status`, `update`, `update-all`, `version`).

## [0.4.0] - 2026-11-24
### Added
- **dokploy-node:** every internet-dependent step of Dokploy's "Setup Server" done ahead of time, so a remote Dokploy panel can set up a server without internet.

## [0.3.0] - 2026-11-24
### Added
- **monitor:** Grafana Alloy agent; VictoriaMetrics, Loki, Grafana, vmalert + Alertmanager (12 alert rules) and Uptime Kuma, as `local`, `hub` (TLS + login) or `external`; `move-to` with the metric history.

## [0.2.0] - 2026-11-24
### Added
- **app:** opt-in tools (docker, node, python, go, nginx, caddy, certbot, postgresql, redis, restic, any apt package or tarball), sandboxed app services, restic backups.

## [0.1.0] - 2026-11-24
### Added
- **base:** download sources tried directly first with a mirror fallback; updates, admin and deploy users, key-only SSH with a 10-minute automatic rollback, ufw + fail2ban, sysctl/AppArmor hardening, long-uptime tuning (limits, BBR, swap + zswap, journal caps, security updates with needrestart), chrony.

[0.7.0]: https://github.com/mohammadreza-zr/server-setup/releases/tag/v0.7.0
[0.6.5]: https://github.com/mohammadreza-zr/server-setup/releases/tag/v0.6.5
