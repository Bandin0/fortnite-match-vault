# Fortnite Match Vault

A self-hosted Fortnite match-history site. It reads the `.replay` files Fortnite
saves after each **PC** match and turns them into a browsable history: placement,
kills, teammates, per-player platform/level, the storm/zone timeline animation,
and a kill feed.

Everything runs on **your** machine — your data never leaves it. No accounts, no
cloud, no external services.

---

## What you get

- **Matches tab** — every match with placement, kills, duration and teammate chips
- **Teammates tab** — per-teammate aggregates (matches, avg kills, wins, best place)
- **Tier List tab** — ranks your whole squad by points/match (placement points + elims)
- **Match detail** — your team, the full lobby scoreboard with a **platform
  breakdown**, per-player platform/level/bot tags, an **animated storm/zone
  timeline**, and a **kill feed**
- **Multi-uploader** — several people can upload into one vault; matches are
  auto-separated per recorder with a player dropdown

---

## How it works

```
 Fortnite PC ──(.replay)──►  watcher/uploader  ──HTTP──►  this server
                                                          │
                                          C# replay2json (FortniteReplayReader)
                                                          │
                                                   match JSON  ──►  web UI
```

- The heavy lifting is done by the open-source library
  **[FortniteReplayReader](https://github.com/Shiqan/FortniteReplayDecompressor)** (Shiqan).
- A tiny C# CLI (`replay2json/`) wraps it and emits normalized JSON.
- A Node/Express server (`app/`) stores matches, dedupes by file content hash, and
  serves the UI.

---

## Requirements

- **Server:** anything that runs Docker (a mini-PC, NAS, VM, even a spare laptop).
  Docker + Docker Compose is all you need — the .NET and Node toolchains are
  inside the image.
- **Replay uploads:** a **Windows PC** with Fortnite (replays only exist for PC
  matches; console/cloud matches can't be captured this way).

---

## Quick start — the server

```bash
# 1. get the files (unzip, or clone your repo)
cd fortnite-match-vault

# 2. (optional) copy the example config
cp .env.example .env      # Windows: copy .env.example .env

# 3. build + start
docker compose up -d --build
```

Open **http://localhost:8090** (or `http://<server-ip>:8090` from another device).

That's it. It's now listening for replay uploads on port 8090.

### Configuration (`.env`, all optional)

| Variable | Default | Purpose |
|---|---|---|
| `HOST_PORT` | `8090` | Host port for the web UI |
| `FORTNITE_INGEST_KEY` | *(blank)* | If set, uploads must send this key (blank = open) |
| `FORTNITE_ME_NAME` | *(blank)* | Your in-game name, helps identify "you" in ambiguous replays |

Data lives in `./data/` next to `docker-compose.yml`:
- `data/matches/*.json` — parsed match records
- `data/raw/*.replay` — the original replays (so records can be re-parsed later)

---

## Quick start — your gaming PC

In the `client/` folder you have three PowerShell scripts:

| Script | What it does |
|---|---|
| `Install-Watcher.ps1` | **Recommended.** Installs a hidden background watcher that auto-uploads new replays, and auto-starts it at every logon. No admin needed. |
| `FortniteWatcher.ps1` | The watcher itself (runs forever, uploads within seconds of each match). |
| `FortniteUploader.ps1` | One-shot: uploads new replays now, then exits. Good for testing. |

**Install the auto-uploader** (run once, in PowerShell):

```powershell
cd client
powershell -ExecutionPolicy Bypass -File Install-Watcher.ps1 -Server http://YOUR-SERVER-IP:8090/api/ingest
```

Replace `YOUR-SERVER-IP` with the machine running the server (e.g. `192.168.1.50`).
If your server requires an ingest key, add `-IngestKey "yourkey"`.

It will:
1. copy the watcher to `%LOCALAPPDATA%\FortniteWatcher\`
2. drop a hidden launcher in your **Startup** folder (auto-runs at logon)
3. start it immediately and bulk-upload any existing replays

Log: `%LOCALAPPDATA%\FortniteWatcher\watcher.log`

### Where are my replays?

Modern Fortnite stores them at:

```
%LOCALAPPDATA%\FortniteGame\Saved\Demos
```

(`%LOCALAPPDATA%` is usually `C:\Users\<you>\AppData\Local` — a hidden folder.)
The scripts find this automatically; use `-Demos "D:\path"` to override.

### Manual / bulk upload

```powershell
# upload everything not yet sent (one zipped request)
powershell -ExecutionPolicy Bypass -File FortniteUploader.ps1 -Server http://YOUR-SERVER-IP:8090/api/ingest

# re-send everything (e.g. after upgrading the server)
powershell -ExecutionPolicy Bypass -File FortniteUploader.ps1 -Server http://YOUR-SERVER-IP:8090/api/ingest -Reset
```

You can also just **drag the `Demos` folder** onto the web page, or drop a single
`.replay` file — the site has an in-browser uploader (Chrome/Edge).

---

## Letting friends upload

Uploads are open by default on your LAN. If several people send replays, each
match is filed under **whoever recorded it** (the replay says so), and a player
dropdown appears so each person can view their own stats. Nothing to configure.

If the port is reachable by people you don't trust, set `FORTNITE_INGEST_KEY` and
share the key with your friends (they pass it as `-IngestKey`).

---

## Upgrading the parser

The server keeps the original replays in `data/raw/`. After changing
`replay2json/Program.cs`, rebuild and re-parse without re-uploading:

```bash
docker compose up -d --build
curl -X POST http://localhost:8090/api/reparse
```

---

## API (handy for scripts)

| Endpoint | Description |
|---|---|
| `GET /api/matches` | match list (`?owner=Name` to filter) |
| `GET /api/matches/:id` | full match record |
| `GET /api/teammates` | per-teammate aggregates |
| `GET /api/tierlist` | squad tier ranking |
| `GET /api/owners` | distinct recorders + counts |
| `GET /api/health` | status |
| `POST /api/ingest` | upload one replay (raw body, `X-Replay-Name` header) |
| `POST /api/ingest-zip` | upload a zip of replays |
| `POST /api/reparse` | re-parse everything in `data/raw/` |

---

## Exposing it beyond your LAN (optional)

The site is plain HTTP on port 8090. To reach it from outside your home network
**without opening any ports**, a Cloudflare Tunnel works well:

1. Create a tunnel in the Cloudflare Zero Trust dashboard.
2. Run `cloudflared` pointing at `http://localhost:8090`.
3. Point a hostname at the tunnel.

Add **Cloudflare Access** in front of it if you want a login gate.

---

## Credits & license

- Replay parsing: **[FortniteReplayDecompressor / FortniteReplayReader](https://github.com/Shiqan/FortniteReplayDecompressor)** by Shiqan — see that repository for its license terms.
- Everything else in this repo (server, UI, CLI wrapper, client scripts) is yours to use and modify.

Fortnite is a trademark of Epic Games. This project is unaffiliated and is for
personal, non-commercial use on your own replay files.
