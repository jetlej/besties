#!/usr/bin/env node
// Re-score saved results with the current fixtures/scorer (no new requests).
//   node rescore.mjs results/a.json [results/b.json …]
import { readFileSync } from "node:fs";
import { allFixtures } from "./fixtures.mjs";
import { score } from "./score.mjs";
import { report } from "./report.mjs";

const byId = Object.fromEntries(allFixtures().map((f) => [f.id, f]));
const rows = process.argv.slice(2).flatMap((file) => JSON.parse(readFileSync(file, "utf8")).results);
for (const r of rows) if (!r.error && byId[r.case]) Object.assign(r, score(byId[r.case], r.text));
console.log(await report(rows, { pricedAt: false }));
