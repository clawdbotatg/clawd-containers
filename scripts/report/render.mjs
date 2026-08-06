#!/usr/bin/env node
// render.mjs — turn a leftclaw audit-report markdown file into a pretty,
// self-contained HTML page using template.html.
//
// Usage:
//   node render.mjs --job 400 --md report.md --ipfs https://bafy....ipfs.community.bgipfs.com/ -o 400.html
//
// No npm install needed: marked is vendored at vendor/marked.umd.js.
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { createRequire } from "node:module";

const HERE = dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);
const { marked } = require(join(HERE, "vendor", "marked.umd.js"));

// ---------- args ----------
const args = {};
for (let i = 2; i < process.argv.length; i++) {
  const a = process.argv[i];
  if (a === "--job") args.job = process.argv[++i];
  else if (a === "--md") args.md = process.argv[++i];
  else if (a === "--ipfs") args.ipfs = process.argv[++i];
  else if (a === "-o" || a === "--out") args.out = process.argv[++i];
}
if (!args.job || !args.md || !args.ipfs || !args.out) {
  console.error("usage: render.mjs --job <id> --md <report.md> --ipfs <url> -o <out.html>");
  process.exit(2);
}

let md = readFileSync(args.md, "utf8");
const template = readFileSync(join(HERE, "template.html"), "utf8");

