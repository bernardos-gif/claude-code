# Elemental Clash — Base44 Dev Notes

## Stack
Three.js + TypeScript + Vite frontend game. No backend, no database, no external services or credentials.

## Running
`docker compose -f docker-compose.base44.yml up -d` starts the Vite dev server (port 5173 inside container, mapped to host port 3000). Dependencies install on container startup via `npm install`.

## Key details
- Vite config sets `base: './'` and `host: true`; the compose command adds `--host 0.0.0.0 --port 5173`.
- `node_modules` lives in a Docker volume (not bind-mounted) to avoid host/container conflicts.
- All game assets (models, textures, audio) are procedural — no external asset files.
- The `BladeRush/` folder is a separate native macOS Swift/Metal project, not part of the web build.
- Tests: `npm test` (Vitest unit tests), `npm run test:e2e` (Playwright headless browser).
