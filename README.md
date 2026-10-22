# auto-backup-db

Daily PostgreSQL/MySQL backups for multiple apps → gzip → Cloudflare R2 (rclone), with per-app retention, automatic retries, and a self-rotating log. Everything lives in this folder (`/var/www/auto-backup-db`); the only thing outside it is the root crontab line.

| File | Purpose |
|---|---|
| `db-backup.sh` | The backup script |
| `config.json` | Apps, DB credentials, retention, retry settings (**gitignored**, mode 600) |
| `.env` | R2 credentials (**gitignored**, mode 600) |
| `config.example.json`, `.env.example` | Committed templates |
| `logs/db-backup.log` | Log file (rotated automatically) |
| `tmp/` | Per-run scratch dirs, deleted after each run |

## 1. Security first

`/var/www` is normally a web root. Make sure no nginx/Apache vhost serves `/var/www` or this folder, and lock it down:

```bash
sudo chown -R root:root /var/www/auto-backup-db
sudo chmod 700 /var/www/auto-backup-db
```

`config.json` holds DB passwords and `.env` holds R2 keys. Both are gitignored; the script refuses to run if either is readable by group/others.

## 2. Prerequisites

Debian/Ubuntu:
```bash
sudo apt update
sudo apt install -y jq gzip util-linux curl git postgresql-client default-mysql-client
```
RHEL/Alma/Rocky:
```bash
sudo dnf install -y jq gzip util-linux curl git postgresql mysql
```
Install only the client you need (`pg_dump` and/or `mysqldump`). The `pg_dump` major version must be **>=** the server's version.

rclone and a bash >= 4.4 check:
```bash
curl https://rclone.org/install.sh | sudo bash
rclone version && jq --version && bash --version | head -1
```

## 3. Install

```bash
sudo git clone <YOUR_REPO_URL> /var/www/auto-backup-db
cd /var/www/auto-backup-db
sudo cp .env.example .env
sudo cp config.example.json config.json
sudo chmod 600 .env config.json
sudo chmod 700 db-backup.sh
```

> Developing on Windows? Before the first push run `git update-index --chmod=+x db-backup.sh`. `.gitattributes` keeps `*.sh` as LF so bash does not fail with `bad interpreter`.

### R2 credentials → `.env`
Create an R2 API token (Object Read & Write, scoped to your bucket). Fill in `.env`:

| `.env` variable | Value |
|---|---|
| `RCLONE_CONFIG_R2_ACCESS_KEY_ID` | Access Key ID |
| `RCLONE_CONFIG_R2_SECRET_ACCESS_KEY` | Secret Access Key |
| `RCLONE_CONFIG_R2_ENDPOINT` | `https://<ACCOUNT_ID>.r2.cloudflarestorage.com` |
| `R2_BUCKET` | Bucket name |

rclone builds the `r2` remote from these variables, so **no `rclone.conf` is needed**. The "token value" is a Cloudflare API bearer token that rclone's S3 backend does not use. Keep every value in double quotes (the file is sourced by bash).

*Prefer a classic rclone.conf?* Delete the `RCLONE_CONFIG_R2_*` lines from `.env` and create `/root/.config/rclone/rclone.conf` (`chmod 600`):
```ini
[r2]
type = s3
provider = Cloudflare
access_key_id = <ACCESS_KEY_ID>
secret_access_key = <SECRET_ACCESS_KEY>
endpoint = https://<ACCOUNT_ID>.r2.cloudflarestorage.com
acl = private
no_check_bucket = true
```

### Apps → `config.json`
One entry per app. Each has its own `retention_days`.

| Field | Notes |
|---|---|
| `name` | Folder name in R2 (`[A-Za-z0-9._-]+`), unique |
| `enabled` | `false` skips the app (default `true`) |
| `db_type` | `postgresql` or `mysql` |
| `host`, `port`, `user`, `password` | Empty `password` = rely on socket/peer auth |
| `databases` | One or more database names |
| `retention_days` | Integer >= 1; remote backups older than this are deleted |
| `extra_dump_args` | Extra `pg_dump` / `mysqldump` flags, e.g. `["--exclude-table=sessions"]` |
| `os_user` | PostgreSQL only: run `pg_dump` as this OS user, e.g. `"postgres"` (peer auth) |

`global` settings: `remote_base_path` (prefix inside the bucket), `tmp_dir`, `log_file`, `log_max_size_mb`, `log_keep`, `retry.*`, `rclone_extra_args`. Relative paths are relative to this folder.

Remote layout: `r2:<bucket>/<remote_base_path>/<app>/<database>/<database>_YYYYmmdd-HHMMSS.sql.gz`

