'use strict';
/*
 * Fortnite match vault — receives .replay files (single, ZIP, or via an
 * auto-scanned inbox folder), parses them with the C# replay2json helper
 * (encrypted + current-version capable), stores normalized records, serves a UI.
 *
 * Multi-uploader: every replay self-identifies its recorder, which we store as
 * `owner`. The API and UI can then be filtered per player (?owner=Name), so
 * several people can drop replays into one vault and each sees their own stats.
 */
const express = require('express');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const AdmZip = require('adm-zip');
const { execFileSync } = require('child_process');

const PORT = process.env.PORT || 8090;
const DATA_DIR = process.env.DATA_DIR || '/data';
const MATCH_DIR = path.join(DATA_DIR, 'matches');
const INBOX_DIR = path.join(DATA_DIR, 'inbox');
const FAILED_DIR = path.join(DATA_DIR, 'failed');
const RAW_DIR = path.join(DATA_DIR, 'raw');
const INGEST_KEY = process.env.INGEST_KEY || '';
const PARSER = process.env.PARSER || 'replay2json';

for (const d of [MATCH_DIR, INBOX_DIR, FAILED_DIR, RAW_DIR]) fs.mkdirSync(d, { recursive: true });
// let the host user (hermes, uid 1000) drop .replay files straight into the inbox
try { fs.chownSync(INBOX_DIR, 1000, 1000); fs.chmodSync(INBOX_DIR, 0o775); } catch (_) {}

const sha = (b) => crypto.createHash('sha1').update(b).digest('hex').slice(0, 16);

// Whose vault this match belongs to. New records carry `owner`; older ones
// (written before multi-uploader support) fall back to the recorder name.
const ownerOf = (m) => m.owner || (m.me && m.me.name) || 'Unknown';

function mapRecord(j, filename, id) {
  const me = j.me || null;
  const team = j.teammates || j.team || [];
  const owner = (me && me.name) || j.recorder || j.recorderName || 'Unknown';
  const teammates = (me ? team.filter(p => p.name !== me.name) : team)
    .map(p => ({ name: p.name, kills: p.kills, team: p.team, platform: p.platform, level: p.level, isBot: p.isBot, isReplayOwner: p.isReplayOwner }));
  return {
    id: id || sha(String(filename) + (j.playedAt || '')),
    fileName: filename,
    owner,
    playedAt: j.playedAt || null,
    playlist: j.mode || 'Battle Royale',
    lengthMs: j.lengthMs || null,
    placement: j.placement ?? null,
    totalPlayers: j.totalPlayers ?? null,
    me: me ? {
      name: me.name, kills: (j.myEliminations ?? me.kills) ?? null, team: me.team,
      platform: me.platform, level: me.level, isBot: me.isBot, isReplayOwner: me.isReplayOwner,
    } : null,
    teammates,
    players: (j.players || []).map(p => ({
      name: p.name, kills: p.kills, team: p.team, isBot: p.isBot, level: p.level,
      platform: p.platform, isReplayOwner: p.isReplayOwner,
    })),
    map: j.map || null,
    killFeed: j.killFeed || [],
    safeZonesStartTime: j.safeZonesStartTime ?? null,
    _debug: { playerCount: j.playerCount, myTeam: j.myTeam },
  };
}

// Returns { ok, id, record } or { ok:false, error }
function ingestBuffer(buf, filename) {
  const tmp = path.join(INBOX_DIR, `.tmp-${Date.now()}-${Math.random().toString(36).slice(2)}.replay`);
  fs.writeFileSync(tmp, buf);
  try {
    const out = execFileSync(PARSER, [tmp], { maxBuffer: 512 * 1024 * 1024 });
    const j = JSON.parse(out.toString());
    if (j.error) throw new Error(j.error);
    const rec = mapRecord(j, filename, sha(buf));
    fs.writeFileSync(path.join(MATCH_DIR, `${rec.id}.json`), JSON.stringify(rec, null, 2));
    // keep the raw replay so records can be re-parsed later without re-uploading
    const rawPath = path.join(RAW_DIR, `${rec.id}.replay`);
    try { fs.renameSync(tmp, rawPath); }
    catch (_) { try { fs.copyFileSync(tmp, rawPath); fs.unlinkSync(tmp); } catch (__) { try { fs.unlinkSync(tmp); } catch (___) {} } }
    return { ok: true, id: rec.id, record: rec };
  } catch (e) {
    const msg = (e.stderr && e.stderr.toString().trim()) || e.message || String(e);
    try { fs.renameSync(tmp, path.join(FAILED_DIR, `${sha(buf)}.replay`)); } catch (_) { try { fs.unlinkSync(tmp); } catch (__) {} }
    return { ok: false, error: msg };
  }
}

const app = express();
app.use((req, res, next) => { res.set('Cache-Control', 'no-store'); next(); });
app.use(express.static(path.join(__dirname, 'public')));

