CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Blog identity only (markdown lives in packed Cloudinary assets).
CREATE TABLE IF NOT EXISTS blogs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    slug TEXT NOT NULL UNIQUE,
    path TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