// Printout cleanup: if the doc opens with plain prose (leaked agent monologue,
// e.g. job 237) rather than a heading or blockquote preamble, start at the
// first heading. The canonical IPFS copy is linked and unchanged.
if (!/^\s*(#|>)/.test(md)) {
  const i = md.search(/^#{1,2}\s/m);
  if (i > 0) md = md.slice(i);
}

// ---------- title: first h1 in the markdown ----------
const titleMatch = md.match(/^#\s+(.+)$/m);
let title = titleMatch ? titleMatch[1].trim() : `Audit Report — Job #${args.job}`;
// Masthead already says "Smart Contract Audit" — strip redundant prefixes/emoji.
const AUDIT_WORDS = /Security\s+(?:Audit|Review)(?:\s+Report)?|Smart\s+Contract\s+Audit(?:\s+Report)?|Unified\s+(?:Two-Phase\s+)?Security\s+Audit/;
title = title
  .replace(/^[\p{Extended_Pictographic}️\s]+/u, "")
  .replace(new RegExp(`^(?:${AUDIT_WORDS.source})\\s*[—–:-]\\s*`, "i"), "")
  .replace(new RegExp(`\\s*[—–:-]\\s*(?:${AUDIT_WORDS.source})$`, "i"), "");
const esc = s => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

// ---------- severity counts: one per "**Severity**: X" finding line ----------
const SEVS = ["Critical", "High", "Medium", "Low", "Info"];
const counts = { Critical: 0, High: 0, Medium: 0, Low: 0, Info: 0 };
const norm = raw => (/^info/i.test(raw) ? "Info" : raw[0].toUpperCase() + raw.slice(1).toLowerCase());

// Preferred signal: the report's own tally line, e.g.
//   **Severity counts:** 1 Critical · 3 High · 11 Medium · 14 Low · 12 Informational · 9 Leads.
// It is authoritative and immune to the per-finding prose drift below. Any
// trailing non-severity bucket ("9 Leads") simply doesn't match.
const tally = md.match(/\*\*Severity counts:?\*\*:?\s*([^\n]+)/i);
if (tally) {
  for (const m of tally[1].matchAll(/(\d+)\s*(Critical|High|Medium|Low|Informational|Info)\b/gi)) {
    counts[norm(m[2])] += Number(m[1]);
  }
}

// Per-finding lines. Formats vary: "**Severity**: X", "**Severity:** X" (colon
// inside the bold), "**Severity: X**" (value inside the bold), and
// "**Severity.** X rather than Y" (period, value outside the bold — job 568),
// and "Severity: **X**" (plain label, bolded value — job 565's inline
// "Confidence: 70 · Severity: **Medium**" metadata run).
const SEV_RE = /\*\*Severity[:.]?\*\*[:.]?\s*(Critical|High|Medium|Low|Informational|Info)\b|\*\*Severity:\s*(Critical|High|Medium|Low|Informational|Info)\*\*|(?:^|[^*])Severity:\s*\*\*(Critical|High|Medium|Low|Informational|Info)\*\*/gi;
if (Object.values(counts).every(n => n === 0)) {
  for (const m of md.matchAll(SEV_RE)) counts[norm(m[1] || m[2] || m[3])]++;
}

// Structural fallback: findings whose heading tags severity in the id, e.g.
// "### [C-1] …", "### [H-2] …". More reliable than prose when a report writes
// "**Severity rationale.** Rated High rather than Critical" (which names two
// severities and belongs to neither counter above).
if (Object.values(counts).every(n => n === 0)) {
  const BY_ID = { C: "Critical", H: "High", M: "Medium", L: "Low", I: "Info" };
  for (const m of md.matchAll(/^#{2,4}\s*\[([CHMLI])-\d+\]/gm)) counts[BY_ID[m[1]]]++;
}

// ---------- markdown -> html ----------
// breaks:true — the reports use single newlines for metadata line blocks
// (**Job**: / **Target**: / **Severity**: …); without it they mash into one paragraph.
marked.setOptions({ gfm: true, breaks: true });
let body = marked.parse(md);

// Minimal sanitize: this is our own auditor's output, but it quotes strings
// from untrusted repos — strip anything that could execute on our domain.
body = body
  .replace(/<\s*(script|iframe|object|embed|form)\b[\s\S]*?<\s*\/\s*\1\s*>/gi, "")
  .replace(/<\s*(script|iframe|object|embed|form)\b[^>]*\/?>/gi, "")
  .replace(/\son\w+\s*=\s*(['"]).*?\1/gi, "")
  .replace(/(href|src)\s*=\s*(['"])\s*javascript:[^'"]*\2/gi, '$1="#"');

// Heading anchors (h2/h3) + TOC of h2s.
const slugCounts = {};
const slugify = t => {
  let s = t.toLowerCase().replace(/<[^>]+>/g, "").replace(/&[a-z#0-9]+;/g, "")
    .replace(/[^a-z0-9\s-]/g, "").trim().replace(/\s+/g, "-").slice(0, 64) || "section";
  slugCounts[s] = (slugCounts[s] || 0) + 1;
  return slugCounts[s] > 1 ? `${s}-${slugCounts[s]}` : s;
};
const tocItems = [];
body = body.replace(/<h([23])>([\s\S]*?)<\/h\1>/g, (_, lvl, inner) => {
  const id = slugify(inner);
  if (lvl === "2") tocItems.push({ id, text: inner.replace(/<[^>]+>/g, "") });
  return `<h${lvl} id="${id}">${inner}</h${lvl}>`;
});
let toc = "";
if (tocItems.length >= 3) {
  // Two explicit halves instead of CSS columns (which mis-render wrapped items in Chrome).
  const li = t => `      <li><a href="#${t.id}">${t.text}</a></li>`;
  const half = Math.ceil(tocItems.length / 2);
  const cols = [tocItems.slice(0, half), tocItems.slice(half)]
    .filter(c => c.length)
    .map((c, i) => `    <ol${i ? ` start="${half + 1}"` : ""}>\n${c.map(li).join("\n")}\n    </ol>`)
    .join("\n");
  toc = `<nav class="toc">\n    <div class="toc-title">Contents</div>\n    <div class="toc-cols">\n${cols}\n    </div>\n  </nav>`;
}

// Severity pills — inside table cells and after "**Severity**:" labels.
const pill = s => {
  const k = /^info/i.test(s) ? "info" : s.toLowerCase();
  const label = k === "info" ? "Info" : k[0].toUpperCase() + k.slice(1);
  return `<span class="pill ${k}">${label}</span>`;
};
body = body.replace(/<td>(Critical|High|Medium|Low|Informational|Info)<\/td>/gi, (_, s) => `<td>${pill(s)}</td>`);
body = body.replace(/(<strong>Severity[:.]?<\/strong>[:.]?\s*)(Critical|High|Medium|Low|Informational|Info)\b/gi,
  (_, pre, s) => `${pre}${pill(s)}`);
body = body.replace(/<strong>Severity:\s*(Critical|High|Medium|Low|Informational|Info)<\/strong>/gi,
  (_, s) => `<strong>Severity:</strong> ${pill(s)}`);
// "Severity: <strong>X</strong>" — plain label, bolded value (job 565).
body = body.replace(/(^|[^>])(Severity:\s*)<strong>(Critical|High|Medium|Low|Informational|Info)<\/strong>/gi,
  (_, pre, lbl, s) => `${pre}${lbl}${pill(s)}`);

// Severity strip: prefer per-finding "**Severity**:" lines; fall back to
// counting severity cells in the findings-summary table (some report formats
// only tabulate severities).
if (Object.values(counts).every(n => n === 0)) {
  for (const m of body.matchAll(/<td><span class="pill (critical|high|medium|low|info)">/g)) {
    counts[m[1] === "info" ? "Info" : m[1][0].toUpperCase() + m[1].slice(1)]++;
  }
}
const totalFindings = Object.values(counts).reduce((a, b) => a + b, 0);
let sevStrip = "";
if (totalFindings > 0) {
  const cards = SEVS.filter(s => counts[s] > 0)
    .map(s => `<div class="sev-card ${s.toLowerCase()}"><div class="n">${counts[s]}</div><div class="l">${s}</div></div>`)
    .join("\n      ");
  sevStrip = `<div class="sev-strip">\n      ${cards}\n    </div>`;
}

// Wrap tables for horizontal scroll on small screens.
body = body.replace(/<table>/g, '<div class="table-wrap"><table>').replace(/<\/table>/g, "</table></div>");

// ---------- assemble ----------
const now = new Date().toISOString().slice(0, 10);
const html = template
  .replaceAll("{{TITLE}}", esc(title))
  .replaceAll("{{JOB_ID}}", esc(String(args.job)))
  .replaceAll("{{JOB_URL}}", esc(`https://leftclaw.services/jobs/${args.job}`))
  .replaceAll("{{IPFS_URL}}", esc(args.ipfs))
  .replaceAll("{{GENERATED_DATE}}", now)
  .replace("{{SEVERITY_STRIP}}", sevStrip)
  .replace("{{TOC}}", toc)
  .replace("{{REPORT_BODY}}", body);

writeFileSync(args.out, html);
console.log(`wrote ${args.out} (${totalFindings} findings: ` +
  SEVS.map(s => `${counts[s]}${s[0]}`).join("/") + `)`);
