#!/usr/bin/env bash
#
# install.sh -- idempotent installation of the Laravel webserver stack on
# Ubuntu 24.04 LTS.
#
# Installs and configures:
#   - Caddy (official Cloudsmith repository), installed only, no Caddyfile
#     changes.
#   - PHP-FPM, CLI and the Laravel extensions, latest track from the ondrej
#     PPA, plus a stable FPM socket at /run/php/php-fpm.sock.
#   - CrowdSec with the Caddy collection, a log acquisition file and the
#     nftables firewall bouncer.
#   - UFW with ssh, http and https allowed.
#   - Unattended upgrades with a nightly reboot window, tuptime, btop, ncdu
#     and hl.
#   - Optional Laravel runtime: systemd queue worker instances
#     (`laravel-worker@.service`) and a cron entry for
#     `php artisan schedule:run` every minute. Only when a Laravel installation
#     directory is given.
#
# The host is assumed to be fresh: nothing is ported from Supervisor. Active
# servers still running the old Supervisor program use
# migrate_to_systemd.sh first.
#
# Every step checks the current state before it changes anything, so the
# script can be re-run safely. It never reboots on its own; it asks at the
# end when a reboot is required.
#
# Usage: sudo ./install.sh

set -euo pipefail

readonly CROWDSEC_ACQUIS='/etc/crowdsec/acquis.d/caddy.yaml'
# CrowdSec repository keyring and source list, named as in the official
# installation guide (docs.crowdsec.net/u/getting_started/installation/linux),
# plus the packagecloud key fingerprint. The guide publishes no fingerprint,
# so it is pinned on purpose: if packagecloud rotates the key, the install
# stops and the value below has to be updated after checking that the new key
# UID points at https://packagecloud.io/crowdsec/crowdsec.
readonly CROWDSEC_KEY_FINGERPRINT='6A89E3C2303A901A889971D3376ED5326E93CD0C'
readonly CROWDSEC_KEYRING='/etc/apt/keyrings/crowdsec_crowdsec-archive-keyring.gpg'
readonly CROWDSEC_SOURCES='/etc/apt/sources.list.d/crowdsec_crowdsec.list'
# Pinned hl release and per-architecture tarball checksums. GitHub releases
# carry no checksum file, so the hashes live here and must be bumped together
# with HL_VERSION. Update them only after downloading the tarballs from the
# release page and comparing their sha256sum.
readonly HL_VERSION='v0.36.5'
readonly HL_SHA256_X86_64='e38e8cd156bf7db377da6ce680166d0e330a0b77ded5f41ef69696ad0e8147bc'
readonly HL_SHA256_ARM64='00efdc6e1b8de38174089555f1dc3846c93db9fb9252143a10b1a91f39dba7e8'
readonly UNATTENDED_CONFIG='/etc/apt/apt.conf.d/51unattended-upgrades'
readonly HISTTIMEFORMAT_LINE="export HISTTIMEFORMAT='%F %T  '"

# Print an error and stop.
err() {
  printf '%s\n' "$*" >&2
  exit 1
}

# Print progress information.
info() {
  printf '==> %s\n' "$*"
}

# Fail unless the script runs as root.
require_root() {
  if (( EUID != 0 )); then
    err 'run this script as root (sudo ./install.sh)'
  fi
}

# Fail unless the host is Ubuntu 24.04 LTS.
require_ubuntu_2404() {
  local id=''
  local version_id=''

  if [[ ! -r /etc/os-release ]]; then
    err '/etc/os-release is missing, cannot identify the distribution'
  fi

  # shellcheck disable=SC1091
  source /etc/os-release
  id="${ID:-}"
  version_id="${VERSION_ID:-}"

  if [[ "${id}" != 'ubuntu' || "${version_id}" != '24.04' ]]; then
    err "Ubuntu 24.04 LTS required, found ${id} ${version_id}"
  fi
}

# Ask for the timezone once and validate it against tzdata. There is no
# default: an empty answer stops the script before the host is changed, since
# guessing the zone would silently shift log and cron timestamps.
prompt_timezone() {
  local timezone=''

  read -r -p 'Timezone (IANA name, e.g. Africa/Bujumbura): ' timezone
  if [[ -z "${timezone}" ]]; then
    err 'a timezone is required'
  fi

  if ! timedatectl list-timezones | grep -Fxq "${timezone}"; then
    err "unknown timezone: ${timezone}"
  fi

  printf '%s\n' "${timezone}" > /etc/timezone
  timedatectl set-timezone "${timezone}"
}

