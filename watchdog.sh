
#!/bin/sh
# watchdog.sh v2 - Minecraft Snapshot Watchdog
# Pterodactyl-compatible server supervisor and automatic updater.
#
# Requirements:
# java, curl, jq, sha1sum, awk, tar, grep, find, dirname, sed
# coreutils and a POSIX-compatible shell.

umask 077

# -----------------------------------------------------------------------------
# CONFIGURATION
# All settings can be overridden using environment variables.
# -----------------------------------------------------------------------------

SERVER_JAR="${SERVER_JAR:-server.jar}"
MANIFEST_URL="${MANIFEST_URL:-https://launchermeta.mojang.com/mc/game/version_manifest.json}"

UPDATE_CHANNEL="${UPDATE_CHANNEL:-snapshot}"  # snapshot or release
UPDATE_INTERVAL="${UPDATE_INTERVAL:-3600}"
RESTART_COUNTDOWN="${RESTART_COUNTDOWN:-60}"
STOP_TIMEOUT="${STOP_TIMEOUT:-180}"
STARTUP_GRACE_SECONDS="${STARTUP_GRACE_SECONDS:-120}"
KEEP_BACKUP="${KEEP_BACKUP:-1}"

JAVA_BIN="${JAVA_BIN:-java}"
JAVA_XMS="${JAVA_XMS:-128M}"
JAVA_MAX_RAM_PERCENTAGE="${JAVA_MAX_RAM_PERCENTAGE:-80.0}"

MCRCON_BIN="${MCRCON_BIN:-./mcrcon}"
MCRCON_VERSION="${MCRCON_VERSION:-0.7.2}"
MCRCON_URL="${MCRCON_URL:-https://github.com/Tiiffi/mcrcon/releases/download/v${MCRCON_VERSION}/mcrcon-${MCRCON_VERSION}-linux-x86-64.tar.gz}"
MCRCON_SHA256="${MCRCON_SHA256:-}"

RCON_HOST="${RCON_HOST:-}"
RCON_PORT="${RCON_PORT:-}"
RCON_PASS="${RCON_PASS:-}"

WEBHOOK="${WEBHOOK:-}"
DISCORD_ROLE_ID="${DISCORD_ROLE_ID-}"

# -----------------------------------------------------------------------------
# RUNTIME PATHS
# -----------------------------------------------------------------------------

BACKUP_JAR="${SERVER_JAR}.bak"
DOWNLOAD_TMP="${SERVER_JAR}.download.$$"
BACKUP_TMP="${BACKUP_JAR}.tmp.$$"

PID_FILE="${SERVER_JAR}.watchdog.pid"
LOCK_DIR="${SERVER_JAR}.update.lock"

UPDATE_PENDING="${SERVER_JAR}.update_pending"
UPDATE_RESTART="${SERVER_JAR}.update_restart"
UPDATE_ABORT="${SERVER_JAR}.update_abort"
UPDATE_NEW_JAR="${SERVER_JAR}.update_new_jar"

TMP_DIR="${TMPDIR:-/tmp}/mc-watchdog.$$"

JAVA_PID=""
WATCHDOG_PID=""

SHUTTING_DOWN=0
BOOTSTRAP_UPDATED=0
ROLLBACK_ELIGIBLE=0

# -----------------------------------------------------------------------------
# LOGGING
# -----------------------------------------------------------------------------

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fail() {
    log "ERROR: $*"
    exit 1
}

is_uint() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

# -----------------------------------------------------------------------------
# DEPENDENCY CHECKS
# -----------------------------------------------------------------------------

