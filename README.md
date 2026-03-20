# TriliumNext on RISC-V (riscv64)

![Platform](https://img.shields.io/badge/platform-linux%2Friscv64-blue)
![License](https://img.shields.io/badge/license-AGPL--3.0-green)
![Docker Pulls](https://img.shields.io/docker/pulls/12345qwert123456/trilium-riscv64)

A community Dockerfile for running [TriliumNext Notes](https://github.com/TriliumNext/Trilium) on `linux/riscv64` hardware (e.g. OrangePi RV2, StarFive VisionFive 2, Milk-V Pioneer, QEMU riscv64).

The official TriliumNext image does not publish a `riscv64` manifest, and a straight cross-compilation fails due to several platform-specific issues described below. This Dockerfile works around all of them.

## Quick start (Docker Hub)

If you just want to run Trilium without building the image yourself:
```bash
docker pull 12345qwert123456/trilium-riscv64:latest
```

Then run:
```bash
docker run -d \
  --name trilium \
  -p 8080:8080 \
  -v ~/trilium-data:/home/node/trilium-data \
  12345qwert123456/trilium-riscv64:latest
```

And open http://localhost:8080 in your browser.

## How it works

The build uses three stages:

### Stage 1 — Backend builder (runs natively on riscv64)

- Clones the TriliumNext repository from GitHub
- Builds **`better-sqlite3`** from source using `node-gyp` (C++ compilation) inside an isolated directory with `--shamefully-hoist` — this mirrors the approach used in the official `apps/server/docker/package.json` and ensures the `.node` binary ends up at a predictable flat path
- Compiles the TypeScript server to a single `main.cjs` bundle via **esbuild**, which ships a prebuilt binary for `linux/riscv64` and requires no cross-compilation
- Copies server-side assets (EJS views, icons, DB initialisation SQL files)

### Stage 2 — Frontend source (AMD64, zero RUN commands)

The official AMD64 image is used **only as a file source**. Because this stage contains no `RUN` instructions, Docker never executes any AMD64 code — it only pulls the image layers. **QEMU is not required.**

This approach avoids two riscv64-specific issues:
- V8 `kMaxBranchOffset` overflow crashes that occur during Vite/Rollup bundling of large JavaScript
- Missing prebuilt `lightningcss` binary for `riscv64`

### Stage 3 — Final runtime image (riscv64)

A minimal `alpine:3.21` image with `nodejs` and `su-exec`. The `su-exec` utility is used in the entrypoint instead of `su -c`, because Alpine does not ship PAM configuration and `su` fails silently inside a container.

## Requirements

| Requirement | Notes |
|---|---|
| Docker with Buildx | Standard Docker Engine ≥ 23 |
| riscv64 host **or** QEMU user-mode emulation | Only Stage 1 needs the target platform; Stage 2 pulls AMD64 layers without executing them |
| Internet access during build | Clones the repo and downloads APK packages |

> **Cross-building from x86-64:** register `qemu-user-static` and build with `docker buildx build --platform linux/riscv64`. Stage 2 pulls the AMD64 image natively without QEMU; only Stage 1 runs under emulation.

## Build

```bash
docker build -t trilium-riscv64 .
```

To pin a specific TriliumNext version, edit the `git clone` line in the Dockerfile and the `ghcr.io/triliumnext/trilium:main` reference in Stage 2 to the same tag (e.g. `v0.102.1`).

## Run

```bash
docker run -d \
  --name trilium \
  -p 8080:8080 \
  -v ~/trilium-data:/home/node/trilium-data \
  trilium-riscv64
```

### docker-compose example

```yaml
services:
  trilium:
    image: trilium-riscv64
    restart: unless-stopped
    ports:
      - "8080:8080"
    volumes:
      - ./data:/home/node/trilium-data
    environment:
      - USER_UID=1000   # optional, match your host user
      - USER_GID=1000
```

### Environment variables

| Variable | Default | Description |
|---|---|---|
| `TRILIUM_DATA_DIR` | `/home/node/trilium-data` | Path where notes database and config are stored |
| `USER_UID` | `1000` | UID the server process runs as |
| `USER_GID` | `1000` | GID the server process runs as |

## Tested on

- OrangePi RV2 (Ky(R) X1: 8-core RISC-V) - TriliumNext v0.102.1, Node.js 22.x
- QEMU riscv64 (x86-64 host, Docker buildx)

## Known limitations

- The frontend is always taken from `ghcr.io/triliumnext/trilium:main` (the latest development build). If you need a stable release, replace both the `git clone` ref and the `FROM --platform=linux/amd64` tag with the same version tag.
- Desktop (Electron) mode is not supported — server mode only.
- The build takes a significant amount of time on native riscv64 hardware due to the C++ compilation of `better-sqlite3`. Subsequent rebuilds are fast because the `/native` stage is cached independently of source changes.

## Why not upstream?

The main blockers for an official riscv64 image are:

1. **No `node:*-alpine` image for riscv64** — the official Node.js Docker Library does not publish Alpine variants for this architecture. Alpine's own `nodejs` package is used instead.
2. **Frontend build fails on riscv64** — Vite/Rollup trigger a V8 `kMaxBranchOffset` out-of-range error when bundling the large CKEditor payload; `lightningcss` has no prebuilt binary for riscv64.
3. **`better-sqlite3` must be compiled from source** — no prebuilt binary exists for `node-v127-linux-riscv64`.

This Dockerfile solves all three without requiring QEMU at runtime.

## License

This Dockerfile is released under the same license as TriliumNext: [AGPL-3.0](https://github.com/TriliumNext/Trilium/blob/main/LICENSE).
