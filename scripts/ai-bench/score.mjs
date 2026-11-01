// Automatic scoring. An answer earns a point per planted fact it mentions
// and per format/style check it passes, and loses a point per forbidden
// claim. Score = points / possible × 100. "Pass" = no forbidden claims,
// every fact present, every check passed.

const EMOJI = /\p{Extended_Pictographic}/u;
// \b is ASCII-only in JS, so accented words need letter lookarounds.
const SPANISH = /(?<!\p{L})(qué|que|hola|cómo|como|está|estás|hace|mucho|tiempo|tu|tú|te|la|el|los|las|un|una|es|eso|sería|y|con|para|por|ya|muy|mi|jaja)(?!\p{L})/giu;
const ENGLISH = /\b(the|and|how|you|your|what|have|been|hope)\b/gi;

export function cleanAnswer(text) {
  return String(text || "")
    .replace(/<think>[\s\S]*?<\/think>/gi, "")   // local reasoning models
    .trim();
}

export function score(f, raw) {
  const text = cleanAnswer(raw);
  const checks = [];
  const add = (name, ok) => checks.push({ name, ok: Boolean(ok) });

  for (const [name, re] of f.facts) add(`fact: ${name}`, re.test(text));

  if (f.kind === "summary") {
    const words = text.split(/\s+/).filter(Boolean).length;
    add(`≤ ${f.maxWords ?? 260} words (${words})`, words > 0 && words <= (f.maxWords ?? 260));
    add("talks to the reader as “you”", /\byou(r)?\b/i.test(text));
    add("no “the user/reader”", !/\bthe (user|reader)\b/i.test(text));
  } else {
    const sentences = text.split(/[.!?¡¿]+(\s|$)/).filter((s) => s && s.trim().length > 1).length;
    add(`≤ 320 chars (${text.length})`, text.length > 0 && text.length <= 320);
    add("just the message (no preamble/quotes/options)",
      !/^(here('s| is)|sure|draft|message:|option|\*\*)/i.test(text)
      && !/^["“].*["”]$/s.test(text) && !/\n\s*\n/.test(text));
    add(`≤ 3 sentences (${sentences})`, sentences <= 3);
    const s = f.style || {};
    if (s.lowercase) {
      const letters = text.replace(/\bI\b/g, "").match(/\p{L}/gu) || [];
      const upper = letters.filter((c) => c !== c.toLowerCase()).length;
      add("matches lowercase style", letters.length && upper / letters.length <= 0.03);
    }
    if (s.emoji === true) add("uses emoji like the user", EMOJI.test(text));
    if (s.emoji === false) add("no emoji (user never uses them)", !EMOJI.test(text));
    if (s.capitalized) add("proper capitalization", /^[A-ZÁÉÍÓÚ¡¿]/.test(text));
    if (s.noSlang) add("no slang (lol/haha/omg)", !/\b(lol|haha|omg|lmao)\b/i.test(text));
    if (s.language === "es") {
      const es = (text.match(SPANISH) || []).length;
      const en = (text.match(ENGLISH) || []).length;
      add("written in Spanish", es >= 2 && en <= 1);
    }
  }

  const hallucinations = (f.forbidden || []).filter(([, re]) => re.test(text)).map(([name]) => name);
  const possible = checks.length;
  const earned = checks.filter((c) => c.ok).length - hallucinations.length;
  return {
    score: Math.max(0, Math.round((earned / possible) * 100)),
    pass: hallucinations.length === 0 && checks.every((c) => c.ok),
    failed: checks.filter((c) => !c.ok).map((c) => c.name),
    hallucinations,
    text,
  };
}