# Install jq locally if it is not already available.
if ! command -v jq >/dev/null 2>&1; then
    JQ_DIR="${HOME:-/home/container}/.local/bin"
    JQ_BIN="$JQ_DIR/jq"

    mkdir -p "$JQ_DIR" || exit 1

    case "$(uname -m)" in
        x86_64|amd64)
            JQ_ASSET="jq-linux-amd64"
            JQ_SHA256="b1c22172dd303f3be49e935aa56aa48a8b7a46e0bc838b4997d3bb451495870f"
            ;;
        aarch64|arm64)
            JQ_ASSET="jq-linux-arm64"
            JQ_SHA256="8b85c817833814ddca00a144c33705546355afccf0cf39b188f3cdb48b852309"
            ;;
        *)
            printf '%s\n' "ERROR: Unsupported CPU architecture for jq."
            exit 1
            ;;
    esac

    JQ_TMP="$JQ_BIN.download.$$"

    printf '%s\n' "jq is missing. Downloading it..."

    if ! curl -fsSL --retry 3 \
        "https://github.com/jqlang/jq/releases/download/jq-1.8.2/$JQ_ASSET" \
        -o "$JQ_TMP"; then
        rm -f "$JQ_TMP"
        printf '%s\n' "ERROR: Could not download jq."
        exit 1
    fi

    if ! printf '%s  %s\n' "$JQ_SHA256" "$JQ_TMP" | sha256sum -c - >/dev/null 2>&1; then
        rm -f "$JQ_TMP"
        printf '%s\n' "ERROR: jq checksum verification failed."
        exit 1
    fi

    chmod 700 "$JQ_TMP"
    mv "$JQ_TMP" "$JQ_BIN" || exit 1

    printf '%s\n' "jq installed successfully."
fi

PATH="${HOME:-/home/container}/.local/bin:$PATH"
export PATH



check_dependencies() {
    for dependency in curl jq sha1sum awk tar grep find dirname chmod cp mv rm mkdir sleep cat date uname sed; do
        if ! command -v "$dependency" >/dev/null 2>&1; then
            log "ERROR: Required command not found: $dependency"
            return 1
        fi
    done

    if ! command -v "$JAVA_BIN" >/dev/null 2>&1; then
        log "ERROR: Java executable not found: $JAVA_BIN"
        return 1
    fi

    return 0
}

# -----------------------------------------------------------------------------
# DISCORD NOTIFICATIONS
# -----------------------------------------------------------------------------

send_discord() {
    message="$1"
    ping_role="${2:-0}"

    [ -n "$WEBHOOK" ] || return 0

    role=""

    if [ "$ping_role" = "1" ] && [ -n "$DISCORD_ROLE_ID" ]; then
        message=$(printf '<@&%s>\n%s' "$DISCORD_ROLE_ID" "$message")
        role="$DISCORD_ROLE_ID"
    fi

    payload=$(jq -n \
        --arg content "$message" \
        --arg role "$role" \
        '{
            content: $content,
            allowed_mentions: {
                parse: [],
                roles: (if $role == "" then [] else [$role] end)
            }
        }') || {
        log "WARNING: Could not build Discord notification JSON."
        return 0
    }

    if ! curl -fsS --connect-timeout 10 --max-time 20 \
        -H 'Content-Type: application/json' \
        -d "$payload" "$WEBHOOK" >/dev/null; then

        log "WARNING: Discord notification failed."
    fi

    return 0
}

# -----------------------------------------------------------------------------
# RCON
# -----------------------------------------------------------------------------

send_rcon() {
    if [ -z "$RCON_PASS" ]; then
        log "RCON password is not configured."
        return 1
    fi

    if [ ! -x "$MCRCON_BIN" ]; then
        log "mcrcon is unavailable or not executable: $MCRCON_BIN"
        return 1
    fi

    "$MCRCON_BIN" \
        -H "$RCON_HOST" \
        -P "$RCON_PORT" \
        -p "$RCON_PASS" \
        "$@"
}

# -----------------------------------------------------------------------------
# MCRCON INSTALLATION
# -----------------------------------------------------------------------------

