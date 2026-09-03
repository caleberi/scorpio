---
title: 'Scorpio #1 — Packing markdown'
summary: 'How zig build pack rewrites local images and videos, stages markdown, then hands the tree to the packer'
authors:
  - 'Adewole Caleb'
date: '2026-09-03'
topics:
  - 'Zig'
  - 'Engineering'
  - 'Cloudinary'
  - 'Markdown'
type: 'Blog'
image: '![image](../../../../blobs/cover41.jpeg)'
highlight: amber
---

> Part 1 of How Scorpio works. Start at the [intro](/posts/blog/guides/intro) if this is your first click.

`zig build pack` is the only command that is allowed to touch `pages/` as a source of truth.

The server will not. The React app will not. If a post is not in the pack, it does not exist.

`pack_blog.zig` is a short script with a loud job.

```mermaid
flowchart LR
  pages[pages/*.md] --> img[rewrite images]
  img --> vid[rewrite videos]
  vid --> stage[packed/staging]
  stage --> pack[Packer.pack]
  pack --> out[chunks + manifest]
  out -->|warn on fail| cloud[Cloudinary raw]
```

```zig
try ensureDir(cfg.blog.staging_dir);
try ensureDir(cfg.blog.pack_dir);

// 1. rewrite images into staging
// 2. rewrite videos on that staging tree
// 3. Packer.pack()
// 4. upload changed chunk_*.dat + manifest.json
```

I split media from packing on purpose. Markdown that still says `../../../blobs/cover41.jpeg` is a local path. Markdown that will be sliced out of a chunk and served from anywhere needs a URL that still works when the API host does not have that jpeg.

## Authoring is boring, on purpose

Posts live under `BLOG_INPUT_DIR`. In this repo `.env` sets that to `pages`, so you get:

- `pages/blog/**` — posts. Nested folders become nested slugs.
- `pages/profile.md` — the profile page.

YAML frontmatter is optional but the UI is nicer with it: `title`, `summary`, `authors`, `date`, `topics`, `image`, `highlight`.

This file you are reading is `pages/blog/guides/scorpio/packing-markdown.md`. After pack the slug is `blog/guides/scorpio/packing-markdown`. The frontend route is `/posts/` plus that slug.

## Images first, then videos

The media processor walks every `.md` / `.markdown` file. It looks for markdown images and `<img>` / `<video>` / `<source>` tags.

Remote URLs stay as they are. `https://…` is already someone else's problem.

Local paths get resolved against the post directory, then staging, then the asset root, then cwd. Bytes are hashed. If the hash is new or you marked the tag `data-scorpio="update"`, we upload to Cloudinary and rewrite the URL in a copy of the markdown under `packed/staging/`.

There is a small lifecycle on those tags:

```zig
pub const Lifecycle = enum {
    keep,
    delete,
    update,
};
```

`keep` is the default. `update` forces a re-upload even if the hash matches the sidecar. `delete` can remove the local file after a successful rewrite. I used `data-scorpio="keep"` on the Hercules header video so the packer would stop being clever.

Two sidecar files land in staging: `images-links.json` and `videos-links.json`. They remember public ids and hashes so the next pack does not re-upload every cover. They are not packed into chunks. They are just the packer's memory.

Videos run after images, on the staging tree, same idea, different extensions (`.mp4`, `.webm`, `.mov`, …).

## The part the README gets wrong

The README says Cloudinary failures skip with a warning.

That is true for **phase 4**, the raw upload of `chunk_0000.dat` and `manifest.json`. Local artifacts stay. The API can still boot.

It is **not** true for media. `try img.run()` and `try vid.run()` abort the whole pack if Cloudinary returns 401. I found that the hard way with demo credentials. If your posts only use remote images you are fine. If they reference `blobs/cover41.jpeg`, you need real keys or the pack never reaches the packer.

I should make media failures warn too. I have not.

## Then the tree is just files

`Directory.load(staging_dir)` walks staging into a flat list of files and folders. I wrote about that instinct in [flat resource loading](/posts/blog/projects/flat-resource-loading). The packer does not care that yesterday this was `pages/`. It cares about relative paths and mtimes.

`Packer.pack()` turns that list into chunks and a manifest. That is [part 2](/posts/blog/guides/scorpio/manifest-and-chunks).

After that, changed chunks go up as Cloudinary `raw` uploads. Public id looks like `{CLOUDINARY_PACK_PREFIX}/chunk_0000.dat`. Manifest last. Failures here log and continue.

## What I type after I edit a post

```bash
zig build pack
# or just
zig build run   # pack → prerun → listen, because of build.zig deps
```

Docker is lazier. The API entrypoint packs only if `manifest.json` is missing, or you set `FORCE_PACK=1`. `zig build run` always packs. I forget that difference every few weeks.

Next: [the manifest and the chunks](/posts/blog/guides/scorpio/manifest-and-chunks).
