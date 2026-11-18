# Laravel server installation

Idempotent installation script for a Laravel-capable Ubuntu 24.04 LTS host,
plus a migration script for active hosts that still run Supervisor.

## `install.sh`

Run as root:

```sh
sudo ./install.sh
```

Or, without cloning the repository, run the script straight from `main`:

```sh
sudo bash <(curl -fsSL https://raw.githubusercontent.com/leadotek-dev/webserver_installation/main/install.sh)
```

Process substitution keeps the terminal on stdin, so the interactive prompts
work. Do not use `curl ... | sudo bash`: bash would read the prompts from the
piped script instead of the terminal.

Re-running the script is safe.

`install.sh` assumes a fresh host: it does not port anything from Supervisor.
Active hosts still running the old Supervisor program use
`migrate_to_systemd.sh` instead (see below).

Prompts, in order:

1. Timezone (required, no default). Must be an IANA name that appears in
   `timedatectl list-timezones`; an empty or unknown answer aborts the run
   before the host is changed.
2. Absolute Laravel installation directory. Empty skips the queue workers and
   the scheduler, for hosts where the application is not deployed yet. A path
   without `artisan` aborts before the host is changed.
3. Number of queue workers (default `1`), only when a directory was given.
4. Reboot confirmation, only when `/var/run/reboot-required` exists.

Installed and configured:

- Caddy from the official Cloudsmith stable repository. Installed only, no
  Caddyfile or site configuration is written.
- PHP-FPM, CLI and the Laravel extensions (`sqlite3`, `pgsql`, `xml`, `curl`,
  `bcmath`, `gd`, `intl`, `mbstring`, `readline`, `zip`) from the ondrej PPA,
  latest track. A drop-in
  (`/etc/php/<version>/fpm/pool.d/zz-caddy-socket.conf`) points every pool at
  the stable socket `/run/php/php-fpm.sock`, owned by `www-data`.
- CrowdSec with the `crowdsecurity/caddy` collection, the acquisition file
  `/etc/crowdsec/acquis.d/caddy.yaml` for `/var/log/caddy/*.log`, and the
  nftables firewall bouncer. Caddy must write access logs to that directory
  for the collection to see traffic. The packagecloud repository and key are
  added directly, following
  <https://docs.crowdsec.net/u/getting_started/installation/linux/>, without
  executing the bootstrap script. The signing key fingerprint is pinned in
  `install.sh` (`6A89E3C2303A901A889971D3376ED5326E93CD0C`, UID
  `https://packagecloud.io/crowdsec/crowdsec`); the docs publish no
  fingerprint, so a rotation requires updating the constant after checking
  the new key.
- UFW with `ssh`, `http` and `https` allowed and the firewall enabled.
- Unattended upgrades with an automatic reboot at 03:00.
- `tuptime`, `btop`, `ncdu`, and the `hl` log highlighter in
  `/usr/local/bin/hl`. `hl` is pinned to `HL_VERSION` and its tarball is
  checked against the SHA256 constants before installation; GitHub publishes
  no checksum file, so upgrading `hl` means bumping the version and both
  hashes in `install.sh`.
- Timestamped bash history for root (`HISTTIMEFORMAT`).
- Queue workers when a Laravel directory is given:
  - `/etc/systemd/system/laravel-worker@.service`, a template unit that keeps
    `php artisan queue:work` running as `www-data`. `Restart=always` covers the
    exit code 0 Laravel uses on purpose (lost database connection,
    `queue:restart`, `--max-time`); `RestartSec=5` spaces the retries.
    `StartLimitIntervalSec=0` keeps a database outage from ending in the
    `failed` state, and `TimeoutStopSec=1900` lets a running job finish.
  - One instance per worker (`laravel-worker@1`, ...). A re-run with a lower
    count stops and disables the surplus instances.
  - A root cron entry running `php artisan schedule:run` every minute. The
    entry replaces the current root crontab.

Behaviour notes:

- Ubuntu 24.04 LTS is enforced; other releases exit before any change.
- The script never reboots on its own.
- The PHP socket path is stable across PHP upgrades, so Caddy configuration
  does not need to change when the PHP minor version moves. The socket
  drop-in is compared with the rendered content, and PHP-FPM is restarted
  only when it differs, so re-runs do not interrupt served requests.
- Package lists are refreshed once per run, after the repositories are
  added; the pre-repository base install only refreshes when the host has no
  lists at all.
- Enabling UFW can cut off SSH access if SSH does not listen on a port
  covered by the `ssh` rule. Adjust rules before running on such a host.
- Queue workers rely on the application being deployed and migrated.

## `migrate_to_systemd.sh`

For active hosts that still run the Supervisor program written by
`legacy/queues_schedules.sh`. Run as root:

```sh
sudo ./migrate_to_systemd.sh
```

Or, without cloning the repository, run the script straight from `main`:

```sh
sudo bash <(curl -fsSL https://raw.githubusercontent.com/leadotek-dev/webserver_installation/main/migrate_to_systemd.sh)
```

Process substitution keeps the terminal on stdin, so the interactive prompts
work. Do not use `curl ... | sudo bash`.

Re-running is safe. Prompts, in order:

1. Laravel installation directory, defaulting to the path found in the
   Supervisor program command.
2. Number of queue workers, defaulting to the Supervisor `numprocs` value.
3. Supervisor purge confirmation. Default is yes when it manages nothing
   else, no when other programs in `/etc/supervisor/conf.d` would be stopped.

What it does:

- Writes `/etc/systemd/system/laravel-worker@.service` (same unit as
  `install.sh`) and starts one instance per worker. A unit whose content is
  unchanged is not restarted, so a re-run does not interrupt a running job.
- Starts the systemd instances before stopping the Supervisor program, so the
  queue keeps a consumer. Both sets run briefly; competing queue workers do
  not lose jobs.
- Stops and removes `/etc/supervisor/conf.d/laravel-worker.conf`, then purges
  Supervisor after confirmation.
- Replaces only root cron lines containing `artisan schedule:run`; other root
  crontab entries are kept.
- Disables and deletes the legacy single-instance `laravel-worker.service`
  unit, and removes surplus template instances when the worker count drops.
- Verifies that every instance is active and prints its unit list.

Prerequisites: Ubuntu 24.04 LTS, root, systemd, PHP CLI and cron.

## Deprecated

In `legacy/`, kept for reference only:

- `legacy/queues_schedules.sh` is superseded by `install.sh` for fresh hosts
  and by `migrate_to_systemd.sh` for active hosts. Both include the queue
  worker and scheduler setup.
- `legacy/initial_install.sh` is the original non-idempotent one-liner.

## Requirements

- Ubuntu 24.04 LTS, root access, network access to the package repositories
  and GitHub.
- No database is installed. Point `DB_*` in the application `.env` at an
  existing database server.

## Files not managed

- Caddy site configuration.
- Application deployment, `.env`, migrations.
- SSH hardening.
