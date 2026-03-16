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
    && rm -rf /var/lib/apt/lists/*

# ── Docker CLI (from official Docker repo — Debian's docker.io is too old) ──
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
       https://download.docker.com/linux/debian bookworm stable" > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli \
    && rm -rf /var/lib/apt/lists/*

# ── Node.js 20 ───────────────────────────────────────────────────────────────
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# ── NanoClaw ─────────────────────────────────────────────────────────────────
# Note: @anthropic-ai/claude-code is NOT needed here — it runs only inside
# agent containers (built separately from /nanoclaw/container/Dockerfile)
WORKDIR /nanoclaw
RUN git clone --depth 1 https://github.com/qwibitai/nanoclaw.git . \
    && npm ci \
    && npm run build

# ── Startup script ───────────────────────────────────────────────────────────
COPY run.sh /run.sh
RUN chmod +x /run.sh

CMD ["/run.sh"]