install_mcrcon() {
    if [ -f "$MCRCON_BIN" ] && grep -qi '<html' "$MCRCON_BIN" 2>/dev/null; then
        log "Removing invalid HTML file at $MCRCON_BIN."
        rm -f "$MCRCON_BIN"
    fi

    if [ -x "$MCRCON_BIN" ]; then
        log "Using existing mcrcon binary: $MCRCON_BIN"
        return 0
    fi

    architecture=$(uname -m)

    case "$architecture" in
        x86_64|amd64)
            ;;
        *)
            log "WARNING: Automatic mcrcon download supports x86_64 only (detected $architecture)."
            return 1
            ;;
    esac

    archive="$TMP_DIR/mcrcon.tar.gz"
    extract_dir="$TMP_DIR/mcrcon-extract"
    candidate_tmp="${MCRCON_BIN}.tmp.$$"

    rm -rf "$extract_dir"
    mkdir -p "$extract_dir" || return 1

    log "Downloading mcrcon v$MCRCON_VERSION..."

    if ! curl -fsSL --retry 3 \
        --connect-timeout 10 \
        --max-time 120 \
        -o "$archive" "$MCRCON_URL"; then

        log "WARNING: Could not download mcrcon."
        return 1
    fi

    if ! tar -tzf "$archive" >/dev/null 2>&1; then
        log "WARNING: The mcrcon archive is invalid."
        return 1
    fi

    # Optional SHA-256 verification if a trusted digest is configured.
    if [ -n "$MCRCON_SHA256" ]; then
        if ! command -v sha256sum >/dev/null 2>&1; then
            log "WARNING: sha256sum is unavailable."
            return 1
        fi

        archive_hash_line=$(sha256sum "$archive") || return 1
        archive_sha=$(printf '%s\n' "$archive_hash_line" | awk '{print $1}')

        if [ "$archive_sha" != "$MCRCON_SHA256" ]; then
            log "WARNING: mcrcon archive SHA-256 mismatch."
            return 1
        fi
    fi

    if ! tar -xzf "$archive" -C "$extract_dir"; then
        log "WARNING: Could not extract mcrcon."
        return 1
    fi

    candidate=$(find "$extract_dir" -type f -name mcrcon -print | sed -n '1p')

    if [ -z "$candidate" ] || [ ! -f "$candidate" ]; then
        log "WARNING: mcrcon binary was not present in the archive."
        return 1
    fi

    mkdir -p "$(dirname "$MCRCON_BIN")" || return 1

    rm -f "$candidate_tmp"

    if ! cp "$candidate" "$candidate_tmp" ||
       ! chmod 700 "$candidate_tmp" ||
       ! mv -f "$candidate_tmp" "$MCRCON_BIN"; then

        rm -f "$candidate_tmp"
        log "WARNING: Could not install mcrcon."
        return 1
    fi

    if [ ! -x "$MCRCON_BIN" ]; then
        log "WARNING: Installed mcrcon is not executable."
        return 1
    fi

    log "mcrcon installed successfully."
    return 0
}

# -----------------------------------------------------------------------------
# PROCESS DETECTION
# -----------------------------------------------------------------------------

read_running_pid() {
    [ -f "$PID_FILE" ] || return 1

    pid=$(cat "$PID_FILE" 2>/dev/null)

    case "$pid" in
        ''|*[!0-9]*) return 1 ;;
    esac

    kill -0 "$pid" 2>/dev/null || return 1

    printf '%s' "$pid"
}

pid_is_running() {
    pid="$1"

    case "$pid" in
        ''|*[!0-9]*) return 1 ;;
    esac

    kill -0 "$pid" 2>/dev/null
}

# -----------------------------------------------------------------------------
# SAFE SERVER JAR INSTALLATION
# -----------------------------------------------------------------------------

install_verified_download() {
    if [ -f "$SERVER_JAR" ] && [ "$KEEP_BACKUP" = "1" ]; then

        rm -f "$BACKUP_TMP"

        if ! cp -p "$SERVER_JAR" "$BACKUP_TMP"; then
            log "ERROR: Could not create server backup."
            return 1
        fi

        if ! mv -f "$BACKUP_TMP" "$BACKUP_JAR"; then
            log "ERROR: Could not move backup into place."
            rm -f "$BACKUP_TMP"
            return 1
        fi
    fi

    # Download is stored beside SERVER_JAR.
    # This allows an atomic rename on the same filesystem.

    if ! mv -f "$DOWNLOAD_TMP" "$SERVER_JAR"; then
        log "ERROR: Could not replace server JAR."
        return 1
    fi

    return 0
}

# -----------------------------------------------------------------------------
# UPDATE STATE HELPERS
# -----------------------------------------------------------------------------

abort_online_update() {
    rm -f "$UPDATE_PENDING"
    : > "$UPDATE_ABORT"
}

