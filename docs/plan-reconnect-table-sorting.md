# Plan: Reconnect table column sorting

**Bug report:** "sorting is broken though — the top columns don't sort."
**Cause:** Sorting was never implemented. The `Table` in `ContentView.swift` (`reconnectTable`, ~line 387) has no `sortOrder` binding and every `TableColumn` uses the closure-only initializer, so macOS renders clickable-looking headers that do nothing.
**Goal:** Clicking Name / Last Message / Messages / Score headers sorts the table (with the standard macOS sort arrow, click again to reverse). Default order stays score-descending, matching today's behavior.

**Estimate:** ~15 minutes including build + manual verify. One file changed: `Besties/Besties/Views/ContentView.swift`.

---

## Background facts (verified in code)

- Row type is `Conversation` ([Models/Conversation.swift](../Besties/Besties/Models/Conversation.swift)). All four displayed values are `Comparable` and reachable by key path:
  - `resolvedName: String` (computed — key paths to computed properties work fine with `KeyPathComparator`)
  - `daysSinceLastMessage: Int` (computed from `lastMessageDate`)
  - `totalMessages: Int`
  - `score: Double`
- Data source: `filteredReconnect` → `appState.reconnectConversations(maxDays:)` → `ConversationAnalyzer.score(...)`, which pre-sorts by `score` descending (`ConversationAnalyzer.swift:57`). That stays untouched; it just becomes the order the default comparator reproduces.
- The fifth column (message-bubble button) has no sortable value and stays closure-only. Mixing sortable and non-sortable columns is supported.

## Changes (all in ContentView.swift)

### 1. Add sort state

```swift
@State private var sortOrder = [KeyPathComparator(\Conversation.score, order: .reverse)]
```

Initial value = score descending, so first launch looks identical to today.

### 2. Bind it to the table

```swift
Table(filteredReconnect, sortOrder: $sortOrder) {
```

### 3. Make the four data columns sortable

Add `value:` key paths, keeping the existing cell closures (labels like "12d ago" and the `ScoreCell` stay as they are):

```swift
TableColumn("Name", value: \.resolvedName) { convo in ... }
TableColumn("Last Message", value: \.daysSinceLastMessage) { convo in ... }
TableColumn("Messages", value: \.totalMessages) { convo in ... }
TableColumn("Score", value: \.score) { convo in ... }
```

Notes:
- **Last Message** sorts on `daysSinceLastMessage` because that's the number displayed — ascending = most recent first, arrow direction matches what the user sees. (Sorting on `lastMessageDate` would invert the arrow's meaning.)
- **Name** should compare human names sensibly (case-insensitive, "Élise" ordered right). Use:
  ```swift
  TableColumn("Name", value: \.resolvedName, comparator: .localizedStandard) { ... }
  ```
- Button column: unchanged, no `value:`.

### 4. Apply the sort to the data

`Table` only stores the clicked order in the binding; the app applies it:

```swift
private var filteredReconnect: [Conversation] {
    appState.reconnectConversations(maxDays: selectedRange.rawValue)
        .filter(matchesSearch)
        .sorted(using: sortOrder)
}
```

## Explicitly out of scope

- No persistence of the chosen sort across launches (add later via `@AppStorage` if wanted).
- No changes to `ConversationAnalyzer`, merge logic, or search.
- Row tap-to-open-reader (`onTapGesture` in the Name cell) is untouched; header clicks and row clicks don't conflict.

## Risks / gotchas

- `daysSinceLastMessage` computes via `Calendar` on every comparison. At leaderboard scale (hundreds to low thousands of rows) this is fine; if it ever shows up in profiling, switch the comparator to `\.lastMessageDate` with `.reverse` semantics.
- If the compiler can't infer the comparator array type from mixed key paths (String/Int/Double all reduce to `KeyPathComparator<Conversation>`, so it should), annotate the `@State` explicitly: `@State private var sortOrder: [KeyPathComparator<Conversation>] = [...]`.

## Verification

1. Build: `xcodebuild -project Besties/Besties.xcodeproj -scheme Besties build` (or ⌘B) — compiles clean.
2. Run the app → Reconnect table:
   - Default order unchanged (highest score first, no arrow shown until a header is clicked — expected, since default comes from state, which does show the arrow on Score ▾).
   - Click **Name** → A→Z, click again → Z→A.
   - Click **Last Message** → smallest "d ago" first, toggles.
   - Click **Messages**, **Score** → numeric toggle.
   - Click the button column header → nothing happens (not sortable, no arrow).
3. Type in search while sorted → results stay in the chosen order.
4. Click a name cell → still opens the reader.