# Refresh the package lists only when the host has none. The repository setup
# below needs the base tools, but a normal host already carries lists from its
# image or an earlier run, so the unconditional refresh happens after the
# repositories are added.
refresh_package_lists_if_missing() {
  local lists=()

  mapfile -t lists < <(compgen -G '/var/lib/apt/lists/*_Packages*' || true)
  if (( ${#lists[@]} > 0 )); then
    return
  fi

  info 'package lists missing, refreshing'
  DEBIAN_FRONTEND=noninteractive apt-get update
}

# Install the base tools needed to add the third-party repositories.
install_base_packages() {
  refresh_package_lists_if_missing

  info 'installing base packages'
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    apt-transport-https \
    btop \
    ca-certificates \
    curl \
    debian-archive-keyring \
    debian-keyring \
    gnupg \
    ncdu \
    software-properties-common \
    tuptime \
    ufw \
    unattended-upgrades \
    wget
}

# Add the ondrej PHP PPA unless it is already configured.
add_php_repository() {
  local sources=()

  # The PPA is stored as ondrej-ubuntu-php-*.sources on 24.04.
  mapfile -t sources < <(compgen -G '/etc/apt/sources.list.d/ondrej-ubuntu-php-*.sources' || true)
  if (( ${#sources[@]} > 0 )); then
    info 'ondrej PHP PPA already configured'
    return
  fi

  info 'adding ondrej PHP PPA'
  add-apt-repository --yes ppa:ondrej/php
}

# Add the Caddy stable repository and its signing key unless present.
add_caddy_repository() {
  local keyring='/usr/share/keyrings/caddy-stable-archive-keyring.gpg'
  local sources='/etc/apt/sources.list.d/caddy-stable.list'

  if [[ ! -f "${keyring}" ]]; then
    info 'adding Caddy repository key'
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
      | gpg --dearmor --yes -o "${keyring}"
  fi

  if [[ ! -f "${sources}" ]]; then
    info 'adding Caddy repository'
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
      > "${sources}"
  fi
}

# Add the CrowdSec packagecloud repository the way the official bootstrap
# script does, but with the key fetched directly and its fingerprint checked:
# nothing from the network is executed. Skipped when a CrowdSec source list
# or a keyring already exists.
add_crowdsec_repository() {
  local sources=()
  local tmp_key=''
  local key_fingerprint=''

  # Matches both the .list and the deb822 .sources format.
  mapfile -t sources < <(compgen -G '/etc/apt/sources.list.d/crowdsec*' || true)
  if (( ${#sources[@]} > 0 )); then
    info 'CrowdSec repository already configured'
    return
  fi

  info 'adding CrowdSec repository'
  install -d -m 0755 /etc/apt/keyrings

  tmp_key="$(mktemp)"
  trap 'rm -f "${tmp_key}"' RETURN

  # -f makes curl fail on HTTP errors instead of storing an error page as key.
  curl -fsSL 'https://packagecloud.io/crowdsec/crowdsec/gpgkey' -o "${tmp_key}"

  key_fingerprint="$(gpg --show-keys --with-colons "${tmp_key}" 2> /dev/null \
    | awk -F: '$1 == "fpr" {print $10; exit}')"
  if [[ "${key_fingerprint}" != "${CROWDSEC_KEY_FINGERPRINT}" ]]; then
    err "CrowdSec key fingerprint mismatch: expected ${CROWDSEC_KEY_FINGERPRINT}, got ${key_fingerprint:-none}"
  fi

  gpg --dearmor --yes -o "${CROWDSEC_KEYRING}" < "${tmp_key}"
  chmod 0644 "${CROWDSEC_KEYRING}"

  # Repository lines from the official installation guide, with an explicit
  # signed-by so apt only accepts this key for this repository.
  cat > "${CROWDSEC_SOURCES}" <<EOF
# Managed by install.sh: CrowdSec packagecloud repository.
deb [signed-by=${CROWDSEC_KEYRING}] https://packagecloud.io/crowdsec/crowdsec/any any main
deb-src [signed-by=${CROWDSEC_KEYRING}] https://packagecloud.io/crowdsec/crowdsec/any any main
EOF
  chmod 0644 "${CROWDSEC_SOURCES}"
}

# Refresh the package lists and apply pending upgrades. Idempotent: an
# up-to-date host upgrades nothing.
upgrade_system() {
  # The only unconditional refresh: the repositories added above changed the
  # lists, and the installations below depend on them.
  info 'updating package lists'
  DEBIAN_FRONTEND=noninteractive apt-get update

  info 'applying pending upgrades'
  DEBIAN_FRONTEND=noninteractive apt-get -y dist-upgrade
}

# Install PHP-FPM and the extensions a Laravel application needs. The
# unversioned package names resolve to the newest version in the PPA.
install_php() {
  info 'installing PHP-FPM and extensions'
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    php-bcmath \
    php-cli \
    php-curl \
    php-fpm \
    php-gd \
    php-intl \
    php-mbstring \
    php-pgsql \
    php-readline \
    php-sqlite3 \
    php-xml \
    php-zip
}

# Install Caddy, CrowdSec and the firewall bouncer. apt-get install is a
# no-op when everything is already at the newest version.
install_security_and_webserver() {
  info 'installing Caddy, CrowdSec and the nftables bouncer'
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    caddy \
    crowdsec \
    crowdsec-firewall-bouncer-nftables
}

# Point every installed PHP-FPM pool at one stable socket path and give the
# web server access to it. The drop-in replaces the versioned default socket,
# so a PHP upgrade does not invalidate the web server configuration.
configure_php_fpm_socket() {
  local pools=()
  local pool_dir=''
  local version=''
  local dropin=''
  local socket='/run/php/php-fpm.sock'
  local content=''

  mapfile -t pools < <(compgen -G '/etc/php/*/fpm/pool.d' || true)
  if (( ${#pools[@]} == 0 )); then
    err 'no PHP-FPM pool directory found'
  fi

  content="$(cat <<EOF
; Managed by install.sh: stable socket for the web server.
listen = ${socket}
listen.owner = www-data
listen.group = www-data
listen.mode = 0660
EOF
)"

  for pool_dir in "${pools[@]}"; do
    version="$(basename "$(dirname "${pool_dir}")")"
    # Filename sorts last so it wins over the package defaults.
    dropin="${pool_dir}/zz-caddy-socket.conf"

    # enable --now covers the first install and a stopped service; restart is
    # only needed when the drop-in actually changed, since it interrupts
    # requests being served.
    systemctl enable --now "php${version}-fpm"
    # Plain string comparison avoids depending on diffutils, which minimal
    # server images do not always ship.
    if [[ -f "${dropin}" && "$(< "${dropin}")" == "${content}" ]]; then
      info "PHP-FPM socket drop-in unchanged for ${version}"
      continue
    fi

    printf '%s\n' "${content}" > "${dropin}"
    systemctl restart "php${version}-fpm"
    info "PHP-FPM ${version} listening on ${socket}"
  done
}

# Ask for the Laravel installation the queue workers serve. An empty answer
# skips the queue and scheduler setup, for hosts without the application yet.
# The path is printed on stdout so main can keep it in a local variable.
prompt_laravel_dir() {
  local dir=''

  read -r -p 'Absolute Laravel installation directory (empty to skip): ' dir
  # A trailing slash would produce //artisan in the unit file.
  dir="${dir%/}"

  if [[ -z "${dir}" ]]; then
    printf '\n'
    return
  fi

  # Fail before touching the host: a unit pointing at a missing artisan would
  # only restart-loop.
  if [[ ! -f "${dir}/artisan" ]]; then
    err "no artisan found in ${dir}"
  fi

  if [[ ! -d /run/systemd/system ]]; then
    err 'systemd is not running on this host'
  fi

  printf '%s\n' "${dir}"
}

# Ask for the number of queue worker instances and validate it.
prompt_worker_count() {
  local count=''

  # A single worker is the safe default on the database queue; more workers
  # mean more concurrent pollers.
  read -r -p 'Number of queue workers [1]: ' count
  count="${count:-1}"

  if [[ ! "${count}" =~ ^[0-9]+$ ]] || (( count < 1 )); then
    err 'number of workers must be a positive integer'
  fi

  printf '%s\n' "${count}"
}

# Configure the nightly unattended upgrade reboot window.
configure_unattended_upgrades() {
  info 'configuring unattended upgrades'
  cat > "${UNATTENDED_CONFIG}" <<'EOF'
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "03:00";
EOF
  systemctl enable --now unattended-upgrades
}

# Add the firewall rules and enable the firewall. allow and enable are
# idempotent, so re-runs keep the existing ruleset.
configure_firewall() {
  info 'configuring UFW'
  ufw allow ssh
  ufw allow http
  ufw allow https
  ufw --force enable
  ufw status verbose
}

# Add crowdsec to the Caddy log acquisition and install the Caddy collection.
configure_crowdsec() {
  info 'configuring CrowdSec'

  # Caddy has to write access logs to /var/log/caddy/*.log for this to work;
  # the site configuration is out of scope here.
  mkdir -p "$(dirname "${CROWDSEC_ACQUIS}")"
  cat > "${CROWDSEC_ACQUIS}" <<'EOF'
filenames:
  - /var/log/caddy/*.log
labels:
  type: caddy
EOF

  if ! cscli collections inspect crowdsecurity/caddy > /dev/null 2>&1; then
    cscli collections install crowdsecurity/caddy
  fi

  systemctl enable --now crowdsec
  systemctl enable --now crowdsec-firewall-bouncer
}

# Add timestamped history to the root shell profile once.
configure_shell_history() {
  if grep -Fqx "${HISTTIMEFORMAT_LINE}" "${HOME}/.bashrc"; then
    return
  fi

  info 'enabling timestamped bash history'
  printf '%s\n' "${HISTTIMEFORMAT_LINE}" >> "${HOME}/.bashrc"
}

# Install the hl log highlighter from the pinned GitHub release. The tarball
# checksum is verified before anything is unpacked or installed. Skipped when
# hl is already in PATH; upgrades require bumping the pinned version.
install_hl() {
  local asset=''
  local expected_sha=''
  local actual_sha=''
  local tmp_dir=''

  if command -v hl > /dev/null 2>&1; then
    info "hl already installed, pinned release ${HL_VERSION} not fetched"
    return
  fi

  # The release assets use arm64 where uname reports aarch64.
  case "$(uname -m)" in
    x86_64)
      asset='x86_64'
      expected_sha="${HL_SHA256_X86_64}"
      ;;
    aarch64)
      asset='arm64'
      expected_sha="${HL_SHA256_ARM64}"
      ;;
    *)
      info "hl has no release for $(uname -m), skipping"
      return
      ;;
  esac

  info "installing hl ${HL_VERSION} for ${asset}"
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "${tmp_dir}"' RETURN

  wget -q "https://github.com/pamburus/hl/releases/download/${HL_VERSION}/hl-linux-${asset}-musl.tar.gz" \
    -O "${tmp_dir}/hl.tar.gz"

  actual_sha="$(sha256sum "${tmp_dir}/hl.tar.gz" | awk '{print $1}')"
  if [[ "${actual_sha}" != "${expected_sha}" ]]; then
    err "hl checksum mismatch: expected ${expected_sha}, got ${actual_sha}"
  fi

  tar -xf "${tmp_dir}/hl.tar.gz" -C "${tmp_dir}"
  install -m 0755 "${tmp_dir}/hl" /usr/local/bin/hl
}

# Offer the reboot that kernel and library upgrades need. The reboot is never
# automatic, so a re-run cannot interrupt an installation.
maybe_reboot() {
  local answer=''

  if [[ ! -f /var/run/reboot-required ]]; then
    info 'no reboot required'
    return
  fi

  if ! read -r -p 'Reboot required. Reboot now? [y/N] ' answer; then
    answer='n'
  fi

  if [[ "${answer}" =~ ^[Yy]$ ]]; then
    info 'rebooting'
    reboot
  else
    info 'reboot skipped, run "reboot" when convenient'
  fi
}

# Install the queue worker template unit, start one instance per worker and
# replace the scheduler crontab entry.
install_queue_workers() {
  local laravel_dir="$1"
  local worker_count="$2"
  local php_bin=''
  local unit=''
  local index=''
  local i=''
  local link=''
  local -a links=()

  php_bin="$(command -v php)" || err 'php not found in PATH'

  info "installing ${worker_count} queue worker(s) for ${laravel_dir}"
  # StartLimitIntervalSec=0 disables systemd's start rate limit (default 5
  # starts per 10 s), so a database outage cannot end in the "failed" state;
  # RestartSec=5 does the spacing instead. TimeoutStopSec is longer than the
  # longest job, so a running job finishes before SIGKILL.
  cat > /etc/systemd/system/laravel-worker@.service <<UNIT
[Unit]
Description=Laravel Queue Worker (%i)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=exec
User=www-data
Group=www-data
WorkingDirectory=${laravel_dir}
ExecStart=${php_bin} "${laravel_dir}/artisan" queue:work --tries=1 --sleep=3 --timeout=1800 --max-time=3600
# "always", not "on-failure": Laravel exits 0 on purpose for a lost database
# connection, a queue:restart signal and --max-time.
Restart=always
RestartSec=5
TimeoutStopSec=1900
SyslogIdentifier=laravel-worker-%i

[Install]
WantedBy=multi-user.target
UNIT

  # Scheduler entry. Replaces the current root crontab. The absolute php path
  # keeps cron's minimal PATH out of the picture.
  printf '* * * * * cd %q && %q artisan schedule:run >> /dev/null 2>&1\n' \
    "${laravel_dir}" "${php_bin}" | crontab -

  systemctl daemon-reload

  # A re-run with a lower count must not leave workers behind: disable every
  # enabled instance above the requested count. The wanted-by symlinks are the
  # exact set of instances that would start on boot.
  mapfile -t links < <(compgen -G '/etc/systemd/system/multi-user.target.wants/laravel-worker@*.service' || true)
  for link in "${links[@]}"; do
    unit="$(basename "${link}")"
    index="${unit#laravel-worker@}"
    index="${index%.service}"
    if [[ "${index}" =~ ^[0-9]+$ ]] && (( index > worker_count )); then
      info "removing surplus worker ${unit}"
      systemctl disable --now "${unit}" || true
    fi
  done

  for ((i = 1; i <= worker_count; i++)); do
    unit="laravel-worker@${i}.service"
    systemctl enable "${unit}"
    # restart, not start: a re-run must pick up the rewritten unit.
    systemctl restart "${unit}"
  done

  systemctl --no-pager --plain list-units 'laravel-worker@*.service' || true
  crontab -l
}

# Report the result of the run.
print_summary() {
  local laravel_dir="$1"
  local worker_count="$2"
  local version=''

  version="$(php -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;')"
  info "PHP ${version} with FPM on unix//run/php/php-fpm.sock"
  info 'Caddy installed, no site configuration was written'
  info 'CrowdSec: caddy collection, /var/log/caddy acquisition, nftables bouncer'
  info 'UFW: ssh, http, https allowed'

  if [[ -n "${laravel_dir}" ]]; then
    info "queue workers: ${worker_count} instance(s) for ${laravel_dir}"
    info 'scheduler: cron entry for php artisan schedule:run every minute'
  else
    info 'queue workers and scheduler skipped (no Laravel directory given)'
  fi
}

main() {
  local laravel_dir=''
  local worker_count=''

  require_root
  require_ubuntu_2404

  prompt_timezone

  # Ask up front so a wrong application path fails before the host changes.
  laravel_dir="$(prompt_laravel_dir)"
  if [[ -n "${laravel_dir}" ]]; then
    worker_count="$(prompt_worker_count)"
  fi

  install_base_packages
  add_php_repository
  add_caddy_repository
  add_crowdsec_repository
  upgrade_system

  install_php
  install_security_and_webserver

  configure_php_fpm_socket
  configure_unattended_upgrades
  configure_firewall
  configure_crowdsec
  configure_shell_history
  install_hl

  if [[ -n "${laravel_dir}" ]]; then
    install_queue_workers "${laravel_dir}" "${worker_count}"
  fi

  print_summary "${laravel_dir}" "${worker_count}"
  maybe_reboot
}

main "$@"