function listMatches() {
  return fs.readdirSync(MATCH_DIR).filter(f => f.endsWith('.json'))
    .map(f => JSON.parse(fs.readFileSync(path.join(MATCH_DIR, f), 'utf8')))
    .sort((a, b) => (b.playedAt || '').localeCompare(a.playedAt || ''));
}

function filteredMatches(owner) {
  const all = listMatches();
  return owner ? all.filter(m => ownerOf(m) === owner) : all;
}

// distinct uploaders + match counts, for the player dropdown
app.get('/api/owners', (req, res) => {
  const mp = {};
  for (const m of listMatches()) { const o = ownerOf(m); mp[o] = (mp[o] || 0) + 1; }
  res.json(Object.entries(mp).map(([name, matches]) => ({ name, matches }))
    .sort((a, b) => b.matches - a.matches || a.name.localeCompare(b.name)));
});

app.get('/api/matches', (req, res) => {
  res.json(filteredMatches(req.query.owner).map(m => ({
    id: m.id, fileName: m.fileName, owner: ownerOf(m), playedAt: m.playedAt, playlist: m.playlist,
    placement: m.placement, totalPlayers: m.totalPlayers, me: m.me,
    teammateCount: (m.teammates || []).length, lengthMs: m.lengthMs,
    teammates: (m.teammates || []).map(t => ({ name: t.name, kills: t.kills })),
    hasMap: !!(m.map && m.map.safeZones && m.map.safeZones.length),
    kills: (m.killFeed || []).filter(k => k.kind === 'eliminated').length,
  })));
});

app.get('/api/matches/:id', (req, res) => {
  const p = path.join(MATCH_DIR, `${req.params.id}.json`);
  if (!fs.existsSync(p)) return res.status(404).json({ error: 'not found' });
  const m = JSON.parse(fs.readFileSync(p, 'utf8'));
  res.json({ ...m, owner: ownerOf(m) });
});

// ---- per-teammate aggregate (honors ?owner=) ----
app.get('/api/teammates', (req, res) => {
  const all = filteredMatches(req.query.owner);
  const mp = {};
  for (const m of all) {
    for (const t of (m.teammates || [])) {
      if (!t.name) continue;
      const k = mp[t.name] || (mp[t.name] = {
        name: t.name, matches: 0, killSum: 0, killGames: 0, bestKills: 0,
        wins: 0, bestPlace: null, placements: [],
      });
      k.matches++;
      if (typeof t.kills === 'number') { k.killSum += t.kills; k.killGames++; k.bestKills = Math.max(k.bestKills, t.kills); }
      if (m.placement === 1) k.wins++;
      if (typeof m.placement === 'number') { k.placements.push(m.placement); k.bestPlace = k.bestPlace == null ? m.placement : Math.min(k.bestPlace, m.placement); }
    }
  }
  const out = Object.values(mp).map(k => ({
    name: k.name, matches: k.matches,
    avgKills: k.killGames ? +(k.killSum / k.killGames).toFixed(1) : null,
    bestKills: k.bestKills, wins: k.wins, bestPlace: k.bestPlace,
    winRate: k.matches ? +(100 * k.wins / k.matches).toFixed(0) : 0,
  })).sort((a, b) => b.matches - a.matches || (b.avgKills || 0) - (a.avgKills || 0));
  res.json(out);
});

// ---- friend-group tier list ----
// Score = points per match = placementPoints(placement) + eliminations, averaged
// over the matches a player appeared in. Tier by standing relative to the leader:
// S >=90%, A 75-89%, B 60-74%, C 45-59%, D <45%.
function placementPoints(p) {
  if (p == null) return 0;
  if (p === 1) return 10;
  if (p <= 3) return 6;
  if (p <= 5) return 4;
  if (p <= 10) return 2;
  if (p <= 25) return 1;
  return 0;
}
const MIN_MATCHES = 2;

