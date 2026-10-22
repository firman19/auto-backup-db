#!/usr/bin/env bash
#
# db-backup.sh - Multi-app PostgreSQL/MySQL backup to Cloudflare R2 (via rclone)
#
# For every enabled app in config.json:
#   1. dump each database (pg_dump / mysqldump) and gzip it     (retried on failure)
#   2. verify the archive (gzip -t, non-empty)
#   3. upload it to R2 with rclone                              (retried on failure)
#   4. prune remote backups older than the app's retention_days (only if step 1-3
#      succeeded for ALL of the app's databases, so a broken app never loses its
#      last good backups)
#
# Usage:  ./db-backup.sh [--config FILE] [--env FILE] [--app NAME] [--dry-run] [--help]
# Exit:   0 = everything OK, 1 = at least one failure, 2 = bad usage / config
#
set -euo pipefail
umask 077

# --------------------------------------------------------------------------- #
# Paths and defaults
# --------------------------------------------------------------------------- #
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$BASE_DIR/config.json"
ENV_FILE="$BASE_DIR/.env"
ONLY_APP=""
DRY_RUN=0

RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
CTX="main"            # log context, e.g. "app-b/app_b_prod"
WORK_DIR=""
LOG_FILE=""
OK_COUNT=0
FAIL_COUNT=0
FAILED_ITEMS=()