finish_update_without_restart() {
    if install_verified_download; then
        log "Update installed while the server was offline; it will not be auto-started."
        send_discord "Minecraft server updated to $TARGET_VERSION."
    else
        log "Could not install the update while the server was offline."
    fi

    abort_online_update
    return 0
}

# -----------------------------------------------------------------------------
# JAVA COMPATIBILITY CHECK
# -----------------------------------------------------------------------------

check_java_compatibility() {
    metadata_file="$1"

    required_java=$(jq -r '.javaVersion.majorVersion // empty' "$metadata_file") || return 1

    [ -n "$required_java" ] || return 0

    if ! is_uint "$required_java"; then
        log "WARNING: Invalid required Java version: $required_java"
        return 1
    fi

    java_version_line=$("$JAVA_BIN" -version 2>&1 | sed -n '1p')

    java_version=$(printf '%s\n' "$java_version_line" |
        sed -n 's/.*version "\([^"]*\)".*/\1/p')

    if [ -z "$java_version" ]; then
        java_version=$(printf '%s\n' "$java_version_line" |
            sed 's/^[^0-9]*//')
    fi

    case "$java_version" in
        1.*)
            installed_java=$(printf '%s\n' "$java_version" |
                sed 's/^1\.//; s/[^0-9].*//')
            ;;
        *)
            installed_java=$(printf '%s\n' "$java_version" |
                sed 's/[^0-9].*//')
            ;;
    esac

    if ! is_uint "$installed_java"; then
        log "WARNING: Could not determine installed Java version."
        return 1
    fi

    if [ "$installed_java" -lt "$required_java" ]; then
        log "WARNING: Minecraft $TARGET_VERSION requires Java $required_java+, but Java $installed_java is installed."
        log "Update skipped."
        return 1
    fi

    log "Java compatibility check passed (installed: $installed_java, required: $required_java)."

    return 0
}

# -----------------------------------------------------------------------------
# MAIN UPDATE LOGIC
# -----------------------------------------------------------------------------

