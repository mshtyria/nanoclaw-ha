ARG BUILD_FROM
FROM $BUILD_FROM

# ── System dependencies ──────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl \
        git \
        ca-certificates \
        gnupg \
        python3 \
        make \
        g++ \
        docker.io \
    && rm -rf /var/lib/apt/lists/*

# ── Node.js 20 ───────────────────────────────────────────────────────────────
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# ── Claude Code CLI ──────────────────────────────────────────────────────────
# Required both by the NanoClaw orchestrator and by agent containers
RUN npm install -g @anthropic-ai/claude-code

# ── NanoClaw ─────────────────────────────────────────────────────────────────
WORKDIR /nanoclaw
RUN git clone --depth 1 https://github.com/qwibitai/nanoclaw.git . \
    && npm ci \
    && npm run build

# ── Startup script ───────────────────────────────────────────────────────────
COPY run.sh /run.sh
RUN chmod +x /run.sh

CMD ["/run.sh"]
