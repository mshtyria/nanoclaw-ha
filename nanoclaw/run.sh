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
# Solution: find the host path for /data, copy NanoClaw there, create a
# symlink so the container-internal path matches the host path, then run
# NanoClaw from the host-matching path.

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

# Create symlink inside the container so HOST_APP path resolves to /data/app.
# e.g. /mnt/data/supervisor/addons/data/62d3ce49_nanoclaw -> /data
# Then HOST_APP (/mnt/data/.../app) exists inside the container too.
if [[ "${HOST_DATA}" != "/data" ]] && [[ ! -e "${HOST_DATA}" ]]; then
    mkdir -p "$(dirname "${HOST_DATA}")"
    ln -sfn /data "${HOST_DATA}"
    bashio::log.info "Symlink created: ${HOST_DATA} -> /data"
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
      const db = new Database('${HOST_APP}/store/messages.db');
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

# ── Start NanoClaw from host-visible path ────────────────────────────────────
# NanoClaw uses process.cwd() for docker -v mount paths.
# cd to HOST_APP so Docker daemon can resolve mount source paths on the host.
bashio::log.info "Starting NanoClaw from: ${HOST_APP}"
bashio::log.info "  assistant: ${ASSISTANT_NAME}, messenger: ${MESSENGER}"

cd "${HOST_APP}"
exec node dist/index.js
