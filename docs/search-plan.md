# Full-Content Search — Plan

Goal: search every message you've ever sent or received, faster and more complete
than Messages itself. Filter by person, time, sender, and source.

Measured on Jordan's Mac (1.15M messages, 1.8 GB chat.db): index is **115 MB**,
full build **~21 s** (once), incremental sync **&lt;0.1 s**, queries **1–13 ms**.
Small enough to always-on — no opt-in needed; add a "Rebuild index" escape hatch
in Settings instead.

## Already built (compiles, service verified against real chat.db)

- `Services/SearchIndex.swift` — FTS5 sidecar DB in
  `~/Library/Application Support/Besties/search.sqlite`. Incremental sync keyed
  on message rowid; auto-rebuild if chat.db is replaced; tapbacks and
  text-free messages excluded. Reuses `MessageStore.decodeBody` (now internal)
  for `attributedBody` blobs. Search supports: quoted-term escaping,
  prefix-match on last word (search-as-you-type), person (chat IDs), date
  range, from me/them, sort by relevance (bm25) / newest / oldest, total match
  count, highlighted snippets.
- `MessageStore.fetchChatInfos()` — maps a search hit's chat_id back to a
  person (1:1 handle) or group.
- `AppState` — background sync on launch with progress; `chatInfoByID` +
  `iMessageConvoByHandleID` lookup tables.
- `Views/SearchView.swift` + a new **Search** tab in ContentView — big query
  field, filter chips (person picker with type-ahead, time menu incl. specific
  years, From: Anyone/Me/Them, sort), result rows with avatar/name/date/
  sun-highlighted snippet, "You:" prefix on sent, match count, indexing
  progress state, empty states. Clicking a result opens the existing
  ConversationReaderView anchored at that exact message.

## Phase 1 — Verify and polish v1 (done)

1. ⌘F (Edit ▸ Find) switches to the Search tab and focuses the field, from
   any tab and when already on Search.
2. Query edge cases, run against the real 1.07M-message index: apostrophes,
   stray/unbalanced quotes, diacritics, punctuation-only, single characters,
   100-term and 500-character queries, CJK, URLs, emails. Nothing errors and
   nothing can inject FTS5 syntax (every term is quoted and `"` doubled).
   Emoji are simply not indexed — `unicode61` treats them as separators, so
   "😂" finds nothing and "lol 😂" behaves like "lol" (see Phase 2).
3. Person filter for someone with no indexed iMessage chats (WhatsApp-only)
   passes an empty chat-id list, which becomes `AND 0` → zero results.
4. Group-chat results open the reader scoped to that chat (ReaderTarget can
   carry chat ids directly). Bubbles still don't name the sender, and chats
   with no `display_name` all read "Group chat".
5. Deleted/edited messages: index keeps rows chat.db deleted. Acceptable for
   v1 ("deleted messages still searchable" is arguably a feature); Settings
   has a "Rebuild search index" button whose note says so.

## Phase 2 — WhatsApp in the index (done, except item 5)

WhatsApp is already a first-class source everywhere else in the app; search
now matches. 18,160 WhatsApp messages join 1,069,077 iMessage ones; full
rebuild still ~20 s.

1. `msgs` has a `source` column ('i'/'w'), schema_version 2 — an older index
   is dropped (not just emptied, the columns differ) and rebuilt on first open.
2. Ingested straight from `ChatStorage.sqlite` (`WhatsAppStore.dbPath`, now
   shared), keyed by ZWAMESSAGE Z_PK with a `wa_last_rowid` cursor, skipping
   empty bodies. Only 1:1 sessions, matching the app-wide WhatsApp rule — so
   every hit maps to a person. A relinked WhatsApp restarts Z_PKs at 1; that
   drops and reindexes only the `source='w'` rows.
3. **chat.db rowids and Z_PKs collide** (chat id 17 is a real chat in both
   here), so: WhatsApp ids are stored shifted by `1 << 40` to keep `msgs.id`
   unique, `Result` carries its source and its `id` is "source-rowid", and
   chat filtering takes `[ChatRef(source:id:)]` grouped into per-source
   `IN` lists.
4. Source filter (All / Messages / WhatsApp) in the filter bar, shown only
   when WhatsApp is installed *and* enabled. WhatsApp is always indexed;
   turning the setting off pins the query to `source = 'i'` instead, so
   flipping it needs no reindex. Results rows don't badge their source.
5. **Not done** — emoji, ideally folded into this same rebuild:
   `tokenize='unicode61 remove_diacritics 2 categories "L* N* Co So"'` makes
   😂 a searchable token. Trade-off measured in SQLite: "lol😂" then tokenizes
   as one word, so a mid-query "lol" no longer matches it (only the trailing
   prefix term would). Doing it later costs users a second full rebuild.

## Phase 3 — Richer filters + quality (done, except item 3)

1. `msgs` carries `has_attachment` and `has_link`, schema_version 3 (one more
   full rebuild). Attachments come from `cache_has_attachments` / WhatsApp's
   `ZMEDIAITEM IS NOT NULL`; both verified row-for-row against their source.
   Note attachment-*only* messages still aren't indexed — they have no text —
   so "Has attachment" means "text **and** an attachment" (31k iMessage, 11k
   WhatsApp here). Links are detected at index time from "http://",
   "https://", and a word-starting "www." (so "awww. that's sweet" isn't a
   link) — `String.range(of:options:)` cost 13 s of the rebuild,
   so it's an 8-byte sliding window over the UTF-8 instead (~0.1 s, identical
   results on 300k real messages). Both are one Menu in the filter bar.
2. Pagination: "Show 200 more" appends the next page. Every sort order now
   breaks ties on `m.id`, which makes plain `LIMIT/OFFSET` exact — walking
   six pages returns byte-for-byte what one big query does, no dupes, for
   all three sorts.
3. **Not done** — result grouping by person ("34 matches with Sam").
4. In-conversation search: a magnifying glass in the reader header opens a
   field that searches the index scoped to `ReaderModel.chatRefs` (that
   person's iMessage chats + WhatsApp sessions, or the group's chat), newest
   first. Picking a match moves the scrubber and jumps the transcript.
5. The matched bubble gets a sun ring + glow that fades after ~1.6 s, both
   from in-reader search and when Search opens the reader
   (`ReaderTarget.anchorMessageID`). The jump lands on the exact message:
   `chat_message_join.message_date` and `message.date` never disagree in
   chat.db (0 rows), and 60/60 hits per source were the first message at
   their anchor.

## Later / maybe (unscoped)

- Semantic search ("that message about the cabin trip") via on-device
  embeddings — big win, real project; index size grows ~4× with vectors.
- OCR of image attachments into the index.
- Regex / exact-phrase power syntax (FTS5 already supports `"exact phrase"`
  — just document it).

## Release notes

- Index lives outside the repo and outside the app bundle; nothing changes in
  release.sh or the DMG.
- First launch after update triggers the one-time ~21 s index build — the
  progress state in the Search tab covers this.
