#!/usr/bin/env python3
"""Turn real conversations from this Mac's Messages history into private
benchmark cases (litmus tests with answers you know are right).

Runs on your Mac only. It reads ~/Library/Messages/chat.db read-only, so the
app running it (Terminal, iTerm) needs Full Disk Access. Output goes to
private/cases.json, which is gitignored: it holds your real messages, so
never commit or share it.

  # a month to summarize, with facts a good summary must mention
  python3 export_real.py summary --handle +15551234567 --name "Mia" --month 2025-03 \
      --fact "Lisbon trip=lisbon" --fact "her new job=bakery|crumb" \
      --forbid "says they went to Porto=went to porto"

  # a hello draft from the last 200 messages, with threads it should pick up
  python3 export_real.py hello --handle alex@example.com --name "Alex" \
      --fact "the marathon=marathon|chicago"

Facts are "label=regex" (case-insensitive). Then run the benchmark on them:
  node bench.mjs --fixtures private/cases.json --preset cheap --runs 3
Note this sends those conversations to every model you benchmark.
"""
import argparse
import json
import os
import sqlite3
import sys
from datetime import datetime, timedelta, timezone

APPLE_EPOCH = datetime(2001, 1, 1, tzinfo=timezone.utc)
HERE = os.path.dirname(os.path.abspath(__file__))


def decode_body(text, blob):
    """Message text: the `text` column, or (most newer messages) the string
    inside the attributedBody typedstream blob."""
    if text:
        return text
    if not blob:
        return None
    try:
        rest = blob.split(b"NSString", 1)[1][5:]
        if rest[0] == 0x81:
            length, rest = int.from_bytes(rest[1:3], "little"), rest[3:]
        else:
            length, rest = rest[0], rest[1:]
        return rest[:length].decode("utf-8", "replace")
    except (IndexError, ValueError):
        return None


def to_local(raw):
    seconds = raw / 1e9 if raw > 1e12 else raw
    return (APPLE_EPOCH + timedelta(seconds=seconds)).astimezone()


def fetch(handles, since=None, until=None, last=None):
    db = sqlite3.connect(f"file:{os.path.expanduser('~/Library/Messages/chat.db')}?mode=ro", uri=True)
    marks = ",".join("?" * len(handles))
    sql = f"""
        SELECT m.date, m.is_from_me, m.text, m.attributedBody, m.cache_has_attachments
        FROM message m
        JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        JOIN chat c ON c.ROWID = cmj.chat_id
        WHERE c.chat_identifier IN ({marks})
          AND m.item_type = 0 AND m.associated_message_type = 0
        ORDER BY m.date {"DESC" if last else "ASC"}
    """
    out = []
    for date, from_me, text, blob, has_attachment in db.execute(sql, handles):
        when = to_local(date)
        if since and when < since:
            continue
        if until and when >= until:
            continue
        body = decode_body(text, blob)
        body = body.replace("￼", "").strip() if body else ""
        if not body:
            if not has_attachment:
                continue
            body = "[attachment]"
        out.append([when.strftime("%Y-%m-%d %H:%M"), "m" if from_me else "t", body])
        if last and len(out) >= last:
            break
    return out if not last else list(reversed(out))


def pairs(values):
    result = []
    for value in values or []:
        label, _, pattern = value.partition("=")
        if not pattern:
            sys.exit(f'--fact/--forbid needs "label=regex", got {value!r}')
        result.append([label.strip(), pattern.strip()])
    return result


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("kind", choices=["summary", "hello"])
    p.add_argument("--handle", action="append", required=True,
                   help="phone (+15551234567) or email as Messages stores it; repeat for several")
    p.add_argument("--name", required=True, help="what to call them in the prompt (as the app would)")
    p.add_argument("--month", help="summary: yyyy-mm")
    p.add_argument("--fact", action="append", help='"label=regex" a good answer must match')
    p.add_argument("--forbid", action="append", help='"label=regex" a good answer must NOT match')
    p.add_argument("--out", default=os.path.join(HERE, "private", "cases.json"))
    args = p.parse_args()

    case = {"kind": args.kind, "name": args.name, "them": args.name,
            "facts": pairs(args.fact), "forbidden": pairs(args.forbid)}
    if args.kind == "summary":
        if not args.month:
            sys.exit("summary needs --month yyyy-mm")
        year, month = map(int, args.month.split("-"))
        start = datetime(year, month, 1).astimezone()
        end = datetime(year + (month == 12), month % 12 + 1, 1).astimezone()
        case.update(year=year, month=month, messages=fetch(args.handle, since=start, until=end))
        case["id"] = f"real-summary-{args.name}-{args.month}".lower().replace(" ", "-")
    else:
        case["messages"] = fetch(args.handle, last=200)
        case["id"] = f"real-hello-{args.name}".lower().replace(" ", "-")
    if not case["messages"]:
        sys.exit("No messages found. Check --handle (as stored in Messages) and --month.")

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    cases = json.load(open(args.out)) if os.path.exists(args.out) else []
    cases = [c for c in cases if c["id"] != case["id"]] + [case]
    with open(args.out, "w") as f:
        json.dump(cases, f, ensure_ascii=False, indent=1)
    print(f"{case['id']}: {len(case['messages'])} messages, {len(case['facts'])} facts → {args.out}")


if __name__ == "__main__":
    main()