do_update_locked() {
    manifest_file="$TMP_DIR/version_manifest.json"
    meta_file="$TMP_DIR/version_metadata.json"

    log "Checking Mojang's $UPDATE_CHANNEL channel..."

    if ! curl -fsSL --retry 3 \
        --connect-timeout 10 \
        --max-time 60 \
        -o "$manifest_file" "$MANIFEST_URL"; then

        log "WARNING: Could not download Minecraft version manifest."
        return 1
    fi

    # Extract latest release or snapshot using jq.

    TARGET_VERSION=$(jq -er --arg channel "$UPDATE_CHANNEL" \
        '.latest[$channel] // empty' "$manifest_file") || {

        log "WARNING: Could not find latest version."
        return 1
    }

    metadata_url=$(jq -er --arg id "$TARGET_VERSION" \
        '[.versions[] | select(.id == $id) | .url][0] // empty' "$manifest_file") || {

        log "WARNING: Could not find metadata URL for $TARGET_VERSION."
        return 1
    }

    if ! curl -fsSL --retry 3 \
        --connect-timeout 10 \
        --max-time 60 \
        -o "$meta_file" "$metadata_url"; then

        log "WARNING: Could not download version metadata."
        return 1
    fi

    SERVER_URL=$(jq -er '.downloads.server.url // empty' "$meta_file") || {
        log "WARNING: Server JAR URL is missing."
        return 1
    }

    EXPECTED_SHA=$(jq -er '.downloads.server.sha1 // empty' "$meta_file") || {
        log "WARNING: Server JAR SHA-1 is missing."
        return 1
    }

    case "$EXPECTED_SHA" in
        *[!0123456789abcdefABCDEF]*|'')
            log "WARNING: Invalid SHA-1 value."
            return 1
            ;;
    esac

    if [ "${#EXPECTED_SHA}" -ne 40 ]; then
        log "WARNING: Unexpected SHA-1 length."
        return 1
    fi

    # Compare installed JAR against Mojang's official checksum.

    CURRENT_SHA=""

    if [ -f "$SERVER_JAR" ]; then
        current_hash_line=$(sha1sum "$SERVER_JAR") || {
            log "WARNING: Could not calculate current JAR checksum."
            return 1
        }

        CURRENT_SHA=$(printf '%s\n' "$current_hash_line" | awk '{print $1}')
    fi

    if [ "$CURRENT_SHA" = "$EXPECTED_SHA" ]; then
        log "Minecraft $TARGET_VERSION is already installed."
        return 0
    fi

    # Check Java only when an actual update is required.

    if ! check_java_compatibility "$meta_file"; then
        return 1
    fi

    log "Update detected: Minecraft $TARGET_VERSION."

    # Determine whether this is an online update.

    RUNNING_PID=$(read_running_pid 2>/dev/null || true)
    ONLINE_UPDATE=0

    if [ -n "$RUNNING_PID" ]; then

        if [ -z "$RCON_PASS" ] || [ ! -x "$MCRCON_BIN" ]; then
            log "Update available, but live updating is disabled because RCON is not configured."
            return 0
        fi

        ONLINE_UPDATE=1

        rm -f "$UPDATE_RESTART" "$UPDATE_ABORT" "$UPDATE_NEW_JAR"
        : > "$UPDATE_PENDING"
    fi

    # Download to a temporary file.

    rm -f "$DOWNLOAD_TMP"

    log "Downloading Minecraft $TARGET_VERSION..."

    if ! curl -fsSL --retry 3 --retry-delay 2 \
        --connect-timeout 10 \
        --max-time 600 \
        -o "$DOWNLOAD_TMP" "$SERVER_URL"; then

        log "WARNING: Minecraft download failed."
        rm -f "$DOWNLOAD_TMP"

        if [ "$ONLINE_UPDATE" = "1" ]; then
            abort_online_update
        fi

        return 1
    fi

    if [ ! -s "$DOWNLOAD_TMP" ]; then
        log "WARNING: Downloaded JAR is empty."
        rm -f "$DOWNLOAD_TMP"

        if [ "$ONLINE_UPDATE" = "1" ]; then
            abort_online_update
        fi

        return 1
    fi

    # Verify downloaded JAR.

    downloaded_hash_line=$(sha1sum "$DOWNLOAD_TMP") || {
        log "WARNING: Could not calculate downloaded JAR checksum."
        rm -f "$DOWNLOAD_TMP"

        if [ "$ONLINE_UPDATE" = "1" ]; then
            abort_online_update
        fi

        return 1
    }

    DOWNLOADED_SHA=$(printf '%s\n' "$downloaded_hash_line" | awk '{print $1}')

    if [ "$DOWNLOADED_SHA" != "$EXPECTED_SHA" ]; then
        log "WARNING: SHA-1 verification failed."
        log "Existing server JAR has NOT been changed."

        rm -f "$DOWNLOAD_TMP"

        if [ "$ONLINE_UPDATE" = "1" ]; then
            abort_online_update
        fi

        return 1
    fi

    log "Download and SHA-1 verification successful."

    # -------------------------------------------------------------------------
    # ONLINE UPDATE
    # -------------------------------------------------------------------------

    if [ "$ONLINE_UPDATE" = "1" ]; then

        # If the server stopped manually during downloading, install the JAR
        # without automatically restarting it.

        if ! pid_is_running "$RUNNING_PID"; then
            finish_update_without_restart
            return 0
        fi

        send_discord \
            "Minecraft $UPDATE_CHANNEL update $TARGET_VERSION is ready. Restarting in ${RESTART_COUNTDOWN} seconds." \
            1

        # Broadcast warning.

        if ! send_rcon "say [Watchdog] Minecraft $TARGET_VERSION is ready. Restarting in ${RESTART_COUNTDOWN} seconds."; then

            if ! pid_is_running "$RUNNING_PID"; then
                finish_update_without_restart
                return 0
            fi

            log "WARNING: Could not broadcast update. Leaving server untouched."

            rm -f "$DOWNLOAD_TMP"
            abort_online_update
            return 1
        fi

        log "Waiting ${RESTART_COUNTDOWN} seconds before stopping Minecraft..."

        sleep "$RESTART_COUNTDOWN"

        if ! pid_is_running "$RUNNING_PID"; then
            finish_update_without_restart
            return 0
        fi

        # Graceful RCON shutdown.

        log "Sending graceful Minecraft stop command..."

        if ! send_rcon "stop"; then
            sleep 3

            if pid_is_running "$RUNNING_PID"; then
                log "WARNING: RCON stop failed. Leaving current JAR untouched."

                rm -f "$DOWNLOAD_TMP"
                abort_online_update
                return 1
            fi
        fi

        # Wait for the actual Java process to exit.

        elapsed=0

        while pid_is_running "$RUNNING_PID"; do

            if [ "$elapsed" -ge "$STOP_TIMEOUT" ]; then
                log "WARNING: Minecraft did not stop within ${STOP_TIMEOUT} seconds."

                rm -f "$DOWNLOAD_TMP"
                abort_online_update
                return 1
            fi

            sleep 2
            elapsed=$((elapsed + 2))
        done

        log "Minecraft has stopped. Installing verified update..."

        if install_verified_download; then

            : > "$UPDATE_NEW_JAR"
            : > "$UPDATE_RESTART"

            rm -f "$UPDATE_PENDING"

            log "Minecraft $TARGET_VERSION installed."
            log "Supervisor will restart the server."

            send_discord "Minecraft server has been updated to $TARGET_VERSION. Restarting now."

            return 0
        fi

        # If installation failed, restart the existing JAR instead of leaving
        # the container offline.

        rm -f "$DOWNLOAD_TMP" "$UPDATE_PENDING"
        : > "$UPDATE_RESTART"

        log "Update installation failed. Restarting existing JAR."

        return 1
    fi

    # -------------------------------------------------------------------------
    # BOOTSTRAP UPDATE
    # Server has not started yet, so no RCON shutdown is needed.
    # -------------------------------------------------------------------------

    if install_verified_download; then

        BOOTSTRAP_UPDATED=1

        log "Minecraft $TARGET_VERSION installed before server startup."

        send_discord "Minecraft server updated to $TARGET_VERSION." 1

        return 0
    fi

    rm -f "$DOWNLOAD_TMP"
    return 1
}

