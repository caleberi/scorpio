# Scorpio

A personal blog engine: Markdown on disk, packed into addressable chunks, served by a Zig HTTP API, and read in a Stripe-inspired React UI.

Posts live as Markdown under `pages/`. At pack time they are concatenated into immutable chunk files with a JSON manifest. The API looks up a slug in that manifest, slices the document out of its chunk (from Cloudinary or a local cache), and returns it as JSON. PostgreSQL stores blog identity plus comments and replies — not the article bodies.

## Stack

| Layer | Tools |
| --- | --- |
| API | [Zig](https://ziglang.org/) 0.16, [zap](https://github.com/zigzap/zap), [pg.zig](https://github.com/karlseguin/pg.zig) |
| Content | Markdown → packed `.dat` chunks + `manifest.json`, [Cloudinary](https://cloudinary.com/) for media and packed assets |
| Data | PostgreSQL 16 (blogs, comments, replies) |
| UI | React 19, TanStack Router, Tailwind CSS 4, Vite |

## How it works

```
pages/*.md ──► pack-blog ──► packed/blog/{chunk-*.dat, manifest.json}
                    │                    │
                    │                    ▼
                    │              Cloudinary (raw)
                    ▼
              prerun ──► PostgreSQL (slug/path + comments)
                    │
                    ▼
              scorpio ──► GET /blog, GET /blog/*slug, comments API
                    │
                    ▼
              web (Vite / nginx)
```

1. **Pack** (`zig build pack` / `pack-blog`) processes images and videos, packs Markdown into ~4 MiB chunks, writes `manifest.json`, and uploads changed chunks to Cloudinary.
2. **Prerun** (`zig build prerun`) applies `sql/*.sql` and upserts one `blogs` row per packed document.
3. **Serve** (`zig build run` / `scorpio`) loads the manifest, caches chunks, and answers HTTP requests.

Each document in the manifest is a single seek-read: `chunk`, `offset`, `length`, plus `slug`, `path`, `modified_at`, and `sha256`. Listing the index does not open every Markdown file.

## Prerequisites

- Zig 0.16
- Node.js 22+ (frontend)
- PostgreSQL 16, or Docker for the full stack
- Cloudinary credentials (uploads skip with a warning if they fail; local packed files are still written)

## Quick start (local)

```bash
cp .env.sample .env
# fill in CLOUDINARY_* and DB_URL

# PostgreSQL must be reachable at DB_URL
zig build run
```

`zig build run` depends on pack and prerun, so the first start packs content, migrates the database, then listens on `http://127.0.0.1:9090`.

Frontend:

```bash
cd web
npm install
npm run dev
```

Open [http://127.0.0.1:5173](http://127.0.0.1:5173). Vite proxies `/blog` to the API. UI shortcuts and the floating console are documented in [`web/README.md`](web/README.md).

### Build steps

| Command | What it does |
| --- | --- |
| `zig build pack` | Process media, pack Markdown, upload changed chunks |
| `zig build prerun` | Apply SQL and upsert blog rows (runs pack first) |
| `zig build run` | Pack, prerun, then start the server |
| `zig build test` | Unit tests for common, router, libraries, and the executable |
| `zig build -Doptimize=ReleaseSafe` | Release binaries (`scorpio`, `pack-blog`, `prerun`) |

## Docker

```bash
cp .env.sample .env
# set CLOUDINARY_* ; compose overrides DB_URL to the postgres service

docker compose up --build
```

| Service | Port | Role |
| --- | --- | --- |
| `web` | 8080 | nginx: static UI, `/blog` and `/hello` proxied to the API |
| `api` | 9090 | scorpio; packs on first boot if `packed/blog/manifest.json` is missing |
| `postgres` | 5432 | `scorpio` database |

Force a re-pack on the next API start:

```bash
FORCE_PACK=1 docker compose up api
```

Packed artifacts persist in the `packed` volume.

## Configuration

Copy [`.env.sample`](.env.sample) to `.env`. Nested config is bound from uppercase env vars (`SERVER_PORT`, `BLOG_PACK_DIR`, `CLOUDINARY_API_KEY`, …).

| Variable | Default | Notes |
| --- | --- | --- |
| `SERVER_PORT` | `9090` | HTTP listen port (1024–65535) |
| `SERVER_THREADS` | `2` | zap worker threads |
| `SERVER_WORKERS` | `1` | zap worker processes |
| `LOG_LEVEL` | `info` | |
| `BLOG_INPUT_DIR` | `pages` | Markdown and media source tree |
| `BLOG_PACK_DIR` | `packed/blog` | Chunks and `manifest.json` |
| `BLOG_STAGING_DIR` | `packed/staging` | Intermediate media output |
| `BLOG_PREFETCH_NEIGHBORS` | `1` | Adjacent posts warmed into cache on GET |
| `CLOUDINARY_CLOUDNAME` | required | |
| `CLOUDINARY_API_KEY` | required | |
| `CLOUDINARY_API_SECRET` | required | |
| `CLOUDINARY_PACK_PREFIX` | `scorpio/blog/packed` | Public ID prefix for packed files |
| `DB_URL` | required | `postgres://` or `postgresql://` |

## HTTP API

The server uses a small action router (`:param` and `*splat` segments). Comment routes are registered before the document splat so `/blog/:slug/comments` wins over `/blog/*slug`.

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/hello` | Health / hello |
| `GET` | `/hello/:name` | Hello with a name |
| `GET` | `/blog` | List packed documents (`slug`, `path`, `modified_at`, `length`) |
| `GET` | `/blog/*slug` | Document body from cache/CDN, plus neighbor slugs to prefetch |
| `GET` | `/blog/*slug/comments` | Comments and nested replies |
| `POST` | `/blog/*slug/comments` | Create a comment (`author`, `body`) |
| `PUT` | `/blog/*slug/comments/:comment_id` | Update a comment |
| `DELETE` | `/blog/*slug/comments/:comment_id` | Delete a comment |
| `POST` | `/blog/*slug/comments/:comment_id/replies` | Create a reply |
| `PUT` | `/blog/*slug/comments/:comment_id/replies/:reply_id` | Update a reply |
| `DELETE` | `/blog/*slug/comments/:comment_id/replies/:reply_id` | Delete a reply |

JSON errors use `{ "error_message": "..." }`.

## Repository layout

```
pages/                 Markdown source (posts + profile)
sql/                   Schema applied by prerun
src/                   scorpio, pack-blog, prerun
  app/actions/         HTTP actions (blogs, comments, replies)
  app/blog/            Manifest cache and PostgreSQL helpers
libraries/             Router, packer, validation, Cloudinary, dotenv
common/                Shared helpers
web/                   React UI
docker/                API entrypoint and nginx config
```

## Writing posts

Add a Markdown file under `pages/` (typically `pages/blog/...`) with YAML frontmatter (`title`, `summary`, `authors`, `date`, `topics`, `type`, optional `image`). Then pack and restart (or run `zig build pack` and `zig build prerun` against a running database).

The UI renders GFM, syntax highlighting (Shiki), and Mermaid diagrams. Slugs come from the packed relative path.
