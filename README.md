# server-setup

Turn a fresh **Ubuntu or Debian** server into a **hardened server that runs for years**: production backends, Dokploy nodes and monitoring hubs. It works with normal internet access or inside an **internal network** where only a mirror is reachable, and it keeps managing the server afterwards.

> **Status: phase 2 of 5.** The *base* role (hardening, users, SSH, firewall, long-uptime tuning, download sources) and the *app* role (opt-in tools, app services, backups) are implemented. *monitor*, *dokploy-node* and *fleet* come next.

| | |
|---|---|
| OS | Ubuntu 22.04 / 24.04 / 26.04 LTS, Debian 12 / 13 (amd64, arm64) |
| Default | **nothing installed but hardening.** Everything else is opt-in |
| Mirror | a Nexus repository manager (default `https://nexus.mrzdev.ir`), used only where needed |

## Quick start

Copy `server-setup.sh` to the server and run it as root from that file (it is interactive):

```bash
sudo bash server-setup.sh
```

It asks every question first and shows the plan, then runs every step. A failed step is reported and the rest still run. It is safe to re-run. Afterwards it installs itself as `server-setup`:

```bash
sudo server-setup status
sudo server-setup help
```

## Download sources: direct first, mirror only where needed

There is no "internal mode" switch. Each source is checked on its own:

1. `apt` is tried with the server's **own OS repositories**. Third-party repos don't count, so a broken PPA can't force the mirror. If they answer, they are kept. If not, apt switches to the mirror's repositories, the other repos are set aside (originals are kept in `/etc/server-setup/backup/apt-original`), and the setup continues.
2. Time sync (NTP) uses the public pools if they answer; otherwise it uses the internal NTP servers you give.
3. Later roles do the same for Docker Hub, ghcr.io, Docker's/Grafana's/NodeSource's apt repos, npm, PyPI, Go and GitHub downloads.

```bash
sudo server-setup mirror test      # each source: does it work directly, and on the mirror?
sudo server-setup mirror set       # URL, login, repository names, NTP servers, per-source mode
sudo server-setup mirror recheck   # decide again (e.g. the server got or lost internet)
```

Each source can also be forced: `auto` (the default: direct, then mirror), `direct`, `mirror` or `none`.

Default Nexus repository names (change them with `mirror set`):

| Source | Repository |
|---|---|
| Ubuntu | `ubuntu`, `ubuntu-security` (arm64: `ubuntu-ports`) |
| Debian | `debian`, `debian-security` |
| Docker / Grafana / NodeSource apt | `docker-apt`, `grafana-apt`, `nodesource-apt` |
| Docker images | the registry on the mirror host |
| npm / PyPI / Go modules | `npm-proxy`, `pypi-proxy`, `go-proxy` |
| Go toolchain / GitHub downloads | `go-dl` (raw proxy of `https://dl.google.com/`), `github-proxy` (raw proxy of `https://github.com/`) |

The apt proxies point at the upstream's root: `docker-apt` → `https://download.docker.com/`, `grafana-apt` → `https://apt.grafana.com/`, `nodesource-apt` → `https://deb.nodesource.com/`. Files are then requested by the same path as upstream.

**Mirror login and language tools:** the login is written only to root-only places (apt `auth.conf.d`, `docker login`). npm/pip/Go settings are readable by every user, so they get the mirror URL but **not** the password. Allow anonymous read on the npm/PyPI/Go proxies, or let each app user log in. Docker's `registry-mirrors` can't send a login either. If the Docker proxy needs one, pull as `<mirror>/library/<image>`, or allow anonymous pull.

