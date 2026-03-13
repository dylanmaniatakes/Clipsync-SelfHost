# ClipSync Self-Hosted Server

This server replaces the original Firebase backend with a single self-hosted process.

## What it does

- Authenticates every request with a shared API key
- Stores pairings between one Mac and one Android device
- Accepts encrypted clipboard payloads from either device
- Accepts encrypted OTP relay payloads from Android
- Exposes polling endpoints so both clients can fetch new events
- Persists data to `server/data/store.json`

## Run it

```bash
cd server
npm install
node ./src/server.js
```

You can also use the executable wrapper:

```bash
./bin/clipsync-server
```

## Configuration

- `CLIPSYNC_BIND`
  Default: `0.0.0.0`
- `CLIPSYNC_PORT`
  Default: `8787`
- `CLIPSYNC_SERVER_KEY`
  Optional. If omitted, the server generates and persists a random key on first start.
- `CLIPSYNC_DATA_DIR`
  Optional. Defaults to `server/data`
- `CLIPSYNC_STORE_FILE`
  Optional. Overrides the full path to the JSON store file.

## Run with Docker

From inside the `server/` directory:

```bash
cd server
cp .env.example .env
docker compose up --build -d
```

Set `CLIPSYNC_SERVER_KEY` in `.env` before starting the container.

Useful commands:

```bash
docker compose ps
docker compose logs --tail 100 clipsync-server
docker compose down
```

The compose stack stores persistent state in the named volume `clipsync-server-data`.

## Security Notes

- Do not commit `.env`.
- Do not commit `data/store.json` or any copy of your runtime data directory.
- `CLIPSYNC_SERVER_KEY` is your shared deployment secret. Rotate it if you ever expose it publicly.
- Use a reverse proxy with HTTPS if clients will connect over the internet.

## Endpoints

- `GET /health`
- `GET /api/v1/server`
- `POST /api/v1/pairings`
- `GET /api/v1/pairings/by-mac/:macDeviceId?since=<ms>`
- `GET /api/v1/pairings/:pairingId`
- `DELETE /api/v1/pairings/:pairingId`
- `POST /api/v1/pairings/:pairingId/clipboard`
- `DELETE /api/v1/pairings/:pairingId/clipboard`
- `POST /api/v1/pairings/:pairingId/otp`
- `GET /api/v1/pairings/:pairingId/events?after=<cursor>&type=clipboard|otp&excludeDeviceId=<id>`

All `/api/*` endpoints except `/health` require the `X-ClipSync-Key` header.
