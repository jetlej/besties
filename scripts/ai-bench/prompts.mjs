// Benchmark requests: a one-shot month recap and a drafted hello, the core
// skills behind the AI tab's reports and reconnect drafts. (The app's own
// prompts are tool-driven — AIPrompt.swift / AIReports.swift — so these
// measure model quality on the task, not the exact production prompt.)

const MONTHS = ["January", "February", "March", "April", "May", "June", "July",
  "August", "September", "October", "November", "December"];

const pad = (n) => String(n).padStart(2, "0");

// Messages are [day, "HH:MM", who, text] within the fixture's month, or
// ["yyyy-MM-dd HH:mm", who, text] (real cases from export_real.py).
function parts(f, m) {
  if (m.length === 3) return { stamp: m[0], who: m[1], text: m[2] };
  return { stamp: `${f.year}-${pad(f.month)}-${pad(m[0])} ${m[1]}`, who: m[2], text: m[3] };
}

export function messageDate(f, m) {
  return new Date(parts(f, m).stamp.replace(" ", "T") + ":00");
}

const WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

// One "Sun 2021-03-14" header per day, then "21:41 Me: text" lines.
function transcript(f, messages) {
  const lines = [];
  let currentDay = "";
  for (const m of messages) {
    const { stamp, who, text } = parts(f, m);
    const [ymd, hhmm] = stamp.split(" ");
    const day = `${WEEKDAYS[new Date(`${ymd}T12:00:00`).getDay()]} ${ymd}`;
    if (day !== currentDay) {
      if (currentDay) lines.push("");
      lines.push(day);
      currentDay = day;
    }
    const body = text === "[attachment]" ? "(sent an attachment)" : text;
    lines.push(`${hhmm} ${who === "m" ? "Me" : f.them}: ${body}`);
  }
  return lines.join("\n");
}

// Cap on a month: stop at 2,000 messages or when text + 30 chars per message
// passes the budget (use --char-budget 12000 for small local models, whose
// default 8K context otherwise silently drops the start of the prompt).
function monthSlice(f, charBudget = 300_000) {
  const out = [];
  let chars = 0;
  for (const m of f.messages) {
    const { text } = parts(f, m);
    if (out.length >= 2000 || (out.length && chars + text.length > charBudget)) return { messages: out, capped: true };
    out.push(m);
    chars += text.length + 30;
  }
  return { messages: out, capped: false };
}

export function summaryRequest(f, { charBudget } = {}) {
  const monthLabel = `${MONTHS[f.month - 1]} ${f.year}`;
  const who = f.them === f.name
    ? `Address the reader as "you" and call the other person ${f.name}.`
    : `This is the group chat "${f.name}"; the reader's lines are marked Me and everyone else's ${f.them}. Address the reader as "you".`;
  const system = "You help someone look back on their own text messages. "
    + `Write a warm, specific recap of their conversations ${f.them === f.name ? "with" : "in"} ${f.name} during ${monthLabel}: `
    + "the main things they talked about, plans they made, jokes, and how things felt. "
    + `${who} `
    + "Keep it under 200 words, in short paragraphs or a few bullet points. "
    + "Only use what's in the messages. Don't invent details.";
  const { messages, capped } = monthSlice(f, charBudget);
  let prompt = `Messages with ${f.name} in ${monthLabel}`;
  if (capped) prompt += ` (the first ${messages.length.toLocaleString("en-US")} of the month; there were more)`;
  prompt += `:\n\n${transcript(f, messages)}\n\nNow write the recap, following the instructions.`;
  return { system, prompt };
}

export function helloRequest(f, now = new Date()) {
  const last = messageDate(f, f.messages[f.messages.length - 1]);
  const gap = Math.floor((now - last) / 86400000);
  const system = "You help someone reconnect with a person they've drifted from. Using their message history, "
    + `draft one short text they could send ${f.name} now, about ${gap} days after they last talked. `
    + "Make it specific: pick up a real thread, plan, or joke from the history. "
    + "Match how the user writes in these messages: length, capitalization, punctuation, emoji. "
    + "One to three sentences. Reply with only the message text, nothing else.";
  const prompt = `Their most recent messages with ${f.name}, oldest first:\n\n${transcript(f, f.messages)}`
    + `\n\nNow write the text to ${f.name}. Reply with only the message.`;
  return { system, prompt };
}

export const requestFor = (f, opts) => (f.kind === "summary" ? summaryRequest(f, opts) : helloRequest(f));