# -----------------------------------------------------------------------------
# UPDATE LOCKING
# -----------------------------------------------------------------------------

do_update() {
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then

        lock_pid=""

        [ -f "$LOCK_DIR/pid" ] &&
            lock_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null)

        case "$lock_pid" in
            ''|*[!0-9]*) lock_pid="" ;;
        esac

        if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
            log "Another update check is running. Skipping."
            return 0
        fi

        rm -rf "$LOCK_DIR"

        if ! mkdir "$LOCK_DIR" 2>/dev/null; then
            log "WARNING: Could not acquire update lock."
            return 1
        fi
    fi

    printf '%s\n' "$$" > "$LOCK_DIR/pid"

    do_update_locked
    result=$?

    rm -rf "$LOCK_DIR"

    return "$result"
}

# -----------------------------------------------------------------------------
# AUTOMATIC ROLLBACK
# -----------------------------------------------------------------------------

rollback_to_backup() {
    [ -f "$BACKUP_JAR" ] || return 1

    failed_jar="${SERVER_JAR}.failed"
    restore_tmp="${SERVER_JAR}.restore.$$"

    if ! cp -p "$BACKUP_JAR" "$restore_tmp"; then
        log "ERROR: Could not stage backup for rollback."
        return 1
    fi

    if [ -f "$SERVER_JAR" ]; then
        mv -f "$SERVER_JAR" "$failed_jar" || {
            rm -f "$restore_tmp"
            return 1
        }
    fi

    if ! mv -f "$restore_tmp" "$SERVER_JAR"; then
        rm -f "$restore_tmp"

        if [ -f "$failed_jar" ] && [ ! -f "$SERVER_JAR" ]; then
            mv -f "$failed_jar" "$SERVER_JAR" 2>/dev/null || true
        fi

        log "ERROR: Automatic rollback failed. Backup remains at $BACKUP_JAR."
        return 1
    fi

    return 0
}

# -----------------------------------------------------------------------------
# SHUTDOWN HANDLING
# -----------------------------------------------------------------------------

stop_watchdog() {
    if [ -n "$WATCHDOG_PID" ]; then
        kill "$WATCHDOG_PID" 2>/dev/null || true
        wait "$WATCHDOG_PID" 2>/dev/null || true
        WATCHDOG_PID=""
    fi
}

