# server-setup

Turn a fresh **Ubuntu or Debian** server into a **hardened server that runs for years**: production backends, Dokploy nodes and monitoring hubs. It works with normal internet access or inside an **internal network** where only a mirror is reachable, and it keeps managing the server afterwards.

> **Status: 0.6.3.** All 5 roles are implemented, plus "under pressure" management. Tested on a real Ubuntu 24.04 server: base, app, monitor, and the CPU / memory / disk-full stress tests. See [Testing status](#testing-status).

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

## Under pressure: you can always get in and fix it

A server that runs for years will one day have a full disk, a memory leak or a runaway process. server-setup makes sure the admin can still log in and act:

- **Every workload runs in `apps.slice`**: app services and every Docker container (Docker's `cgroup-parent`). Apps are slowed down above *RAM − 2 × reserve* and can never take the last *reserve* (5% of RAM, 256 MB–1 GB).
- **SSH and admin sessions** get 10× the CPU and disk-I/O priority of the apps, and guaranteed memory. The kernel's OOM killer never picks sshd.
- **The monitoring stack** runs in its own `monitoring.slice`, so it keeps reporting while the apps misbehave.
- **systemd-oomd** watches only `apps.slice`. If apps thrash (80% memory pressure for 20 s) or swap is 90% full, the heaviest app is ended. SSH, admin sessions and system services are never touched.
- **A ballast file** (2% of the disk, 256 MB–2 GB) holds space in reserve. `rescue free-space` frees it at once when the disk fills.

```bash
sudo server-setup rescue              # what is eating CPU, RAM, disk; pressure; recent OOM kills
sudo server-setup rescue freeze       # PAUSE every app and container at once (nothing is killed)
sudo server-setup rescue thaw         # resume them
sudo server-setup rescue free-space   # ballast + journal + apt cache + dangling Docker images + old /tmp files
sudo server-setup rescue stop-apps    # stop every app service and container
sudo server-setup rescue kill <pid>
sudo server-setup rescue restore      # put the ballast back when it's fixed
```

`rescue` never waits for a lock and writes nothing, so it works on a full disk and while another run is stuck. It raises its own CPU and I/O priority.

**Measured on a 2-CPU / 4 GB test server.** An admin SSH login that runs `sudo` + a command:

| Situation (caused by an app in `apps.slice`) | Login time |
|---|---|
| idle | 2.0 s |
| 8 CPU hogs on 2 CPUs (CPU pressure 85%) | 2.0 s |
| 5 GB of memory wanted on 3.9 GB RAM (memory pressure up to 90%, swap 3.4 GB) | 2.1–2.9 s |
| disk 100% full (including root's reserve) | 4.5 s, then 2.2 s |

`rescue freeze` took the CPU hogs to 0% instantly. SSH, journald, Docker and the monitoring stack stayed up in every test.

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

## Monitoring: from one server to many

Every monitored server runs **Grafana Alloy**, one agent that collects:
- host metrics, including the state of every systemd service
- container metrics and container logs
- the system journal
- server-setup's own facts: reboot needed, security updates waiting

It **pushes** everything, so it works through NAT and firewalls. The **stack** is VictoriaMetrics, Loki, Grafana with a ready dashboard, vmalert + Alertmanager with 12 alert rules, and Uptime Kuma. It runs with docker compose in `/opt/server-setup/monitoring`, with images pulled directly or through the mirror.

| Mode | Use it when |
|---|---|
| `local` | one server (a startup): the stack runs right here |
| `hub` | this server watches many: the others `join` it over TLS with a login (port 8430) |
| `external` | you already run Prometheus-compatible storage + Loki: only the agent |
| `none` | no monitoring |

```bash
sudo server-setup monitor setup                           # choose the mode, retention, alert receivers
sudo server-setup monitor token                           # on the hub: the agents' login
sudo server-setup monitor join https://hub.example:8430   # on every other server
sudo server-setup monitor move-to https://hub:8430        # a 'local' server grows: agent re-pointed, metric history copied
```

**Alerts:**
- server silent
- disk almost full / fills within 24 h
- low memory, swap almost full, OOM kill
- high load
- failed service
- clock not synced
- reboot needed for a day, security updates waiting 2 days
- a container restarting

They go to Telegram (needs internet), e-mail (SMTP) and/or a webhook. Grafana and Uptime Kuma listen on localhost only, reached through SSH: `ssh -L 3000:127.0.0.1:3000 <server>`. Nothing reports usage to Grafana Labs, and Grafana doesn't preinstall plugins from the internet.

## Dokploy node: a server managed by a remote Dokploy panel

The Dokploy panel runs elsewhere. It logs in to this server over SSH and runs its **Setup Server** script, and each step of that script is skipped when its result already exists. `dokploy-node` creates all of those results ahead of time, through the direct-or-mirror sources. So "Setup Server" also works on a server **without internet**:

| Panel step | Done here instead |
|---|---|
| utilities, rclone (`rclone.org/install.sh`) | apt |
| Docker (`get.docker.com`, compose from GitHub) | Docker's apt repo (Swarm-ready, logs capped, firewall-aware) |
| Swarm (address from `ifconfig.io`) | `swarm init` with the address you give / the routing address |
| `dokploy-network` | created |
| Traefik container (`docker run traefik:v3.7.19`) | image pulled in advance; the panel still writes its config and starts it |
| nixpacks, railpack, pack (install scripts) | the pinned GitHub releases (pack checksum-verified) |

```bash
sudo server-setup dokploy-node prepare            # asks for the panel's SSH key and IP
sudo server-setup dokploy-node status
sudo server-setup dokploy-node sync v0.26.0       # a newer panel: read its versions from Dokploy's source
```

- **Panel access:** the panel logs in as `dokploy`, key-only and **only from the panel's IP**, with no forwarding. Dokploy requires passwordless sudo and the docker group, so this user is effectively root. That's said plainly in the report. Root login stays off.
- **Firewall:** 80/443 are open for Traefik (including HTTP/3). Swarm ports 2377/7946/4789 are open only to the Swarm peers you list.
- **Updates:** Docker and containerd are never restarted by automatic updates, which would restart every app.
- **Building without internet:** Dockerfile builds work, with Docker Hub images through the mirror. Nixpacks/Railpack also pull **ghcr.io** images, which Docker can't mirror. For those, add a ghcr.io proxy to Nexus and pre-pull the images, or use Dockerfiles. Builds that run npm/pip/go need the mirror URLs as build variables in Dokploy; the report prints them.

## Fleet: many servers from one

One server, usually the monitoring hub, manages the others over SSH. On a member, the manager's key may run **one program only**: the fleet agent, which accepts `brief`, `status`, `update`, `update-all` and `version`. The key gives no shell and no forwarding, and works only from the manager's address. sudo is allowed for exactly that program.

```bash
# on the manager
sudo server-setup fleet init                       # prints the join command
sudo server-setup fleet add web-1 10.0.0.11
sudo server-setup fleet status                     # one table: uptime, load, memory, disk, reboot needed, updates, failed services
sudo server-setup fleet update --all web-1 web-2   # or every server
sudo server-setup fleet show web-1                 # its full status
# on each managed server
sudo server-setup fleet join "ssh-ed25519 AAAA... server-setup-fleet@hub" --from 10.0.0.5
```

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
monitor status|setup|apply|join <hub>|move-to <hub>|token|alerts
dokploy-node prepare|status|sync [<dokploy-version>]
fleet init | add <name> <host> [--port P] | remove <name> | list | status | show <name> | update [--all]
fleet join "<manager key>" --from <manager IP>
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
3. ~~**monitor**: Alloy agent; local / hub / external stack; move-to~~ ✅
4. ~~**dokploy-node**: Dokploy's Setup Server steps done ahead of time~~ ✅
5. ~~**fleet**: manage many servers from the hub~~ ✅

## Testing status

**Real server (Ubuntu 24.04, 2 CPU / 4 GB):**
- **Setup:** a full `setup` (tools docker/node/python, local monitoring, auditd, Lynis), then a **re-run**, which keeps every earlier answer.
- **SSH:**
  - The admin login confirms the change, on two ports. SSH is limited to one IP, with no open-to-all rule.
  - **Rollback:** answering "no" to a port change restores the old ports, closes the new port in the firewall, and restores the saved config.
- **Docker firewall:** published ports filtered by host port. `80→80` and `443→80` are reachable, `8080→80` is blocked and logged.
- **Monitoring:**
  - `local`: metrics, container metrics, the journal and container logs, server-setup's facts, alert rules, and the Grafana dashboard.
  - `hub`: the gateway uses TLS (Caddy's CA), refuses wrong or missing logins (401) and plain HTTP, and is open only to the allowed agent IPs. Its routes to VictoriaMetrics and Loki work.
- **Under pressure:** the CPU / memory / disk-full stress tests above.
- **fleet:**
  - init / join / add / status / update, with the server managing itself.
  - The forced command refuses anything else.
  - `join` adds the manager to the SSH allow-list.
- **dokploy-node prepare:**
  - Swarm, `dokploy-network`, the Traefik image, nixpacks/railpack/pack, rclone.
  - The panel user limited to the panel's IP, and 443/udp.
- **Internal-network simulation** (outbound blocked except DNS and Nexus):
  - `mirror test` shows that direct fails for every source, and each Nexus repo's status.
  - `mirror recheck` stops with a clear message and **leaves apt untouched** when the mirror can't serve apt.
  - `rescue` works offline.

**Bugs found on the real server, all fixed:**
- Docker's route rules let `8080→80` through.
- The monitoring step failed on non-hub servers.
- cAdvisor needs root.
- Docker's config wasn't refreshed on a re-run.
- A **Docker restart left every container stopped**, now fixed with `docker_restart`.
- A fleet **deadlock** when the hub is its own member.
- The SSH rollback left the rejected port open.

**Still to test:**
- The *successful* mirror path. It needs Nexus apt/npm/GitHub repos, or the real repo names.
- Debian 12 and Ubuntu 22.04.
- Dokploy's "Setup Server" from a real panel, including whether the panel needs SSH forwarding.
- fleet and hub agents across two different servers.

Also tested locally:

Everything that can run without root was tested on Ubuntu 24.04:
- **Sources:** direct apt works, and OS vs third-party sources are told apart. Checks ran against the real Nexus (it answers 401 or 404 for each repo).
- **Configs:** every generated config parses. `docker compose config` accepts the monitoring stack. The Docker `daemon.json` variants are valid JSON. App units pass `systemd-analyze verify`.
- **Downloads:** real downloads of the Go checksum and of the nixpacks/railpack/pack release assets, with pack's sha256 verified.
- **Dokploy sync:** reads the versions from Dokploy's current source, and they match the built-in defaults.
- **Fleet:** forced command, `from=` restriction and forwarding refusal tested against a real (unprivileged) sshd.

**Not yet verified:** a full `setup` as root on a disposable Ubuntu 22.04/24.04 and Debian 12 VM, with internet and with internet blocked except to Nexus. That covers the SSH rollback, ufw + DOCKER-USER rules, the Alloy agent and Caddy gateway configs (checked by structure, not by the real binaries), and Dokploy's "Setup Server" on a prepared node. On that test, also check whether the panel needs SSH forwarding for anything beyond running commands. Its key is set to `no-port-forwarding`. Run it on a test VM first.