# --------------------------------------------------------------------------- #
# Helpers: output, logging, errors
# --------------------------------------------------------------------------- #
usage() {
  sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

# Used before the log file is ready (argument / config errors).
die() { echo "ERROR: $*" >&2; exit 2; }

# log LEVEL MESSAGE   -> "2026-10-23T02:30:00+07:00 [INFO] [ctx] message"
log() {
  local level=$1; shift
  local line
  line="$(date +%Y-%m-%dT%H:%M:%S%z) [$level] [$CTX] $*"
  if [[ -n "$LOG_FILE" ]]; then
    printf '%s\n' "$line" | tee -a "$LOG_FILE" >&2
  else
    printf '%s\n' "$line" >&2
  fi
}

# Rotate log_file -> log_file.1 ... log_file.N when it exceeds the size limit.
rotate_log() {
  [[ -f "$LOG_FILE" ]] || return 0
  local max=$(( LOG_MAX_MB * 1024 * 1024 )) size i
  size=$(stat -c %s "$LOG_FILE")
  if (( size < max )); then return 0; fi
  for (( i = LOG_KEEP - 1; i >= 1; i-- )); do
    if [[ -f "$LOG_FILE.$i" ]]; then mv -f "$LOG_FILE.$i" "$LOG_FILE.$((i + 1))"; fi
  done
  mv -f "$LOG_FILE" "$LOG_FILE.1"
}

# POST a failure message to NOTIFY_WEBHOOK_URL (optional, never fatal).
notify() {
  [[ -n "${NOTIFY_WEBHOOK_URL:-}" ]] || return 0
  command -v curl >/dev/null 2>&1 || return 0
  local msg="$1" payload
  payload="$(jq -n --arg m "$msg" '{text: $m, content: $m}')"
  curl -fsS -m 15 -X POST -H 'Content-Type: application/json' \
       -d "$payload" "$NOTIFY_WEBHOOK_URL" >/dev/null 2>&1 \
    || log WARN "Could not deliver notification to webhook"
}

cleanup() {
  # Always return 0 so the original exit status is preserved (and ERR is not re-triggered).
  if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then rm -rf "$WORK_DIR"; fi
  return 0
}
trap cleanup EXIT
trap 'log ERROR "Unexpected error near line $LINENO (exit status $?)"; exit 1' ERR
trap 'log ERROR "Interrupted"; exit 130' INT TERM

# Resolve a path from config: relative paths are relative to the script's folder.
resolve_path() { case "$1" in /*) printf '%s' "$1";; *) printf '%s/%s' "$BASE_DIR" "${1#./}";; esac; }

# True if a file is readable/writable by group or others.
too_open() { local m; m=$(stat -c %a "$1"); [[ "${m: -2}" != "00" ]]; }

# --------------------------------------------------------------------------- #
# retry LABEL CMD...  - retry a command with exponential backoff
#   uses RETRY_MAX / RETRY_DELAY / RETRY_BACKOFF (from config.global.retry)
# --------------------------------------------------------------------------- #
retry() {
  local label=$1; shift
  local attempt=1 delay=$RETRY_DELAY
  while true; do
    if "$@"; then return 0; fi
    if (( attempt >= RETRY_MAX )); then
      log ERROR "$label failed after $attempt attempt(s)"
      return 1
    fi
    log WARN "$label failed (attempt $attempt/$RETRY_MAX); retrying in ${delay}s"
    sleep "$delay"
    delay=$(( delay * RETRY_BACKOFF ))
    attempt=$(( attempt + 1 ))
  done
}

# --------------------------------------------------------------------------- #
# Argument parsing
# --------------------------------------------------------------------------- #
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)  CONFIG_FILE="${2:?--config needs a file}"; shift 2 ;;
    --env)     ENV_FILE="${2:?--env needs a file}"; shift 2 ;;
    --app)     ONLY_APP="${2:?--app needs a name}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)         die "Unknown option: $1 (try --help)" ;;
  esac
done

# --------------------------------------------------------------------------- #
# Pre-flight: tools, files, permissions, config validation
# --------------------------------------------------------------------------- #
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  die "bash >= 4.4 required (found $BASH_VERSION)"
fi
for t in jq rclone gzip flock stat; do
  command -v "$t" >/dev/null 2>&1 || die "Required tool not found: $t"
done

[[ -f "$CONFIG_FILE" ]] || die "Config not found: $CONFIG_FILE (copy config.example.json)"
[[ -f "$ENV_FILE" ]]    || die "Env file not found: $ENV_FILE (copy .env.example)"
jq -e . "$CONFIG_FILE" >/dev/null 2>&1 || die "Config is not valid JSON: $CONFIG_FILE"

# Both files contain secrets: refuse to run if group/other can access them.
for f in "$CONFIG_FILE" "$ENV_FILE"; do
  if too_open "$f"; then die "$f is accessible by group/others; run: chmod 600 $f"; fi
done

# Structural validation (prints one message per problem).
validation_errors="$(jq -r '
  def nonempty_string: type == "string" and length > 0;
  [
    (if (.global | type) != "object" then "global: missing object" else empty end),
    (if (.global.remote | nonempty_string | not) then "global.remote: required" else empty end),
    (if (.global.remote_base_path | nonempty_string | not) then "global.remote_base_path: required" else empty end),
    (if (.apps | type) != "array" or (.apps | length) == 0 then "apps: must be a non-empty array" else empty end),
    ( (.apps // []) | to_entries[] | .key as $i | .value as $a
      | ( "apps[\($i)] (\($a.name // "?"))" ) as $p
      | (if ($a.name | type) != "string" or ($a.name | test("^[A-Za-z0-9._-]+$") | not)
           then "\($p): name must match [A-Za-z0-9._-]+" else empty end),
        (if ($a.db_type | IN("postgresql", "mysql") | not)
           then "\($p): db_type must be \"postgresql\" or \"mysql\"" else empty end),
        (if ($a.host | nonempty_string | not) then "\($p): host required" else empty end),
        (if ($a.port | type) != "number" then "\($p): port must be a number" else empty end),
        (if ($a.user | nonempty_string | not) then "\($p): user required" else empty end),
        (if ($a.databases | type) != "array" or ($a.databases | length) == 0
              or ([$a.databases[] | (type == "string" and test("^[A-Za-z0-9._-]+$"))] | all | not)
           then "\($p): databases must be a non-empty array of names matching [A-Za-z0-9._-]+" else empty end),
        (if ($a.retention_days | type) != "number" or $a.retention_days < 1
              or $a.retention_days != ($a.retention_days | floor)
           then "\($p): retention_days must be an integer >= 1" else empty end),
        (if ($a.os_user // "") != "" and $a.db_type != "postgresql"
           then "\($p): os_user is only supported for postgresql" else empty end)
    ),
    ( [(.apps // [])[] | .name] | group_by(.) | map(select(length > 1) | .[0])[]
      | "duplicate app name: \(.)" )
  ] | .[]' "$CONFIG_FILE")" || die "Config validation failed to run"
if [[ -n "$validation_errors" ]]; then
  echo "Invalid config $CONFIG_FILE:" >&2
  while IFS= read -r l; do echo "  - $l" >&2; done <<<"$validation_errors"
  exit 2
fi

cfg() { jq -r "$1" "$CONFIG_FILE"; }   # read a value from config.json

REMOTE="$(cfg '.global.remote')"
REMOTE_BASE="$(cfg '.global.remote_base_path | sub("^/+"; "") | sub("/+$"; "")')"
TMP_DIR="$(resolve_path "$(cfg '.global.tmp_dir // "./tmp"')")"
LOG_FILE="$(resolve_path "$(cfg '.global.log_file // "./logs/db-backup.log"')")"
LOG_MAX_MB="$(cfg '.global.log_max_size_mb // 10')"
LOG_KEEP="$(cfg '.global.log_keep // 5')"
RETRY_MAX="$(cfg '.global.retry.max_attempts // 3')"
RETRY_DELAY="$(cfg '.global.retry.delay_seconds // 30')"
RETRY_BACKOFF="$(cfg '.global.retry.backoff_multiplier // 2')"
mapfile -t RCLONE_EXTRA < <(cfg '.global.rclone_extra_args // [] | .[]')

DRY=()
if (( DRY_RUN )); then DRY=(--dry-run); fi

mkdir -p "$TMP_DIR" "$(dirname "$LOG_FILE")"
rotate_log

# Secrets (R2 credentials) are loaded after the permission check above.
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a
: "${R2_BUCKET:?R2_BUCKET is not set in $ENV_FILE}"

# Only one run at a time (a slow upload must not overlap the next cron run).
exec 9>"$TMP_DIR/.db-backup.lock"
if ! flock -n 9; then
  log ERROR "Another db-backup run is already in progress; exiting"
  exit 1
fi

WORK_DIR="$(mktemp -d "$TMP_DIR/run.XXXXXX")"
RUN_START=$SECONDS
log INFO "RUN START id=$RUN_ID dry_run=$DRY_RUN config=$CONFIG_FILE"

# Pick the apps to process.
mapfile -t APP_INDEXES < <(jq -r --arg only "$ONLY_APP" '
  .apps | to_entries[]
  | select(.value.enabled != false)
  | select($only == "" or .value.name == $only)
  | .key' "$CONFIG_FILE")
if (( ${#APP_INDEXES[@]} == 0 )); then
  if [[ -n "$ONLY_APP" ]]; then log ERROR "No enabled app named '$ONLY_APP'"; else log ERROR "No enabled apps in config"; fi
  exit 2
fi

# Cheap connectivity check before dumping anything.
CTX="preflight"
if ! retry "R2 connectivity check" rclone lsf "$REMOTE:$R2_BUCKET" --max-depth 1 "${RCLONE_EXTRA[@]}" >/dev/null; then
  log ERROR "Cannot reach $REMOTE:$R2_BUCKET - check .env credentials/endpoint"
  notify "db-backup $(hostname): cannot reach R2 bucket $R2_BUCKET"
  exit 1
fi

# --------------------------------------------------------------------------- #
# Dump / upload
# --------------------------------------------------------------------------- #
# Per-app values, filled in by load_app().
APP_JSON=""; A_NAME=""; A_TYPE=""; A_HOST=""; A_PORT=""; A_USER=""; A_PASS=""
A_OSUSER=""; A_RETENTION=""; A_DBS=(); A_EXTRA=(); A_MYCNF=""

load_app() {
  APP_JSON="$(jq -c ".apps[$1]" "$CONFIG_FILE")"
  aj() { jq -r "$1" <<<"$APP_JSON"; }
  A_NAME="$(aj .name)";           A_TYPE="$(aj .db_type)"
  A_HOST="$(aj .host)";           A_PORT="$(aj .port)"
  A_USER="$(aj .user)";           A_PASS="$(aj '.password // ""')"
  A_OSUSER="$(aj '.os_user // ""')"
  A_RETENTION="$(aj .retention_days)"
  mapfile -t A_DBS   < <(aj '.databases[]')
  mapfile -t A_EXTRA < <(aj '.extra_dump_args // [] | .[]')
  A_MYCNF=""
}

# MySQL: keep the password off the command line via a private option file.
write_mysql_cnf() {
  local pw=${A_PASS//\\/\\\\}; pw=${pw//\"/\\\"}
  A_MYCNF="$WORK_DIR/mysql-$A_NAME.cnf"
  ( umask 077
    {
      echo "[client]"
      echo "user=\"$A_USER\""
      echo "password=\"$pw\""
      echo "host=\"$A_HOST\""
      echo "port=$A_PORT"
    } > "$A_MYCNF" )
}

# Run a dump command; the Postgres password is exported only inside this
# (pipeline) subshell, so it never appears on a command line or in other processes' env.
run_dump_cmd() {
  if [[ "$A_TYPE" == "postgresql" && -n "$A_PASS" ]]; then export PGPASSWORD="$A_PASS"; fi
  "$@"
}

# One dump attempt: <db> <partial-file>. Fails if the dump, gzip or verification fails.
dump_once() {
  local db=$1 out=$2 err="$WORK_DIR/dump.err"
  local -a cmd=()
  rm -f "$out" "$err"

  if [[ "$A_TYPE" == "postgresql" ]]; then
    if [[ -n "$A_OSUSER" ]]; then cmd+=(runuser -u "$A_OSUSER" --); fi
    cmd+=(pg_dump -h "$A_HOST" -p "$A_PORT" -U "$A_USER" --no-password
          --format=plain --no-owner --clean --if-exists "${A_EXTRA[@]}" "$db")
  else
    local -a gtid=()
    if mysqldump --help 2>/dev/null | grep -q -- '--set-gtid-purged'; then gtid=(--set-gtid-purged=OFF); fi
    cmd+=(mysqldump "--defaults-extra-file=$A_MYCNF" --single-transaction --quick
          --routines --triggers --events --hex-blob "${gtid[@]}" "${A_EXTRA[@]}" "$db")
  fi

  if ! run_dump_cmd "${cmd[@]}" 2>"$err" | gzip -6 > "$out"; then
    log ERROR "Dump command failed: $(tail -n 5 "$err" 2>/dev/null | tr '\n' ' ')"
    rm -f "$out"
    return 1
  fi
  if ! gzip -t "$out" 2>/dev/null; then
    log ERROR "Archive failed gzip integrity test"; rm -f "$out"; return 1
  fi
  if (( $(stat -c %s "$out") <= 20 )); then   # a gzip of empty input is ~20 bytes
    log ERROR "Dump is empty"; rm -f "$out"; return 1
  fi
}

# Back up one database. Returns 0 on success, 1 on failure.
backup_db() {
  local db=$1 ts file partial remote_path size t0=$SECONDS
  CTX="$A_NAME/$db"
  ts="$(date +%Y%m%d-%H%M%S)"
  file="${db}_${ts}.sql.gz"
  partial="$WORK_DIR/$file.partial"
  remote_path="$REMOTE:$R2_BUCKET/$REMOTE_BASE/$A_NAME/$db/$file"

  log INFO "Dumping ($A_TYPE) ..."
  retry "Dump" dump_once "$db" "$partial" || return 1
  mv "$partial" "$WORK_DIR/$file" || return 1

  size="$(stat -c %s "$WORK_DIR/$file" | awk '{printf "%.1fMB", $1/1048576}')"
  log INFO "Dump OK ($size), uploading to $remote_path"
  if ! retry "Upload" rclone copyto "$WORK_DIR/$file" "$remote_path" \
         "${RCLONE_EXTRA[@]}" "${DRY[@]}"; then
    rm -f "$WORK_DIR/$file"
    return 1
  fi
  rm -f "$WORK_DIR/$file"
  log INFO "Uploaded in $(( SECONDS - t0 ))s"
}

# One prune attempt; rclone's -v output is forwarded into our log.
prune_once() {
  rclone delete "$REMOTE:$R2_BUCKET/$REMOTE_BASE/$A_NAME"         --min-age "${A_RETENTION}d" --include '*.sql.gz' -v         "${RCLONE_EXTRA[@]}" "${DRY[@]}" 2>&1     | while IFS= read -r l; do log INFO "rclone: $l"; done
  # pipefail: the function's status is rclone's, not the while loop's
}

# Delete remote backups of this app older than retention_days.
prune_app() {
  CTX="$A_NAME"
  log INFO "Pruning remote backups older than ${A_RETENTION}d"
  retry "Retention prune" prune_once
}

# --------------------------------------------------------------------------- #
# Main loop
# --------------------------------------------------------------------------- #
for idx in "${APP_INDEXES[@]}"; do
  load_app "$idx"
  CTX="$A_NAME"
  log INFO "App start: type=$A_TYPE databases=${#A_DBS[@]} retention=${A_RETENTION}d"

  # Verify the dump tool exists for this app.
  tool=$([[ "$A_TYPE" == "postgresql" ]] && echo pg_dump || echo mysqldump)
  if ! command -v "$tool" >/dev/null 2>&1; then
    log ERROR "$tool not installed; skipping app"
    FAIL_COUNT=$(( FAIL_COUNT + ${#A_DBS[@]} )); FAILED_ITEMS+=("$A_NAME/*")
    continue
  fi
  if [[ "$A_TYPE" == "mysql" ]]; then write_mysql_cnf; fi

  app_ok=1
  for db in "${A_DBS[@]}"; do
    if backup_db "$db"; then
      OK_COUNT=$(( OK_COUNT + 1 ))
    else
      FAIL_COUNT=$(( FAIL_COUNT + 1 )); FAILED_ITEMS+=("$A_NAME/$db"); app_ok=0
      log ERROR "FAILED after all retries"
    fi
  done

  CTX="$A_NAME"
  if (( app_ok )); then
    if ! prune_app; then
      FAIL_COUNT=$(( FAIL_COUNT + 1 )); FAILED_ITEMS+=("$A_NAME/(retention)")
    fi
  else
    log WARN "Skipping retention prune because a backup failed (keeping existing backups)"
  fi
  if [[ -n "$A_MYCNF" ]]; then rm -f "$A_MYCNF"; fi
done

# --------------------------------------------------------------------------- #
# Summary
# --------------------------------------------------------------------------- #
CTX="summary"
elapsed=$(( SECONDS - RUN_START ))
if (( FAIL_COUNT > 0 )); then
  log ERROR "RUN END id=$RUN_ID ok=$OK_COUNT failed=$FAIL_COUNT duration=${elapsed}s failed_items=${FAILED_ITEMS[*]}"
  notify "db-backup $(hostname): $FAIL_COUNT failure(s): ${FAILED_ITEMS[*]} (see $LOG_FILE)"
  exit 1
fi
log INFO "RUN END id=$RUN_ID ok=$OK_COUNT failed=0 duration=${elapsed}s"
exit 0
