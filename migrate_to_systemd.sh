#!/usr/bin/env bash
#
# migrate_to_systemd.sh -- move the Laravel queue workers on an active server
# from Supervisor to systemd.
#
# The script is meant for hosts installed with the previous
# legacy/queues_schedules.sh, which ran one Supervisor program
# (/etc/supervisor/conf.d/laravel-worker.conf) and a root cron entry for
# `php artisan schedule:run`. It
#   1. reads the Laravel directory and worker count from the Supervisor
#      program as prompt defaults,
#   2. writes and starts the systemd template unit laravel-worker@.service,
#   3. stops and removes the Supervisor program,
#   4. replaces only the scheduler line in the root crontab, keeping any other
#      entries, and
#   5. purges Supervisor after confirmation (default yes when it manages
#      nothing else).
#
# The systemd instances are started before the Supervisor program is stopped,
# so the queue is never without a worker. Both run for a moment; competing
# queue workers do not lose jobs.
#
# Every step checks the current state first, so the script can be re-run.
# Use install.sh for fresh hosts; it does not port Supervisor.
#
# Usage: sudo ./migrate_to_systemd.sh

set -euo pipefail

readonly SUPERVISOR_PROGRAM='laravel-worker'
readonly SUPERVISOR_CONF='/etc/supervisor/conf.d/laravel-worker.conf'
readonly UNIT_PATH='/etc/systemd/system/laravel-worker@.service'
# Single-instance unit from an earlier systemd attempt; it would keep a second
# worker alive next to the template instances.
readonly LEGACY_UNIT='/etc/systemd/system/laravel-worker.service'

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
    err 'run this script as root (sudo ./migrate_to_systemd.sh)'
  fi
}

# Fail unless the host is Ubuntu 24.04 LTS, matching install.sh.
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