### Least-privilege DB users
```sql
-- PostgreSQL 14+ (run as superuser)
CREATE ROLE app_a_backup LOGIN PASSWORD '...';
GRANT pg_read_all_data TO app_a_backup;

-- MySQL / MariaDB
CREATE USER 'app_b_backup'@'127.0.0.1' IDENTIFIED BY '...';
GRANT SELECT, SHOW VIEW, TRIGGER, LOCK TABLES, EVENT, PROCESS ON *.* TO 'app_b_backup'@'127.0.0.1';
```
PostgreSQL must allow the user in `pg_hba.conf` for the given host (e.g. `host all app_a_backup 127.0.0.1/32 scram-sha-256`).

## 4. Test

```bash
cd /var/www/auto-backup-db

# R2 reachable? (list the bucket itself; `rclone lsd r2:` returns 403 with a
# bucket-scoped token because listing ALL buckets needs an account-level token)
set -a; . ./.env; set +a
rclone lsf "r2:$R2_BUCKET"

# Syntax check, then a dry run (dumps locally; rclone uploads/deletes nothing)
bash -n db-backup.sh
sudo ./db-backup.sh --dry-run

# Real run for a single app, then verify in R2
sudo ./db-backup.sh --app app-a
rclone ls "r2:$R2_BUCKET/db-backups/"
```

## 5. Daily cron

```bash
sudo crontab -e
```
```cron
# Every day at 02:30. The script writes its own log, so cron output is discarded.
30 2 * * * /var/www/auto-backup-db/db-backup.sh >/dev/null 2>&1
```

## 6. Logs

```bash
tail -f /var/www/auto-backup-db/logs/db-backup.log     # live
grep -E 'ERROR|WARN' /var/www/auto-backup-db/logs/db-backup.log
grep 'RUN END' /var/www/auto-backup-db/logs/db-backup.log | tail   # one summary line per run
```
Format: `2026-10-23T02:30:00+0700 [LEVEL] [app/database] message`. When the log passes `log_max_size_mb` it rotates to `db-backup.log.1` … `.N` (`log_keep` files); no logrotate config needed.

## 7. Retries and failure handling

- **Automatic retry:** dump, upload and retention-prune are each retried up to `retry.max_attempts` times (default 3) with exponential backoff (30s, 60s, …). rclone also retries internally (`--retries`, `--low-level-retries`).
- **If a database still fails:** it is logged as `ERROR`, the other apps/databases continue, and the script exits `1`.
- **Retention safety:** an app's old backups are pruned only when *all* of its databases backed up successfully in that run, so a broken app never loses its last good backups.
- **Alerts:** set `NOTIFY_WEBHOOK_URL` in `.env` (Slack/Discord/healthchecks.io) to get a message on failure.
- **Next attempt:** cron runs again the next day. To re-run now: `sudo ./db-backup.sh --app <name>`.
- Concurrent runs are blocked by a lock (`tmp/.db-backup.lock`).

## 8. Restore

```bash
# list, then stream straight into the database
rclone lsf "r2:$R2_BUCKET/db-backups/my-server/app-a/app_a_prod/"
rclone cat "r2:$R2_BUCKET/db-backups/my-server/app-a/app_a_prod/app_a_prod_20261023-023001.sql.gz" | gunzip | psql -h 127.0.0.1 -U postgres app_a_prod
rclone cat "r2:$R2_BUCKET/db-backups/my-server/app-b/app_b_prod/app_b_prod_20261023-023015.sql.gz" | gunzip | mysql -u root -p app_b_prod
```
Restore into a scratch database first and check it before touching production.

## 9. Updating

```bash
cd /var/www/auto-backup-db && sudo git pull
```
`.env`, `config.json`, logs and `tmp/` are gitignored and untouched.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `... is accessible by group/others` | `chmod 600 .env config.json` |
| `bad interpreter: /usr/bin/env: 'bash\r'` | CRLF line endings: `sed -i 's/\r$//' db-backup.sh` |
| `pg_dump: error: aborting because of server version mismatch` | Install a `postgresql-client` matching the server's major version |
| R2 `403` / `AccessDenied` | Check the token has Object Read & Write on the bucket; keep `RCLONE_CONFIG_R2_NO_CHECK_BUCKET="true"` |
| `rclone lsd r2:` → 403 `ListBuckets` Access Denied | Expected with a bucket-scoped token; test with `rclone lsf "r2:$R2_BUCKET"` instead |
| `Cannot reach r2:<bucket>` | Verify endpoint (`https://<ACCOUNT_ID>.r2.cloudflarestorage.com`), keys and `R2_BUCKET`; test with `rclone lsf "r2:$R2_BUCKET"` |
| `NOTICE: Config file ... rclone.conf not found` | Harmless (remote comes from `.env`); `RCLONE_CONFIG="/dev/null"` in `.env` silences it |
| MySQL `Access denied` / PostgreSQL `no pg_hba.conf entry` | Check the backup user's host and grants / `pg_hba.conf` |
| `Another db-backup run is already in progress` | A previous run is still going; check `ps aux \| grep db-backup` |
