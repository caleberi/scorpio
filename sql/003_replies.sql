CREATE TABLE IF NOT EXISTS replies (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    comment_id UUID NOT NULL REFERENCES comments(id) ON DELETE CASCADE,
    blog_id UUID NOT NULL REFERENCES blogs(id) ON DELETE CASCADE,
    author TEXT NOT NULL,
    body TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS replies_comment_id_idx ON replies(comment_id);
CREATE INDEX IF NOT EXISTS replies_blog_id_idx ON replies(blog_id);