app.get('/api/tierlist', (req, res) => {
  const all = filteredMatches(req.query.owner);
  const owners = new Set(all.map(ownerOf));
  const mp = {};
  const add = (name, kills, place) => {
    if (!name) return;
    const k = mp[name] || (mp[name] = { name, matches: 0, kills: 0, killGames: 0, placeSum: 0, placeN: 0, wins: 0, top5: 0, best: null, points: 0 });
    k.matches++;
    if (typeof kills === 'number') { k.kills += kills; k.killGames++; }
    k.points += placementPoints(place) + (typeof kills === 'number' ? kills : 0);
    if (typeof place === 'number') {
      k.placeSum += place; k.placeN++;
      if (place === 1) k.wins++;
      if (place <= 5) k.top5++;
      k.best = k.best == null ? place : Math.min(k.best, place);
    }
  };
  for (const m of all) {
    if (m.me) add(m.me.name, m.me.kills, m.placement);
    for (const t of (m.teammates || [])) add(t.name, t.kills, m.placement);
  }
  let rows = Object.values(mp).map(k => ({
    name: k.name, matches: k.matches, kills: k.kills,
    avgKills: k.killGames ? +(k.kills / k.killGames).toFixed(1) : null,
    avgPlace: k.placeN ? +(k.placeSum / k.placeN).toFixed(1) : null,
    best: k.best, wins: k.wins, top5: k.top5,
    winRate: k.matches ? +(100 * k.wins / k.matches).toFixed(0) : 0,
    ptsPerMatch: k.matches ? +(k.points / k.matches).toFixed(2) : 0,
    isOwner: owners.has(k.name),
  })).sort((a, b) => b.ptsPerMatch - a.ptsPerMatch || b.avgKills - a.avgKills);
  rows = rows.filter(r => r.matches >= MIN_MATCHES || r.isOwner);
  const max = rows.length ? rows[0].ptsPerMatch : 0;
  const tierOf = (s) => {
    if (!max) return 'D';
    const r = s / max;
    return r >= 0.90 ? 'S' : r >= 0.75 ? 'A' : r >= 0.60 ? 'B' : r >= 0.45 ? 'C' : 'D';
  };
  rows = rows.map(r => ({ ...r, tier: tierOf(r.ptsPerMatch) }));
  res.json({ players: rows, minMatches: MIN_MATCHES });
});

app.get('/api/health', (req, res) => res.json({
  ok: true, matches: listMatches().length, parser: PARSER,
  inbox: fs.readdirSync(INBOX_DIR).length,
  owners: [...new Set(listMatches().map(ownerOf))].length,
  raw: fs.readdirSync(RAW_DIR).length,
}));

// re-parse every stored raw replay and rewrite its record (run after a parser upgrade)
app.post('/api/reparse', (req, res) => {
  const files = fs.readdirSync(RAW_DIR).filter(f => f.endsWith('.replay'));
  let ok = 0, fail = 0;
  for (const f of files) {
    const p = path.join(RAW_DIR, f);
    try {
      const out = execFileSync(PARSER, [p], { maxBuffer: 512 * 1024 * 1024 });
      const j = JSON.parse(out.toString());
      if (j.error) throw new Error(j.error);
      const rec = mapRecord(j, f, sha(fs.readFileSync(p)));
      fs.writeFileSync(path.join(MATCH_DIR, `${rec.id}.json`), JSON.stringify(rec, null, 2));
      ok++;
    } catch (e) { fail++; }
  }
  res.json({ ok: true, reparsed: ok, failed: fail, total: files.length });
});

// ---- single replay ----
app.post('/api/ingest', express.raw({ type: '*/*', limit: '512mb' }), (req, res) => {
  if (INGEST_KEY && req.headers['x-ingest-key'] !== INGEST_KEY) return res.status(401).json({ error: 'bad key' });
  const filename = req.headers['x-replay-name'] || `manual-${Date.now()}.replay`;
  if (!req.body || !req.body.length) return res.status(400).json({ error: 'empty body' });
  const r = ingestBuffer(req.body, filename);
  r.ok ? res.json(r) : res.status(422).json(r);
});

// ---- ZIP bulk upload (one request, many replays) ----
app.post('/api/ingest-zip', express.raw({ type: '*/*', limit: '2gb' }), (req, res) => {
  if (INGEST_KEY && req.headers['x-ingest-key'] !== INGEST_KEY) return res.status(401).json({ error: 'bad key' });
  if (!req.body || !req.body.length) return res.status(400).json({ error: 'empty body' });
  let zip;
  try { zip = new AdmZip(req.body); } catch (e) { return res.status(400).json({ error: 'bad zip: ' + e.message }); }
  let ok = 0, fail = 0; const results = [];
  for (const e of zip.getEntries()) {
    if (e.isDirectory || !/\.replay$/i.test(e.entryName)) continue;
    const r = ingestBuffer(e.getData(), path.basename(e.entryName));
    r.ok ? ok++ : fail++;
    results.push({ file: path.basename(e.entryName), ok: r.ok, owner: r.ok ? r.record.owner : undefined, error: r.ok ? undefined : r.error });
  }
  res.json({ ok: true, ingested: ok, failed: fail, results });
});

// ---- auto-scan inbox folder (drop .replay files here) ----
function scanInbox() {
  let files;
  try { files = fs.readdirSync(INBOX_DIR).filter(f => f.endsWith('.replay')); } catch { return; }
  for (const f of files) {
    try {
      const buf = fs.readFileSync(path.join(INBOX_DIR, f));
      const r = ingestBuffer(buf, f);
      fs.unlinkSync(path.join(INBOX_DIR, f));
      console.log(`[inbox] ${f} -> ${r.ok ? r.record.owner + ' / ' + r.record.playlist + ' p' + r.record.placement : 'FAIL ' + r.error}`);
    } catch (e) { console.error('[inbox] error', f, e.message); }
  }
}
setInterval(scanInbox, 15000);

app.listen(PORT, '0.0.0.0', () => console.log(`fortnite-stats on :${PORT}  data=${DATA_DIR}  parser=${PARSER}`));
