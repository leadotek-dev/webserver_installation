# TODO

Issues found in `install.sh`, ordered by theme priority: Security, Speed,
Usability. Each entry states the problem, location and proposed fix. Remove an
entry once it is implemented.

## Usability

### 1. Root crontab overwritten

- Location: `install_queue_workers`.
- Problem: `printf ... | crontab -` replaces the whole root crontab, deleting
  unrelated entries the operator may have added.
- Fix: read the current crontab, drop only lines matching
  `artisan schedule:run`, append the new entry, and install the result.
  Preserve an empty crontab case.

### 2. SSH lockout on non-default port

- Location: `configure_firewall`.
- Problem: only `ssh` (port 22) is allowed before `ufw --force enable`. A host
  whose `sshd_config` uses a different `Port` loses remote access on the next
  connection.
- Fix: resolve the effective port with `sshd -T | awk '$1 == "port" {print
  $2}'` (fallback to 22), allow every port found before enabling the
  firewall, and print the allowed ports.