A mirror login is stored root-only (`/etc/server-setup/secrets`, apt's `auth.conf.d`) and never passed on a command line.

## What the base role does

- **Updates:** finishes any interrupted upgrade, upgrades everything, installs a small base set (all from the OS repos), and removes leftovers.
- **Users:** one admin (sudo with a password, SSH key) and an optional **deploy** user (key only, no sudo, for CI/CD). sudo re-asks after 5 minutes and logs every use to `/var/log/sudo.log`.
- **SSH:** key-only, no root login, only the `ssh-users` group, several ports possible. Only *local* forwarding is allowed (`ssh -L` to a database): no remote forwards, no agent forwarding, no X11. Changes **roll back automatically** after 10 minutes unless the admin logs in through the new config.
- **Firewall (ufw):** everything inbound blocked except SSH (optionally only from given IPs) and the ports you open. fail2ban guards SSH and works offline.
- **Hardening:** sysctl network/kernel hardening (redirects, source routing, ptrace, BPF, kernel pointers, protected links), no core dumps, AppArmor on, empty login banner. Optional: auditd (who changed accounts, sudo, SSH, firewall) and a Lynis audit report.
- **Long uptime:**
  - Raised file and connection limits, bigger network queues, BBR when the kernel has it, conntrack sized for busy servers.
  - Swap file plus zswap (compressed swap in RAM).
  - sshd protected from the OOM killer and restarted if it ever dies.
  - Weekly fstrim.
  - The journal is capped (default 1 GB, at most 3 months, compressed), and text logs rotate before 500 MB.
  - Security updates install daily, and services that use updated libraries restart by themselves (needrestart).
  - **No automatic reboot** by default: `status` tells you when one is needed and why. Ubuntu Pro Livepatch (kernel fixes without a reboot) is optional where Canonical is reachable.
- **Time:** chrony, with public pools or your internal NTP servers.

## Tools (app role): opt-in

```bash
sudo server-setup tools list
sudo server-setup tools install docker node --version 24
sudo server-setup tools install go --version 1.25.4      # needed when go.dev isn't reachable
sudo server-setup tools install apt:jq url:https://github.com/org/tool/releases/download/v1.2.3/tool_linux_amd64.tar.gz --sha256 <hash>
```

| Tool | From |
|---|---|
| `docker` | Docker's apt repo: CE, compose, buildx. Container logs capped (20 MB × 5); `live-restore` (off in Swarm) |
| `node` | NodeSource apt repo (`--version 22|24…`); npm registry direct or mirror |
| `python` | OS python3 + venv + pip + pipx, plus `uv` for everyone (from PyPI, direct or mirror) |
| `go` | the official tarball, **checksum-verified**, in `/usr/local/go`; GOPROXY direct or mirror |
| `nginx`, `caddy`, `certbot`, `postgresql`, `postgresql-client`, `redis`, `restic` | the OS repositories |
| `apt:<pkg>` | any OS package |
| `url:<tarball>` | unpacked into `--prefix` (default `/opt/<name>`); github.com URLs follow the GitHub source's route; `--sha256` to verify |

**Docker and the firewall:** Docker publishes container ports with its own iptables rules, past ufw. server-setup adds rules to Docker's `DOCKER-USER` chain. Containers can talk out and to each other, but from outside only the ports opened with `server-setup firewall allow` reach a container. Everything else is dropped and logged as `[UFW DOCKER BLOCK]`. Use the container's port (the one after the `:` in `-p 8080:80`).

**App services:** `server-setup apps add api --exec "/srv/api/bin/api --port 8080" --port 8080` creates:
- a system user `api`
- `/srv/api`
- settings in `/etc/server-setup/apps/api.env`
- a systemd service `app-api` in a sandbox: read-only system, writes only its directory, no privilege escalation, restarts forever, logs in the journal.

**Backups:** `server-setup backup init` sets up daily restic backups to a local disk, SFTP or S3/MinIO, with a retention policy and a 1% data check after each run. The restic password goes to the credentials file. Keep it outside the server too.

## Commands

```text
setup                        First-time setup (interactive). Safe to re-run.
status                       System, reboot needed, sources, users, SSH, firewall, time, logs.
report                       Rewrite /root/server-setup-report.txt.
update [--all]               Security updates now (--all: everything), restart what needs it,
                             say whether a reboot is needed.
users list|add|remove|key|password <name> [--admin|--deploy]
firewall list | allow <port>[/udp]... | deny <port>... | ssh-from [<cidr>...]
mirror show|test|set|recheck
tools list | install <tool>... [--version V] [--prefix DIR] [--sha256 H] | remove <tool>...
apps list | add <name> --exec CMD [--port N] | remove <name>
backup init|run|status|list
ssh [--ports "22 9011"]      Re-apply SSH hardening / change ports (auto-rollback).
confirm                      Keep a pending SSH change now.
```

## Files

| | |
|---|---|
| Command | `/usr/local/sbin/server-setup` |
| Configuration | `/etc/server-setup/config` (root only) |
| Secrets (mirror login) | `/etc/server-setup/secrets/` (root only) |
| Log (no secrets) | `/var/log/server-setup.log` |
| Report | `/root/server-setup-report.txt` |
| Generated passwords / keys | `/root/server-setup-credentials/`. Hand them over, then delete them |

## Roadmap

1. ~~Framework, download sources, base role~~ ✅
2. ~~**app**: opt-in tools catalog, app services, restic backups~~ ✅
3. **monitor**: Grafana Alloy agent on every server. The stack (VictoriaMetrics, Loki, Grafana, Alertmanager, Uptime Kuma) can run on the same server or on a hub, or the agent can feed one you already have. `monitor move-to <hub>` when you outgrow one server.
4. **dokploy-node**: prepares a server to be managed by a remote Dokploy panel, with all of Dokploy's setup steps done ahead of time so "Setup Server" works without internet.
5. **fleet**: manage many servers from the hub.