handle_signal() {
    SHUTTING_DOWN=1

    log "Shutdown signal received. Stopping child processes..."

    signal_java_pid="$JAVA_PID"

    if [ -z "$signal_java_pid" ] && [ -f "$PID_FILE" ]; then
        signal_java_pid=$(cat "$PID_FILE" 2>/dev/null || true)
    fi

    case "$signal_java_pid" in
        ''|*[!0-9]*) ;;
        *) kill -TERM "$signal_java_pid" 2>/dev/null || true ;;
    esac

    if [ -n "$WATCHDOG_PID" ]; then
        kill -TERM "$WATCHDOG_PID" 2>/dev/null || true
    fi
}

# -----------------------------------------------------------------------------
# STARTUP VALIDATION
# -----------------------------------------------------------------------------

case "$UPDATE_CHANNEL" in
    snapshot|release)
        ;;
    *)
        fail "UPDATE_CHANNEL must be snapshot or release."
        ;;
esac

is_uint "$UPDATE_INTERVAL" ||
    fail "UPDATE_INTERVAL must be a non-negative integer."

is_uint "$RESTART_COUNTDOWN" ||
    fail "RESTART_COUNTDOWN must be a non-negative integer."

is_uint "$STOP_TIMEOUT" ||
    fail "STOP_TIMEOUT must be a non-negative integer."

is_uint "$STARTUP_GRACE_SECONDS" ||
    fail "STARTUP_GRACE_SECONDS must be a non-negative integer."

[ "$UPDATE_INTERVAL" -gt 0 ] ||
    fail "UPDATE_INTERVAL must be greater than zero."

[ "$STOP_TIMEOUT" -gt 0 ] ||
    fail "STOP_TIMEOUT must be greater than zero."

[ "$KEEP_BACKUP" = "0" ] || [ "$KEEP_BACKUP" = "1" ] ||
    fail "KEEP_BACKUP must be 0 or 1."

check_dependencies ||
    fail "Missing dependencies. jq is required for Mojang metadata parsing."

mkdir -p "$TMP_DIR" ||
    fail "Could not create temporary directory."

# Clear stale runtime markers from a previous run.

rm -f "$PID_FILE" \
    "$UPDATE_PENDING" \
    "$UPDATE_RESTART" \
    "$UPDATE_ABORT" \
    "$UPDATE_NEW_JAR"

# -----------------------------------------------------------------------------
# BOOTSTRAP UPDATE
# -----------------------------------------------------------------------------

log "Minecraft watchdog starting."
log "Update channel: $UPDATE_CHANNEL"

if ! do_update; then
    log "Bootstrap update check failed. Continuing with existing JAR if available."
fi

[ -f "$SERVER_JAR" ] ||
    fail "$SERVER_JAR does not exist and no verified server JAR could be installed."

# Install mcrcon only when RCON is configured.

if [ -n "$RCON_PASS" ]; then

    if ! install_mcrcon; then
        log "WARNING: mcrcon setup failed."
        log "Live updates will be skipped. Bootstrap updates still work."
    fi

else
    log "RCON_PASS is empty."
    log "Bootstrap updates work, but live hourly updates are disabled."
fi

if [ "$BOOTSTRAP_UPDATED" = "1" ] && [ -f "$BACKUP_JAR" ]; then
    ROLLBACK_ELIGIBLE=1
fi

# Ignore HUP so terminal/session changes do not kill the watchdog.

trap '' HUP
trap 'handle_signal' INT TERM

# -----------------------------------------------------------------------------
# BACKGROUND UPDATE WATCHDOG
# -----------------------------------------------------------------------------

(
    trap '' HUP

    while :; do

        sleep "$UPDATE_INTERVAL"

        if ! do_update; then
            log "Update check encountered an error. Retrying next interval."
        fi

    done
) &

WATCHDOG_PID=$!

# -----------------------------------------------------------------------------
# MINECRAFT SERVER SUPERVISOR
# -----------------------------------------------------------------------------

