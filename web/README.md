# Scorpio blog UI

Stripe-inspired blog frontend (TanStack Router + Tailwind + Vite) that talks to the Zig API.

## Develop

```bash
# terminal 1 — API (from repo root)
zig build run

# terminal 2 — UI
cd web
npm install
npm run dev
```

Open http://127.0.0.1:5173 — `/blog` is proxied to `http://127.0.0.1:9090`.

## Shortcuts

- `[B]` / `b` — blog index
- `[C]` / `c` — toggle floating console

## Console commands

`help`, `ls`, `open <slug|path>`, `theme list|set`, `clear`, `close`
