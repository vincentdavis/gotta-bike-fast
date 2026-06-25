# Keyboard-only Web build, for hosting on Railway (or any container host).
#
# Stage 1 exports the "Web" preset with Godot headless; stage 2 serves the
# static files with Caddy on $PORT. The exported game is keyboard-only — the
# BLE bridge is gated off behind OS.has_feature("web") (see sensor_bridge.gd).
#
# The Godot + export-templates layer is cached across deploys, so only a source
# change re-runs the (fast) export step.

# ── Stage 1: export the Web build ───────────────────────────────────────
FROM debian:bookworm-slim AS exporter
ARG GODOT_VERSION=4.6.3
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl unzip \
        # Godot's Linux binary links these even for --headless; the dynamic
        # loader needs them present at process start or Godot won't launch.
        libx11-6 libxcursor1 libxinerama1 libxrandr2 libxi6 \
        libgl1 libglu1-mesa libfontconfig1 libasound2 \
    && rm -rf /var/lib/apt/lists/*

# Godot headless binary + matching web export templates.
RUN set -eux; \
    base="https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-stable"; \
    curl -fL --retry 5 -o /tmp/godot.zip "${base}/Godot_v${GODOT_VERSION}-stable_linux.x86_64.zip"; \
    unzip -q /tmp/godot.zip -d /tmp; \
    mv "/tmp/Godot_v${GODOT_VERSION}-stable_linux.x86_64" /usr/local/bin/godot; \
    chmod +x /usr/local/bin/godot; \
    curl -fL --retry 5 -o /tmp/templates.tpz "${base}/Godot_v${GODOT_VERSION}-stable_export_templates.tpz"; \
    mkdir -p "/root/.local/share/godot/export_templates/${GODOT_VERSION}.stable"; \
    unzip -q /tmp/templates.tpz -d /tmp/tpl; \
    mv /tmp/tpl/templates/* "/root/.local/share/godot/export_templates/${GODOT_VERSION}.stable/"; \
    rm -rf /tmp/godot.zip /tmp/templates.tpz /tmp/tpl

WORKDIR /src
COPY . .
# Import (generates .godot/), then export. Precompress the big binaries so Caddy
# can serve them gzip-encoded.
RUN godot --headless --path . --import . 2>&1 | tail -3 || true
RUN mkdir -p build/web \
    && godot --headless --path . --export-release "Web" build/web/index.html \
    && gzip -9 -k build/web/index.wasm build/web/index.pck build/web/index.js \
    && ls -lh build/web

# ── Stage 2: serve with Caddy on $PORT ──────────────────────────────────
FROM caddy:2-alpine
COPY --from=exporter /src/build/web /srv
COPY Caddyfile /etc/caddy/Caddyfile
# Railway injects $PORT; Caddy reads it in the Caddyfile.
CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
