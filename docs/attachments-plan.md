# Photos & Videos in Messages — Plan

Goal: bubbles that say "[attachment]" instead show the actual photo/video, in
the conversation reader and in search results.

Measured on Jordan's Mac:

- **101,328 iMessage attachments** (100,255 with a file path), ~34 GB in
  `~/Library/Messages/Attachments`. By type: 20,991 JPEG · 10,341 PNG ·
  6,418 HEIC · 2,949 QuickTime · 1,684 GIF · 347 PDF. The other ~57k rows
  have no mime type — mostly stickers, link previews, and plugin payloads.
- **Only ~14% of attachment files exist on disk** (28/200 sampled). iCloud's
  "Optimize Mac Storage" offloads the originals and there is no public API to
  pull them back — the placeholder state is a first-class case, not an edge.
- **WhatsApp media: 5.3 GB locally** in the Group Container (`ZWAMEDIAITEM.
  ZMEDIALOCALPATH`), much higher local availability since WhatsApp doesn't
  offload.

Constraints that shape everything: chat.db and media files stay read-only; we
never copy originals (34 GB); thumbnails are generated lazily and cached small.

## Phase 1 — Photos in the reader (~1 day)

1. `MessageStore.fetchAttachments(messageRowIDs:)` — join
   `message_attachment_join` → `attachment`, returning path + mime + bytes
   per message. Fold into the reader's page fetch (one extra query per page,
   not per message).
2. Thumbnail pipeline: `QLThumbnailGenerator` (handles HEIC/JPEG/PNG/GIF/
   video posters natively), async, `NSCache` in memory + small JPEG disk cache
   in Application Support (cap ~200 MB, LRU). Never decode originals on the
   main thread.
3. Bubble UI: image thumbnail (max ~220pt) in place of the "[attachment]"
   text, rounded to match bubbles; text+image messages show both. Click →
   Quick Look panel (`QLPreviewPanel`) on the original file.
4. The missing-file state: a neutral tan placeholder ("In iCloud") — no
   broken-image icons, no layout shift when a thumb loads late.
5. Verify against the real DB: a page with mixed present/offloaded files,
   HEIC decode, scroll performance with 100 thumbs in the window.

## Phase 2 — Videos, GIFs, WhatsApp (~half a day)

1. Videos: poster-frame thumbnail with a play badge; click opens Quick Look
   (plays inline there — no in-bubble player needed).
2. GIFs: static thumb in the transcript; animate in Quick Look.
3. WhatsApp media via `ZWAMEDIAITEM.ZMEDIALOCALPATH` (paths are relative to
   the Group Container), same pipeline and placeholder rules.
4. PDFs and other docs: filename + icon chip, click → Quick Look.

## Phase 3 — Media in search + per-person grid (~1 day)

1. Search result rows for has-attachment hits get a small thumbnail on the
   right edge; the existing "Has attachment" filter becomes visibly useful.
2. "Media" view in the reader: a photo grid of the whole conversation
   (attachment rows for that chat, newest first, same thumbnail cache),
   click → jump the transcript to that message. This is the "our photos"
   nostalgia feature and likely the emotional payoff of the whole phase.
3. Attachment-only messages are currently *not* in the search index (no
   text). Index them with an empty body + flags so "Has attachment" search
   scoped to a person/date actually finds them (schema bump → one ~20s
   rebuild; batch it with the pending emoji-tokenizer bump so users only
   rebuild once).

## Later / maybe

- OCR image text into the search index (Vision framework) — searches
  screenshots, the single most-requested flavor of "find that message".
- Offloaded originals: detect and deep-link into Messages.app on the right
  conversation as a "get the full-res version" escape hatch.

## Release notes

- Thumbnail cache is new disk usage (~200 MB cap) in Application Support —
  worth a line in Settings next to Rebuild search index.
- No changes to signing/entitlements: same Full Disk Access read path
  already covers Attachments and the WhatsApp container.
