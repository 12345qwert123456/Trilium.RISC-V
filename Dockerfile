# =============================================================================
# RISC-V (riscv64) Dockerfile for TriliumNext
#
# Build strategy:
#   - Backend : compiled natively on riscv64 via esbuild + node-gyp
#   - Frontend: static files copied from the official AMD64 image with no RUN
#               commands in that stage, so QEMU is never needed
#   - better-sqlite3: built in an isolated directory that mirrors the official
#               docker/package.json approach, placing the .node binary at a
#               predictable flat path
# =============================================================================

# =============================================================================
# Stage 1 — Backend builder (runs natively on the target platform: riscv64)
# =============================================================================
ARG TRILIUM_TAG=main
FROM alpine:3.21 AS backend_builder
ARG TRILIUM_TAG

RUN apk add --no-cache \
        git nodejs npm python3 make g++ gcc \
        autoconf libtool build-base py3-setuptools && \
    npm install -g corepack && \
    corepack enable

# -- Build better-sqlite3 in isolation ----------------------------------------
# Mirrors the official apps/server/docker/package.json approach.
# --shamefully-hoist ensures that peer deps (bindings, file-uri-to-path) are
# hoisted to the top-level node_modules and are easy to copy later.
WORKDIR /native
RUN printf '{"dependencies":{"better-sqlite3":"12.8.0"}}' > package.json && \
    printf 'onlyBuiltDependencies:\n- better-sqlite3\n' > pnpm-workspace.yaml && \
    pnpm install --no-frozen-lockfile --prod --shamefully-hoist

# -- Clone source and install monorepo dependencies ---------------------------
WORKDIR /build
RUN git clone --depth 1 --branch ${TRILIUM_TAG} https://github.com/TriliumNext/Trilium.git .

# --ignore-scripts skips native postinstall hooks; the .node binary already
# built in /native will be copied into the final image separately.
RUN pnpm install --no-frozen-lockfile --ignore-scripts

# -- Compile TypeScript → dist/main.cjs via esbuild ---------------------------
# esbuild ships a prebuilt binary for linux/riscv64 (@esbuild/linux-riscv64).
# loader:css=text and loader:ejs=text inline templates into the bundle,
# matching the behaviour of the official scripts/build-utils.ts.
RUN cd apps/server && \
    npx esbuild \
        src/main.ts \
        src/docker_healthcheck.ts \
        --tsconfig=tsconfig.app.json \
        --platform=node \
        --bundle \
        --outdir=dist \
        --out-extension:.js=.cjs \
        --format=cjs \
        --external:electron \
        --external:@electron/remote \
        --external:better-sqlite3 \
        "--external:./xhr-sync-worker.js" \
        --external:vite \
        --loader:.css=text \
        --loader:.ejs=text \
        "--define:process.env.NODE_ENV=\"production\"" \
        --minify

# Copy server-side assets (EJS views, icons, DB initialisation SQL scripts)
RUN cp -r apps/server/src/assets apps/server/dist/assets

# =============================================================================
# Stage 2 — Frontend source (AMD64, no RUN commands)
# Docker only pulls the image layers and copies files from them.
# No AMD64 code is executed, so QEMU is NOT required.
# =============================================================================
FROM --platform=linux/amd64 ghcr.io/triliumnext/trilium:${TRILIUM_TAG} AS frontend_source

# =============================================================================
# Stage 3 — Final runtime image (riscv64)
# =============================================================================
FROM alpine:3.21

# Install runtime deps, create the app user and data directory in one layer
RUN apk add --no-cache nodejs su-exec shadow && \
    adduser -s /bin/false node || true && \
    mkdir -p /home/node/trilium-data && \
    chown -R node:node /home/node/trilium-data

WORKDIR /usr/src/app

# Compiled server bundle + server-side assets
COPY --from=backend_builder /build/apps/server/dist .

# Native modules built for riscv64 (from the clean isolated /native build)
COPY --from=backend_builder /native/node_modules/better-sqlite3   ./node_modules/better-sqlite3
COPY --from=backend_builder /native/node_modules/bindings          ./node_modules/bindings
COPY --from=backend_builder /native/node_modules/file-uri-to-path  ./node_modules/file-uri-to-path

# CKEditor content CSS (required for note and share-page rendering)
COPY --from=backend_builder /build/node_modules/ckeditor5/dist/ckeditor5-content.css .

# Frontend static files from the official AMD64 image.
# When running `node ./main.cjs` from /usr/src/app, getResourceDir() returns
# /usr/src/app, so the server expects:
#   /usr/src/app/public/index.html   ← served at GET /
#   /usr/src/app/assets/             ← DB init SQL, EJS views (RESOURCE_DIR)
COPY --from=frontend_source /usr/src/app/public       ./public/
COPY --from=frontend_source /usr/src/app/pdfjs-viewer  ./pdfjs-viewer/
COPY --from=frontend_source /usr/src/app/share-theme   ./share-theme/

# Entrypoint: su-exec avoids the PAM dependency that `su -c` requires on Alpine
RUN printf '#!/bin/sh\n\
[ -n "${USER_UID}" ] && usermod -u "${USER_UID}" node || echo "No USER_UID specified, leaving 1000"\n\
[ -n "${USER_GID}" ] && groupmod -og "${USER_GID}" node || echo "No USER_GID specified, leaving 1000"\n\
chown -R node:node /home/node\n\
exec su-exec node node /usr/src/app/main.cjs\n\
' > /start.sh && chmod +x /start.sh

EXPOSE 8080
ENV TRILIUM_DATA_DIR=/home/node/trilium-data

CMD ["/start.sh"]
HEALTHCHECK --start-period=10s CMD exec su-exec node node /usr/src/app/docker_healthcheck.cjs