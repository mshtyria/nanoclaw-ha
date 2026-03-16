#!/usr/bin/with-contenv bashio

# ── Read add-on options ──────────────────────────────────────────────────────
ANTHROPIC_API_KEY=$(bashio::config 'anthropic_api_key')
ASSISTANT_NAME=$(bashio::config 'assistant_name')
ASSISTANT_HAS_OWN_NUMBER=$(bashio::config 'assistant_has_own_number')
MESSENGER=$(bashio::config 'messenger')
TELEGRAM_BOT_TOKEN=$(bashio::config 'telegram_bot_token')
TELEGRAM_CHAT_ID=$(bashio::config 'telegram_chat_id')
MAX_CONCURRENT_CONTAINERS=$(bashio::config 'max_concurrent_containers')
CONTAINER_TIMEOUT_SEC=$(bashio::config 'container_timeout')
LOG_LEVEL=$(bashio::config 'log_level')

# ── Validate required options ────────────────────────────────────────────────
if bashio::var.is_empty "${ANTHROPIC_API_KEY}"; then
    bashio::log.fatal "anthropic_api_key is not set. Please configure it in the add-on options."
    exit 1
fi

if [[ "${MESSENGER}" == "telegram" ]] && bashio::var.is_empty "${TELEGRAM_BOT_TOKEN}"; then
    bashio::log.fatal "telegram_bot_token is required when messenger is set to 'telegram'."
    exit 1
fi

# ── Export environment variables expected by NanoClaw ───────────────────────
export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}"
export ASSISTANT_NAME="${ASSISTANT_NAME}"
export ASSISTANT_HAS_OWN_NUMBER="${ASSISTANT_HAS_OWN_NUMBER}"
export MAX_CONCURRENT_CONTAINERS="${MAX_CONCURRENT_CONTAINERS}"
export CONTAINER_TIMEOUT=$(( CONTAINER_TIMEOUT_SEC * 1000 ))
export IDLE_TIMEOUT=$(( CONTAINER_TIMEOUT_SEC * 1000 ))
export CREDENTIAL_PROXY_PORT=3001
export LOG_LEVEL="${LOG_LEVEL}"

if [[ "${MESSENGER}" == "telegram" ]]; then
    export TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN}"
fi

# ── Docker socket setup ──────────────────────────────────────────────────────
if [[ -S /var/run/docker.sock ]]; then
    export DOCKER_HOST="unix:///var/run/docker.sock"
elif [[ -S /run/docker.sock ]]; then
    export DOCKER_HOST="unix:///run/docker.sock"
else
    bashio::log.fatal "Docker socket not found! Enable docker_api and disable Protection mode."
    exit 1
fi

bashio::log.info "Docker: $(docker info --format '{{.ServerVersion}}' 2>&1)"

# ── Docker-in-Docker path translation ────────────────────────────────────────
# NanoClaw uses process.cwd() for docker -v mount paths. But Docker daemon
# runs on the HOST and needs HOST paths, not container-internal paths.
# Solution: wrap the docker CLI to rewrite /data → HOST_DATA in -v arguments.

CID=$(cat /run/cid 2>/dev/null || hostname)
HOST_DATA=$(docker inspect "${CID}" --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}' 2>/dev/null)

if [[ -z "${HOST_DATA}" ]]; then
    bashio::log.warning "Could not detect host path for /data. Trying fallback..."
    # Fallback: common HAOS path pattern
    HOST_DATA="/mnt/data/supervisor/addons/data/nanoclaw"
fi

bashio::log.info "Host data path: ${HOST_DATA}"

# NanoClaw working directory — on the host-visible /data partition
APP_DIR="/data/app"
HOST_APP="${HOST_DATA}/app"

# ── Docker CLI wrapper ────────────────────────────────────────────────────────
# NanoClaw calls `docker run -v /data/app/...:/workspace/...` but the Docker
# daemon runs on the host and needs host paths. This wrapper rewrites -v source
# paths from container-internal /data to host-visible HOST_DATA.
REAL_DOCKER=$(which docker)
cat > /usr/local/bin/docker <<'WRAPPER'
#!/bin/bash
# Docker CLI wrapper: rewrites /data paths → host paths in -v mount arguments.
# NanoClaw generates "-v /data/app/...:/workspace/..." but the Docker daemon
# needs the host-side path for bind mounts.
HOST_DATA="__HOST_DATA__"
REAL_DOCKER="__REAL_DOCKER__"

