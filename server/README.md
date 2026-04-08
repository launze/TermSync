# TermSync Server

Cross-platform terminal emulator server - lightweight Go server with SQLite.

## Quick Start

```bash
# Build and run
make all
./termsync-server

# Or with Docker
make docker
docker run -p 7373:7373 -p 8080:8080 termsync-server:latest
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| TERMSYNC_PORT | 7373 | WSS port |
| TERMSYNC_HTTP_PORT | 8080 | HTTP redirect port |
| TERMSYNC_DB_PATH | ./data/termsync.db | SQLite database path |
| TERMSYNC_JWT_SECRET | termsync-secret-change-in-production | JWT signing key |

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| POST | `/api/register` | Register new device |
| POST | `/api/login` | Login with token |
| POST | `/api/pairing/start` | Generate a 6-digit pairing code for a desktop device |
| POST | `/api/pairing/complete` | Bind a mobile device to a desktop by pairing code |
| GET | `/api/sessions` | List active sessions |
| GET | `/api/health` | Health check |
| GET | `/api/cert` | Download server certificate |
| GET | `/ws` | WebSocket endpoint |
