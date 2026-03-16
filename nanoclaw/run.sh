#!/usr/bin/with-contenv bashio

# ── Read add-on options ──────────────────────────────────────────────────────
ANTHROPIC_API_KEY=$(bashio::config 'anthropic_api_key')
ASSISTANT_NAME=$(bashio::config 'assistant_name')
ASSISTANT_HAS_OWN_NUMBER=$(bashio::config 'assistant_has_own_number')
MESSENGER=$(bashio::config 'messenger')
TELEGRAM_BOT_TOKEN=$(bashio::config 'telegram_bot_token')
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
# NanoClaw expects timeout in milliseconds
export CONTAINER_TIMEOUT=$(( CONTAINER_TIMEOUT_SEC * 1000 ))
export IDLE_TIMEOUT=$(( CONTAINER_TIMEOUT_SEC * 1000 ))
export CREDENTIAL_PROXY_PORT=3001
export LOG_LEVEL="${LOG_LEVEL}"

# Telegram token forwarded as env var for the Telegram connector
if [[ "${MESSENGER}" == "telegram" ]]; then
    export TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN}"
fi

# ── Persistent data directory ────────────────────────────────────────────────
# HA maps /data to persistent storage; move NanoClaw runtime dirs there.
DATA_DIR=/data/nanoclaw
mkdir -p "${DATA_DIR}/store" "${DATA_DIR}/data" "${DATA_DIR}/.config"

cd /nanoclaw

# store/ and data/ — simple symlinks; no pre-existing source content
for dir in store data; do
    if [[ ! -L "${dir}" ]]; then
        rm -rf "${dir}"
        ln -s "${DATA_DIR}/${dir}" "${dir}"
    fi
done

# groups/ contains source defaults (global/, main/) — copy once, then symlink
if [[ ! -d "${DATA_DIR}/groups" ]]; then
    bashio::log.info "Copying default group configs to persistent storage..."
    cp -r /nanoclaw/groups "${DATA_DIR}/groups"
fi
if [[ ! -L "groups" ]]; then
    rm -rf groups
    ln -s "${DATA_DIR}/groups" groups
fi

# Persist WhatsApp / Telegram session files (~/.config/nanoclaw)
if [[ ! -L "${HOME}/.config/nanoclaw" ]]; then
    mkdir -p "${HOME}/.config"
    ln -s "${DATA_DIR}/.config" "${HOME}/.config/nanoclaw"
fi

# ── Build the nanoclaw-agent Docker image if it doesn't exist yet ────────────
# The agent Dockerfile lives in container/ (not agent/) within the NanoClaw repo
if ! docker image inspect nanoclaw-agent:latest &>/dev/null; then
    bashio::log.info "Building nanoclaw-agent container image (first run, this may take a few minutes)..."
    docker build -t nanoclaw-agent:latest /nanoclaw/container \
        && bashio::log.info "nanoclaw-agent image built successfully." \
        || bashio::log.warning "Could not build nanoclaw-agent image. Agent containers will fail until the image is available."
fi

# ── WhatsApp first-run notice ────────────────────────────────────────────────
if [[ "${MESSENGER}" == "whatsapp" ]] && [[ ! -d "${DATA_DIR}/.config/whatsapp" ]]; then
    bashio::log.info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    bashio::log.info "FIRST RUN: WhatsApp authentication required."
    bashio::log.info "A QR code will appear below. Scan it with WhatsApp:"
    bashio::log.info "  WhatsApp → Settings → Linked Devices → Link a Device"
    bashio::log.info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
fi

# ── Start NanoClaw ───────────────────────────────────────────────────────────
bashio::log.info "Starting NanoClaw (assistant: ${ASSISTANT_NAME}, messenger: ${MESSENGER})..."

exec node /nanoclaw/dist/index.js