ARGS=()
NEXT_IS_VOLUME=false
for arg in "$@"; do
    if $NEXT_IS_VOLUME; then
        # arg is the volume spec: src:dst[:opts]
        arg="${arg/\/data\//${HOST_DATA}/}"
        NEXT_IS_VOLUME=false
    elif [[ "$arg" == "-v" ]]; then
        NEXT_IS_VOLUME=true
    elif [[ "$arg" == -v/data/* ]]; then
        # -v/data/app/...:/workspace/... (joined form)
        arg="-v${arg#-v}"
        arg="${arg/\/data\//${HOST_DATA}/}"
    elif [[ "$arg" == "--volume" ]]; then
        NEXT_IS_VOLUME=true
    fi
    ARGS+=("$arg")
done
exec "$REAL_DOCKER" "${ARGS[@]}"
WRAPPER
# Substitute actual values into the wrapper
sed -i "s|__HOST_DATA__|${HOST_DATA}|g" /usr/local/bin/docker
sed -i "s|__REAL_DOCKER__|${REAL_DOCKER}|g" /usr/local/bin/docker
chmod +x /usr/local/bin/docker
bashio::log.info "Docker wrapper installed (rewrites /data → ${HOST_DATA})"

# Copy NanoClaw source to /data/app (persisted, host-visible)
if [[ ! -f "${APP_DIR}/dist/index.js" ]]; then
    bashio::log.info "Copying NanoClaw to persistent storage (first run)..."
    mkdir -p "${APP_DIR}"
    cp -a /nanoclaw/. "${APP_DIR}/"
else
    # Update dist/ and container/ on each start (new addon version may have changes)
    cp -a /nanoclaw/dist/. "${APP_DIR}/dist/"
    cp -a /nanoclaw/container/. "${APP_DIR}/container/"
    cp -a /nanoclaw/package.json "${APP_DIR}/package.json"
    # Ensure node_modules are present
    if [[ ! -d "${APP_DIR}/node_modules" ]]; then
        cp -a /nanoclaw/node_modules/. "${APP_DIR}/node_modules/"
    fi
fi


# ── Generate .env file ───────────────────────────────────────────────────────
cat > "${APP_DIR}/.env" <<ENVEOF
ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}
ASSISTANT_NAME=${ASSISTANT_NAME}
ASSISTANT_HAS_OWN_NUMBER=${ASSISTANT_HAS_OWN_NUMBER}
MAX_CONCURRENT_CONTAINERS=${MAX_CONCURRENT_CONTAINERS}
CONTAINER_TIMEOUT=$(( CONTAINER_TIMEOUT_SEC * 1000 ))
IDLE_TIMEOUT=$(( CONTAINER_TIMEOUT_SEC * 1000 ))
CREDENTIAL_PROXY_PORT=3001
ENVEOF

if [[ "${MESSENGER}" == "telegram" ]]; then
    echo "TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}" >> "${APP_DIR}/.env"
fi

mkdir -p "${APP_DIR}/data/env"
cp "${APP_DIR}/.env" "${APP_DIR}/data/env/env"

# ── Ensure runtime directories exist ─────────────────────────────────────────
mkdir -p "${APP_DIR}/store" "${APP_DIR}/data" "${APP_DIR}/groups/main" "${APP_DIR}/groups/global"

# Clean stale IPC files from previous runs and fix permissions.
# Agent containers run as node (uid 1000) but IPC dirs/files may be owned by root.
if [[ -d "${APP_DIR}/data/ipc" ]]; then
    find "${APP_DIR}/data/ipc" -type d -exec chmod 777 {} +
    find "${APP_DIR}/data/ipc" -type f -exec chmod 666 {} +
    # Remove stale input files (leftover from previous container sessions)
    find "${APP_DIR}/data/ipc" -path '*/input/*.json' -delete 2>/dev/null
    bashio::log.info "IPC directory cleaned and permissions fixed"
fi

# Clean stale Claude Code sessions from previous failed runs.
# Session IDs are stored in two places:
# 1. SQLite messages.db → sessions table (orchestrator reads this to pass sessionId to containers)
# 2. /data/sessions/{group}/.claude/ (Claude Code's own session files inside containers)
# Both must be cleared so agents start fresh instead of trying to resume stale sessions.
if [[ -d "${APP_DIR}/data/sessions" ]]; then
    find "${APP_DIR}/data/sessions" -type d -exec chmod 777 {} +
    find "${APP_DIR}/data/sessions" -type f -exec chmod 666 {} +
    find "${APP_DIR}/data/sessions" -name ".claude" -type d -exec rm -rf {} + 2>/dev/null
fi
# Clear session IDs from SQLite so orchestrator doesn't pass stale IDs to new containers
if [[ -f "${APP_DIR}/store/messages.db" ]]; then
    node -e "
      const Database = require('better-sqlite3');
      const db = new Database('${APP_DIR}/store/messages.db');
      try { db.exec('DELETE FROM sessions'); } catch(e) {}
      db.close();
    " 2>/dev/null
    bashio::log.info "Session data cleaned (SQLite + files)"
fi

# Copy default group configs if not present
if [[ ! -f "${APP_DIR}/groups/main/CLAUDE.md" ]] && [[ -f "/nanoclaw/groups/main/CLAUDE.md" ]]; then
    cp -a /nanoclaw/groups/main/. "${APP_DIR}/groups/main/"
fi
if [[ ! -f "${APP_DIR}/groups/global/CLAUDE.md" ]] && [[ -f "/nanoclaw/groups/global/CLAUDE.md" ]]; then
    cp -a /nanoclaw/groups/global/. "${APP_DIR}/groups/global/"
fi

# ── Build the nanoclaw-agent Docker image if needed ──────────────────────────
if ! docker image inspect nanoclaw-agent:latest &>/dev/null; then
    bashio::log.info "Building nanoclaw-agent container image (first run, this may take a few minutes)..."
    docker build -t nanoclaw-agent:latest "${APP_DIR}/container" \
        && bashio::log.info "nanoclaw-agent image built successfully." \
        || bashio::log.warning "Could not build nanoclaw-agent image."
fi

# ── Register Telegram chat if configured ─────────────────────────────────────
if [[ "${MESSENGER}" == "telegram" ]] && ! bashio::var.is_empty "${TELEGRAM_CHAT_ID}"; then
    CHAT_JID="${TELEGRAM_CHAT_ID}"
    [[ "${CHAT_JID}" != tg:* ]] && CHAT_JID="tg:${CHAT_JID}"

    bashio::log.info "Registering Telegram chat: ${CHAT_JID}"
    node -e "
      const Database = require('better-sqlite3');
      const db = new Database('${APP_DIR}/store/messages.db');
      db.exec(\`
        CREATE TABLE IF NOT EXISTS registered_groups (
          jid TEXT PRIMARY KEY, name TEXT, folder TEXT,
          trigger_pattern TEXT, added_at TEXT, container_config TEXT,
          requires_trigger INTEGER DEFAULT 1, is_main INTEGER DEFAULT 0
        )
      \`);
      db.prepare(\`
        INSERT OR REPLACE INTO registered_groups
        (jid, name, folder, trigger_pattern, added_at, container_config, requires_trigger, is_main)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      \`).run('${CHAT_JID}', 'HomeAssistant', 'main', '@${ASSISTANT_NAME}',
             new Date().toISOString(), '{}', 0, 1);
      console.log('Chat registered successfully');
      db.close();
    " 2>&1 || bashio::log.warning "Chat registration failed"
fi

# ── Start dashboard ───────────────────────────────────────────────────────────
export APP_DIR
export DASHBOARD_PORT=8099
export NODE_PATH="${APP_DIR}/node_modules"
node /dashboard/server.js &
bashio::log.info "Dashboard started on port ${DASHBOARD_PORT}"

# ── Start NanoClaw ────────────────────────────────────────────────────────────
bashio::log.info "Starting NanoClaw from: ${APP_DIR}"
bashio::log.info "  assistant: ${ASSISTANT_NAME}, messenger: ${MESSENGER}"

cd "${APP_DIR}"

# NanoClaw runs as root in the addon, but agent containers run as node (uid 1000).
# Set umask so IPC files created by the orchestrator are world-writable,
# allowing the agent container to read and delete them.
umask 0000

exec node dist/index.js