while :; do

    if [ "$SHUTTING_DOWN" = "1" ]; then
        break
    fi

    log "Starting Minecraft server..."

    # Run Java in the foreground so Pterodactyl's attached console stdin
    # reaches the server process. The small shell wrapper writes its PID,
    # then execs Java so the PID remains the same for RCON/update handling.

    START_TIME=$(date +%s)

    sh -c '
        pid_file=$1
        shift
        printf "%s\\n" "$$" > "$pid_file" || exit 1
        exec "$@"
    ' watchdog-java "$PID_FILE" "$JAVA_BIN" \
        "-Xms$JAVA_XMS" \
        "-XX:MaxRAMPercentage=$JAVA_MAX_RAM_PERCENTAGE" \
        -jar "$SERVER_JAR" nogui
    JAVA_STATUS=$?

    JAVA_PID=$(cat "$PID_FILE" 2>/dev/null || true)

    END_TIME=$(date +%s)
    ELAPSED=$((END_TIME - START_TIME))

    rm -f "$PID_FILE"
    JAVA_PID=""

    if [ "$SHUTTING_DOWN" = "1" ]; then
        break
    fi

    # -------------------------------------------------------------------------
    # WAIT FOR UPDATE INSTALLATION
    # -------------------------------------------------------------------------

    if [ -f "$UPDATE_PENDING" ] ||
       [ -f "$UPDATE_RESTART" ] ||
       [ -f "$UPDATE_ABORT" ]; then

        while [ -f "$UPDATE_PENDING" ] &&
              [ ! -f "$UPDATE_RESTART" ] &&
              [ ! -f "$UPDATE_ABORT" ]; do

            sleep 1
        done

        if [ -f "$UPDATE_RESTART" ]; then

            if [ -f "$UPDATE_NEW_JAR" ] && [ -f "$BACKUP_JAR" ]; then
                ROLLBACK_ELIGIBLE=1
            else
                ROLLBACK_ELIGIBLE=0
            fi

            rm -f "$UPDATE_PENDING" \
                "$UPDATE_RESTART" \
                "$UPDATE_ABORT" \
                "$UPDATE_NEW_JAR"

            log "Restarting Minecraft after update operation..."

            continue
        fi

        if [ -f "$UPDATE_ABORT" ]; then

            rm -f "$UPDATE_PENDING" \
                "$UPDATE_ABORT" \
                "$UPDATE_RESTART" \
                "$UPDATE_NEW_JAR"

            log "Update aborted or server stopped manually."
            log "Not restarting Minecraft."

            break
        fi
    fi

    # -------------------------------------------------------------------------
    # AUTOMATIC ROLLBACK IF NEW JAR FAILS QUICKLY
    # -------------------------------------------------------------------------

    if [ "$ROLLBACK_ELIGIBLE" = "1" ] &&
       [ "$JAVA_STATUS" -ne 0 ] &&
       [ "$ELAPSED" -le "$STARTUP_GRACE_SECONDS" ] &&
       [ -f "$BACKUP_JAR" ]; then

        log "New server JAR exited with status $JAVA_STATUS after ${ELAPSED}s."
        log "Attempting automatic rollback..."

        if rollback_to_backup; then

            ROLLBACK_ELIGIBLE=0

            send_discord "Minecraft update failed to start. Restored the previous server JAR and will retry it."

            log "Previous server JAR restored."
            log "Restarting Minecraft..."

            continue
        fi
    fi

    ROLLBACK_ELIGIBLE=0

    # -------------------------------------------------------------------------
    # NORMAL SHUTDOWN / ERROR EXIT
    # -------------------------------------------------------------------------

    if [ "$JAVA_STATUS" -eq 0 ]; then

        log "Minecraft stopped normally."
        log "Exiting watchdog."

    else

        log "Minecraft exited with status $JAVA_STATUS."
        log "Exiting so Pterodactyl can apply its restart policy."

    fi

    break

done

# -----------------------------------------------------------------------------
# CLEANUP
# -----------------------------------------------------------------------------

stop_watchdog

rm -f "$PID_FILE" \
    "$DOWNLOAD_TMP" \
    "$BACKUP_TMP"

rm -rf "$TMP_DIR"

if [ "$SHUTTING_DOWN" = "1" ]; then
    exit 0
fi

exit "${JAVA_STATUS:-0}"