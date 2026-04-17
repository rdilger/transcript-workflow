#!/usr/bin/env node
// Obsidian Transcript MCP Server
// Exposes the Transcripts folder of the Obsidian vault to Claude Code.
//
// Tools:
//   list_transcripts  — list all transcripts with metadata (filterable by tag)
//   read_transcript   — read full content of a specific transcript
//   search_transcripts — search by keyword across title, summary, and full text

import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from '@modelcontextprotocol/sdk/types.js';
import { readdir, readFile } from 'fs/promises';
import { join } from 'path';
import { homedir } from 'os';

const VAULT = process.env.OBSIDIAN_VAULT
  ?? join(homedir(), 'Library/Mobile Documents/iCloud~md~obsidian/Documents/Obsidian Vault');
const TRANSCRIPTS_DIR = join(VAULT, 'Transcripts');

// ── Frontmatter parser ────────────────────────────────────────────────────────

function parseFrontmatter(content) {
  const match = content.match(/^---\n([\s\S]*?)\n---\n([\s\S]*)$/);
  if (!match) return { meta: {}, body: content };

  const meta = {};
  for (const line of match[1].split('\n')) {
    const sep = line.indexOf(':');
    if (sep === -1) continue;
    const key = line.slice(0, sep).trim();
    let val = line.slice(sep + 1).trim();
    // Parse YAML arrays like [transcript, tag1, tag2]
    if (val.startsWith('[') && val.endsWith(']')) {
      val = val.slice(1, -1).split(',').map(s => s.trim().replace(/^["']|["']$/g, ''));
    }
    // Parse quoted strings
    if (typeof val === 'string' && val.startsWith('"') && val.endsWith('"')) {
      val = val.slice(1, -1);
    }
    meta[key] = val;
  }
  return { meta, body: match[2].trim() };
}

// ── File helpers ──────────────────────────────────────────────────────────────

async function loadTranscripts() {
  let files;
  try {
    files = (await readdir(TRANSCRIPTS_DIR)).filter(f => f.endsWith('.md'));
  } catch {
    return [];
  }

  const results = await Promise.all(files.map(async (filename) => {
    try {
      const content = await readFile(join(TRANSCRIPTS_DIR, filename), 'utf8');
      const { meta, body } = parseFrontmatter(content);
      return { filename, meta, body, raw: content };
    } catch {
      return null;
    }
  }));
  return results.filter(Boolean).sort((a, b) => b.filename.localeCompare(a.filename));
}

// ── Tool handlers ─────────────────────────────────────────────────────────────

async function listTranscripts({ tag, limit = 20 } = {}) {
  const transcripts = await loadTranscripts();
  let filtered = transcripts;

  if (tag) {
    const needle = tag.toLowerCase();
    filtered = transcripts.filter(t => {
      const tags = Array.isArray(t.meta.tags) ? t.meta.tags : [t.meta.tags ?? ''];
      return tags.some(tg => tg.toLowerCase().includes(needle));
    });
  }

  const items = filtered.slice(0, limit).map(t => ({
    filename: t.filename,
    date: t.meta.date ?? '',
    title: t.meta.title ?? t.filename,
    duration: t.meta.duration ?? '',
    language: t.meta.language ?? '',
    word_count: t.meta.word_count ?? '',
    tags: Array.isArray(t.meta.tags) ? t.meta.tags.join(', ') : (t.meta.tags ?? ''),
    cost_eur: t.meta.cost_eur ?? '',
  }));

  const rows = items.map(i =>
    `${i.date}  ${i.title.padEnd(50)}  ${i.duration.padStart(6)}  ${i.language}  [${i.tags}]`
  ).join('\n');

  return `Found ${filtered.length} transcript(s)${tag ? ` tagged "${tag}"` : ''}` +
    (filtered.length > limit ? ` (showing first ${limit})` : '') +
    `:\n\n${rows}`;
}

async function readTranscript({ filename }) {
  if (!filename) return 'Error: filename is required';
  // Allow partial match (e.g. "2026-03-27" matches first file with that date)
  const transcripts = await loadTranscripts();
  const match = transcripts.find(t =>
    t.filename === filename ||
    t.filename === filename + '.md' ||
    t.filename.includes(filename)
  );
  if (!match) return `No transcript found matching "${filename}"`;
  return match.raw;
}

async function searchTranscripts({ query, limit = 10 }) {
  if (!query) return 'Error: query is required';
  const transcripts = await loadTranscripts();
  const needle = query.toLowerCase();

  const scored = transcripts.map(t => {
    const titleScore = (t.meta.title ?? '').toLowerCase().includes(needle) ? 3 : 0;
    const bodyScore = t.body.toLowerCase().includes(needle) ? 1 : 0;
    const tagScore = (Array.isArray(t.meta.tags) ? t.meta.tags.join(' ') : '').toLowerCase().includes(needle) ? 2 : 0;
    return { ...t, score: titleScore + bodyScore + tagScore };
  }).filter(t => t.score > 0).sort((a, b) => b.score - a.score);

  if (scored.length === 0) return `No transcripts found matching "${query}"`;

  const items = scored.slice(0, limit).map(t => {
    // Extract a snippet around the match
    const bodyLower = t.body.toLowerCase();
    const idx = bodyLower.indexOf(needle);
    const snippet = idx !== -1
      ? '…' + t.body.slice(Math.max(0, idx - 60), idx + 120).replace(/\n+/g, ' ') + '…'
      : '';
    return `**${t.meta.date}** — ${t.meta.title ?? t.filename}\n  File: ${t.filename}\n  ${snippet}`;
  });

  return `Found ${scored.length} result(s) for "${query}"` +
    (scored.length > limit ? ` (showing top ${limit})` : '') +
    `:\n\n${items.join('\n\n')}`;
}

// ── Server setup ──────────────────────────────────────────────────────────────

const server = new Server(
  { name: 'obsidian-transcripts', version: '1.0.0' },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: 'list_transcripts',
      description: 'List transcripts from the Obsidian vault with metadata. Optionally filter by tag.',
      inputSchema: {
        type: 'object',
        properties: {
          tag:   { type: 'string', description: 'Filter by tag (partial match)' },
          limit: { type: 'number', description: 'Max results (default 20)' },
        },
      },
    },
    {
      name: 'read_transcript',
      description: 'Read the full content of a specific transcript by filename (or partial date/title match).',
      inputSchema: {
        type: 'object',
        required: ['filename'],
        properties: {
          filename: { type: 'string', description: 'Filename or partial match, e.g. "2026-03-27" or "Meeting-Q2"' },
        },
      },
    },
    {
      name: 'search_transcripts',
      description: 'Search transcript titles, tags, and content for a keyword.',
      inputSchema: {
        type: 'object',
        required: ['query'],
        properties: {
          query: { type: 'string', description: 'Search term' },
          limit: { type: 'number', description: 'Max results (default 10)' },
        },
      },
    },
  ],
}));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;
  let result;
  try {
    if (name === 'list_transcripts')   result = await listTranscripts(args);
    else if (name === 'read_transcript')    result = await readTranscript(args);
    else if (name === 'search_transcripts') result = await searchTranscripts(args);
    else result = `Unknown tool: ${name}`;
  } catch (err) {
    result = `Error: ${err.message}`;
  }
  return { content: [{ type: 'text', text: result }] };
});

const transport = new StdioServerTransport();
await server.connect(transport);