# Fail unless systemd is the running init and cron is available; both are
# prerequisites for the units and the scheduler entry written below.
require_runtime() {
  local missing=()

  if [[ ! -d /run/systemd/system ]]; then
    err 'systemd is not running on this host'
  fi

  command -v crontab > /dev/null 2>&1 || missing+=('cron')
  command -v php > /dev/null 2>&1 || missing+=('php-cli')
  if (( ${#missing[@]} > 0 )); then
    err "missing prerequisites: ${missing[*]} (install with apt-get)"
  fi
}

# Print the Laravel directory from the Supervisor program command line, if the
# config exists and names an artisan path. Used only as a prompt default.
supervisor_artisan_dir() {
  local command_line=''
  local token=''
  local -a tokens=()

  [[ -r "${SUPERVISOR_CONF}" ]] || return 1

  # command=php /var/www/app/artisan queue:work ...
  command_line="$(awk -F= '$1 == "command" { sub(/^[^=]*=/, ""); print; exit }' "${SUPERVISOR_CONF}")"
  read -r -a tokens <<< "${command_line}"
  for token in "${tokens[@]}"; do
    if [[ "${token}" == */artisan ]]; then
      printf '%s\n' "${token%/artisan}"
      return 0
    fi
  done
  return 1
}

# Print the process count from the Supervisor program, if valid. Used only as
# a prompt default.
supervisor_worker_count() {
  local count=''

  [[ -r "${SUPERVISOR_CONF}" ]] || return 1

  count="$(awk -F= '$1 == "numprocs" { gsub(/[[:space:]]/, "", $2); print $2; exit }' "${SUPERVISOR_CONF}")"
  if [[ "${count}" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s\n' "${count}"
    return 0
  fi
  return 1
}

# Ask for the Laravel installation served by the workers, defaulting to the
# path found in the Supervisor program.
prompt_laravel_dir() {
  local default_dir=''
  local prompt='Absolute Laravel installation directory: '
  local dir=''

  default_dir="$(supervisor_artisan_dir || true)"
  if [[ -n "${default_dir}" ]]; then
    prompt="Absolute Laravel installation directory [${default_dir}]: "
  fi

  # EOF aborts before the host changes instead of looping on an empty answer.
  if ! read -r -p "${prompt}" dir; then
    err 'no input, aborting'
  fi
  dir="${dir:-${default_dir}}"
  # A trailing slash would produce //artisan in the unit file.
  dir="${dir%/}"

  if [[ -z "${dir}" ]]; then
    err 'a Laravel installation directory is required'
  fi

  # Fail before touching the host: a unit pointing at a missing artisan would
  # only restart-loop.
  if [[ ! -f "${dir}/artisan" ]]; then
    err "no artisan found in ${dir}"
  fi

  printf '%s\n' "${dir}"
}

# Ask for the number of queue worker instances, defaulting to the Supervisor
# numprocs value.
prompt_worker_count() {
  local default_count=''
  local prompt='Number of queue workers [1]: '
  local count=''

  default_count="$(supervisor_worker_count || true)"
  if [[ -n "${default_count}" ]]; then
    prompt="Number of queue workers [${default_count}]: "
  fi

  if ! read -r -p "${prompt}" count; then
    err 'no input, aborting'
  fi
  count="${count:-${default_count:-1}}"

  if [[ ! "${count}" =~ ^[1-9][0-9]*$ ]]; then
    err 'number of workers must be a positive integer'
  fi

  printf '%s\n' "${count}"
}

# Disable and delete the earlier single-instance unit before the template
# instances start, so only one set of workers consumes the queue.
remove_legacy_unit() {
  if [[ ! -f "${LEGACY_UNIT}" ]]; then
    return
  fi

  info 'removing the previous single-instance unit'
  systemctl disable --now laravel-worker.service || true
  rm -f "${LEGACY_UNIT}"
}

# Write the template unit and start one instance per worker. Unchanged units
# are not restarted, so a re-run does not interrupt a running job.
configure_workers() {
  local laravel_dir="$1"
  local worker_count="$2"
  local php_bin="$3"
  local content=''
  local unit=''
  local link=''
  local index=''
  local i=''
  local unit_changed=0
  local -a links=()

  remove_legacy_unit

  # Keep in sync with install.sh. StartLimitIntervalSec=0 disables systemd's
  # start rate limit, so a database outage cannot end in the "failed" state;
  # RestartSec=5 spaces the retries instead. TimeoutStopSec is longer than the
  # longest job, so a running job finishes before SIGKILL.
  content="$(cat <<UNIT
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
)"

  if [[ ! -f "${UNIT_PATH}" || "$(< "${UNIT_PATH}")" != "${content}" ]]; then
    info "writing ${UNIT_PATH}"
    printf '%s\n' "${content}" > "${UNIT_PATH}"
    unit_changed=1
  else
    info "${UNIT_PATH} unchanged"
  fi

  systemctl daemon-reload

  # A lower count must not leave workers behind: disable every enabled
  # instance above the requested count. The wanted-by symlinks are the exact
  # set of instances that would start on boot.
  mapfile -t links < <(compgen -G '/etc/systemd/system/multi-user.target.wants/laravel-worker@*.service' || true)
  for link in "${links[@]}"; do
    unit="$(basename "${link}")"
    index="${unit#laravel-worker@}"
    index="${index%.service}"
    # 10# avoids treating a zero-padded instance number as octal.
    if [[ "${index}" =~ ^[0-9]+$ ]] && (( 10#${index} > worker_count )); then
      info "removing surplus worker ${unit}"
      systemctl disable --now "${unit}" || true
    fi
  done

  # A changed unit only takes effect after a restart; an unchanged one is
  # enabled and started when it is not active yet.
  for ((i = 1; i <= worker_count; i++)); do
    unit="laravel-worker@${i}.service"
    systemctl enable "${unit}"
    if (( unit_changed )); then
      systemctl restart "${unit}"
    else
      systemctl start "${unit}"
    fi
  done
}

# Fail when any instance is not running after the start, and print the unit
# journal for the first failing one.
verify_workers() {
  local worker_count="$1"
  local unit=''
  local i=''

  for ((i = 1; i <= worker_count; i++)); do
    unit="laravel-worker@${i}.service"
    if ! systemctl is-active --quiet "${unit}"; then
      journalctl --unit "${unit}" --lines=20 --no-pager >&2 || true
      err "${unit} is not running"
    fi
  done

  info "${worker_count} queue worker(s) active"
}

# Install the scheduler entry and keep unrelated root cron lines. Only lines
# containing `artisan schedule:run` are replaced, so a previous entry for
# another directory does not survive next to the new one.
install_schedule_cron() {
  local laravel_dir="$1"
  local php_bin="$2"
  local entry=''
  local current=''
  local kept=''
  local tmp=''

  # %q quotes the directory for the shell cron runs, and the absolute php path
  # keeps cron's minimal PATH out of the picture.
  printf -v entry '* * * * * cd %q && %q artisan schedule:run >> /dev/null 2>&1' \
    "${laravel_dir}" "${php_bin}"

  current="$(crontab -l 2> /dev/null || true)"
  kept="$(printf '%s\n' "${current}" | grep -Fv 'artisan schedule:run' || true)"

  tmp="$(mktemp)"
  trap 'rm -f "${tmp}"' RETURN
  {
    if [[ -n "${kept}" ]]; then
      printf '%s\n' "${kept}"
    fi
    printf '%s\n' "${entry}"
  } > "${tmp}"
  crontab "${tmp}"

  info 'scheduler cron entry installed'
}

# Stop and delete the Supervisor program. The systemd instances must already
# be running at this point.
remove_supervisor_program() {
  if [[ ! -f "${SUPERVISOR_CONF}" ]]; then
    info "no Supervisor program at ${SUPERVISOR_CONF}"
    return
  fi

  info "stopping and removing ${SUPERVISOR_PROGRAM} from Supervisor"
  if command -v supervisorctl > /dev/null 2>&1; then
    supervisorctl stop "${SUPERVISOR_PROGRAM}:*" > /dev/null 2>&1 || true
  fi
  rm -f "${SUPERVISOR_CONF}"
  if command -v supervisorctl > /dev/null 2>&1; then
    supervisorctl reread > /dev/null 2>&1 || true
    supervisorctl update > /dev/null 2>&1 || true
  fi
}

# Purge Supervisor once the systemd instances run. The default is yes when it
# manages nothing else; when other programs are left, the prompt warns that
# purging stops them and defaults to no.
maybe_purge_supervisor() {
  local answer=''
  local prompt='Purge supervisor? [Y/n] '
  local default_answer='y'
  local -a other_programs=()

  if ! dpkg -s supervisor > /dev/null 2>&1; then
    info 'supervisor not installed'
    return
  fi

  mapfile -t other_programs < <(compgen -G '/etc/supervisor/conf.d/*.conf' || true)
  if (( ${#other_programs[@]} > 0 )); then
    printf 'supervisor still manages: %s\n' "${other_programs[*]}" >&2
    prompt='Purging supervisor stops these programs. Purge anyway? [y/N] '
    default_answer='n'
  fi

  if ! read -r -p "${prompt}" answer; then
    answer="${default_answer}"
  fi
  answer="${answer:-${default_answer}}"
  if [[ ! "${answer}" =~ ^[Yy]$ ]]; then
    info 'keeping supervisor, only the Laravel program was removed'
    return
  fi

  info 'purging supervisor'
  systemctl stop supervisor.service 2> /dev/null || true
  DEBIAN_FRONTEND=noninteractive apt-get purge -y supervisor
  # Purge leaves custom configuration in place.
  rm -rf /etc/supervisor
}

# Report the result of the migration.
print_summary() {
  local laravel_dir="$1"
  local worker_count="$2"

  info "queue workers: ${worker_count} systemd instance(s) for ${laravel_dir}"
  info 'scheduler: root cron entry for php artisan schedule:run every minute'
  if dpkg -s supervisor > /dev/null 2>&1; then
    info 'supervisor: still installed'
  else
    info 'supervisor: removed'
  fi
  systemctl --no-pager --plain list-units 'laravel-worker@*.service' || true
}

main() {
  local laravel_dir=''
  local worker_count=''
  local php_bin=''

  require_root
  require_ubuntu_2404
  require_runtime

  # Ask up front so a wrong application path fails before the host changes.
  laravel_dir="$(prompt_laravel_dir)"
  worker_count="$(prompt_worker_count)"
  php_bin="$(command -v php)" || err 'php not found in PATH'

  # Start systemd first, then retire Supervisor: the queue keeps a consumer
  # throughout the migration.
  configure_workers "${laravel_dir}" "${worker_count}" "${php_bin}"
  verify_workers "${worker_count}"

  install_schedule_cron "${laravel_dir}" "${php_bin}"
  remove_supervisor_program
  maybe_purge_supervisor

  print_summary "${laravel_dir}" "${worker_count}"
}

main "$@"
