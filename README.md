# vps-service-watchdog

A tiny bash watchdog that keeps your systemd services alive: it checks the services in your config file, restarts any that are down, and alerts you when a service will not stay up.

## Why this instead of systemd's own `Restart=always`?

Systemd restart policies are per-unit and silent. The watchdog gives you:

- **One place to watch everything** — nginx, PHP-FPM, MySQL, Redis, Postfix in a single list
- **Restart caps** — a broken service is restarted at most N times per hour, so it cannot spin in a restart loop forever
- **Alerts** — a log line and (optionally) an email on every restart and every failure
- **A dry-run mode** — `--check-only` reports what is down without touching anything

## Install

```bash
sudo mkdir -p /etc/service-watchdog /var/lib/service-watchdog
sudo cp watchdog.sh /usr/local/bin/watchdog
sudo chmod +x /usr/local/bin/watchdog
sudo cp services.conf.example /etc/service-watchdog/services.conf
# edit the list to match your server:
sudo nano /etc/service-watchdog/services.conf
```

## Config

One service per line; `#` starts a comment. An optional `:N` suffix caps restarts for that service to N per hour (default 3).

```
nginx
php8.2-fpm
mysql
redis-server:5
postfix
```

## Run it

```bash
# Once, from cron every 5 minutes:
*/5 * * * * root /usr/local/bin/watchdog --to you@example.com

# Or as a loop (e.g. from a systemd unit):
/usr/local/bin/watchdog --interval 60 --to you@example.com

# Dry run — report only:
watchdog --check-only

# Custom paths:
watchdog --config ./services.conf --state-dir ./state --log ./watchdog.log
```

Email alerts need a working `mail` command (Postfix/sendmail installed).

## Exit codes

| Code | Meaning |
|---|---|
| 0 | All services healthy, or every down service restarted successfully |
| 1 | At least one service is still down (restart failed or cap reached) |
| 2 | Config/environment error (no systemd, unreadable config, unwritable state/log) |

A lock file prevents overlapping runs from restarting the same service twice.

## License

MIT — see [LICENSE](LICENSE).
