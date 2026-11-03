'use strict';
// 연말 경품 추첨 — IMS 수집기(monitor/server.js)가 /event 주소로 이 모듈을 불러 쓴다 (같은 포트 15138). 모니터링과 별개 폴더.
//  - 명단(그룹·팀·이름·매수)을 붙여 넣으면 응모권 번호를 만든다 (번호를 직접 적어도 됨)
//  - 1차·2차 탈락: 서버가 탈락 순서를 미리 정해 두고 몇 초마다 한 장씩 발표 → 모든 화면(TV·직원 PC·휴대폰)이 같은 순서로 본다
//  - 최종 추첨: 경품마다 남은 응모권에서 뽑는다. 결과는 공개 시각이 지나야 화면으로 나간다 (미리 볼 수 없음)
// 데이터: event/data/event.json   진행 버튼은 모니터링 관리자(admin) 로그인일 때만.
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const PUB = path.join(__dirname, 'public');
const DATA_DIR = process.env.EVENT_DATA || path.join(__dirname, 'data');
const FILE = path.join(DATA_DIR, 'event.json');
const MAX_PER = 4;                                     // 한 사람 최대 응모권 수

const randInt = (n) => (crypto.randomInt ? crypto.randomInt(n) : crypto.randomBytes(4).readUInt32LE(0) % n);
function shuffle(a) { for (let i = a.length - 1; i > 0; i--) { const j = randInt(i + 1); const x = a[i]; a[i] = a[j]; a[j] = x; } return a; }
const clampInt = (v, lo, hi, d) => { const n = Math.round(Number(v)); return Number.isFinite(n) ? Math.min(hi, Math.max(lo, n)) : d; };
const str = (v, n) => String(v == null ? '' : v).trim().slice(0, n);

function blank() {
  return {
    title: '연말 경품 추첨', interval: 6, spin: 3, finalSpin: 7, onePrize: true,
    rounds: [
      { name: '1차 탈락자 발표', counts: {}, state: 'ready', seq: [], shown: 0 },
      { name: '2차 탈락자 발표', counts: {}, state: 'ready', seq: [], shown: 0 },
    ],
    prizes: [],     // [{ name, g: 'A'|'B'|'*', n }]
    wins: [],       // [{ k: 경품 위치, t: 응모권 위치, at: 공개 시각(ms) }]
    people: [],     // [{ g, team, name }]
    tickets: [],    // [{ no, p: 사람 위치, out: 0 = 남음 | 1 = 1차 탈락 | 2 = 2차 탈락, ord: 그 라운드 발표 순서 }]
    rosterRev: 1, rev: 1, run: null,
  };
}

let S = load();
let dirty = false;
function load() {
  const b = blank();
  try {
    const d = JSON.parse(fs.readFileSync(FILE, 'utf8'));
    const s = Object.assign(b, d);
    if (!Array.isArray(s.rounds) || s.rounds.length !== 2) s.rounds = blank().rounds;
    if (s.run && s.run.type === 'round') { s.run.paused = true; s.run.nextAt = null; }   // 수집기가 다시 켜지면 멈춘 상태로 — 진행자가 '계속' 을 누른다
    return s;
  } catch (e) {
    if (e.code !== 'ENOENT') { try { fs.renameSync(FILE, FILE + '.broken-' + Date.now()); } catch (_) {} console.error('경품 추첨 데이터 읽기 실패 — 새로 시작:', e.message); }
    return b;
  }
}
function saveNow() {
  try {
    fs.mkdirSync(DATA_DIR, { recursive: true });
    const tmp = FILE + '.tmp';
    fs.writeFileSync(tmp, JSON.stringify(S));
    fs.renameSync(tmp, FILE);
    dirty = false;
  } catch (e) { console.error('경품 추첨 저장 실패:', e.message); }
}
setInterval(() => { if (dirty) saveNow(); }, 3000).unref();
const bump = () => { S.rev++; dirty = true; };

// ---- 명단 ----
function groups() { return [...new Set(S.people.map((p) => p.g))].sort(); }
function normGroup(s) { const g = String(s || '').trim().toUpperCase().replace(/\s*(그룹|조|GROUP)$/i, '').trim(); return g.slice(0, 10); }

function parseRoster(text) {
  const lines = String(text || '').split(/\r?\n/);
  const people = [], tickets = [], errs = [], used = new Set();
  lines.forEach((line, i) => {
    const s = line.trim(); if (!s || s.startsWith('#')) return;
    const cols = (s.includes('\t') ? s.split('\t') : s.split(',')).map((x) => x.trim());
    if (/이름|성명/.test(s) && /그룹|구분|팀|부서/.test(s) && !/\d/.test(cols[3] || '')) return;   // 머리글 줄
    const g = normGroup(cols[0]), team = str(cols[1], 30) || '(팀 없음)', name = str(cols[2], 30);
    const nums = cols.slice(4).join(' ').split(/[\s;/]+/).map((x) => x.trim()).filter(Boolean);
    const n = nums.length || parseInt(cols[3], 10);
    if (!g) { errs.push(`${i + 1}행: 그룹이 비어 있습니다`); return; }
    if (!name) { errs.push(`${i + 1}행: 이름이 비어 있습니다`); return; }
    if (!(n >= 1 && n <= MAX_PER)) { errs.push(`${i + 1}행 ${name}: 매수는 1~${MAX_PER}장이어야 합니다 (${cols[3] || '빈칸'})`); return; }
    const p = people.length; people.push({ g, team, name });
    for (let k = 0; k < n; k++) {
      const no = nums[k] ? str(nums[k], 20) : null;
      if (no) { if (used.has(no)) errs.push(`${i + 1}행 ${name}: 응모번호 ${no} 가 중복됩니다`); used.add(no); }
      tickets.push({ no, p, out: 0, ord: 0 });
    }
  });
  // 번호를 안 적은 응모권은 그룹별로 A-001, A-002 … (이미 쓴 번호는 건너뜀)
  const seq = {};
  const width = tickets.length > 999 ? 4 : 3;
  for (const t of tickets) {
    if (t.no) continue;
    const g = people[t.p].g;
    let no; do { seq[g] = (seq[g] || 0) + 1; no = `${g}-${String(seq[g]).padStart(width, '0')}`; } while (used.has(no));
    used.add(no); t.no = no;
  }
  if (!people.length && !errs.length) errs.push('명단이 비어 있습니다');
  return { people, tickets, errs };
}
function rosterText() {
  const byP = S.people.map(() => []);
  S.tickets.forEach((t) => byP[t.p].push(t.no));
  return S.people.map((p, i) => [p.g, p.team, p.name, byP[i].length, byP[i].join(' ')].join(',')).join('\n');
}

// ---- 진행 ----
function started() { return S.rounds.some((r) => r.state !== 'ready') || S.wins.length > 0; }
function wonSet() { return new Set(S.wins.map((w) => w.t)); }
function winnerPeople() { return new Set(S.wins.map((w) => S.tickets[w.t].p)); }
function aliveIdx(g) {
  const won = wonSet();
  const out = [];
  S.tickets.forEach((t, i) => { if (!t.out && !won.has(i) && (!g || g === '*' || S.people[t.p].g === g)) out.push(i); });
  return out;
}

function reveal(r) {
  const R = S.rounds[r], t = S.tickets[R.seq[R.shown]];
  t.out = r + 1; t.ord = R.shown + 1; R.shown++;
}
function finishRound(r) { const R = S.rounds[r]; R.state = 'done'; R.endedAt = Date.now(); S.run = null; }

function tick() {
  const run = S.run, now = Date.now();
  if (!run) return;
  if (run.type === 'round') {
    if (run.paused || !run.nextAt || now < run.nextAt) return;
    const R = S.rounds[run.r];
    reveal(run.r);
    if (R.shown >= R.seq.length) finishRound(run.r);
    else run.nextAt = now + S.interval * 1000;
    bump();
  } else if (run.type === 'prize' && now >= run.revealAt) {
    S.run = null; bump();
  }
}
setInterval(tick, 200).unref();

function act(b, by) {
  const a = String(b.act || '');
  const now = Date.now();
  if (a === 'roster') {
    if (started()) throw new Error('추첨을 시작한 뒤에는 명단을 바꿀 수 없습니다. 먼저 [처음부터 다시]를 누르세요');
    const r = parseRoster(b.text);
    if (r.errs.length) { const e = new Error(r.errs.slice(0, 15).join('\n') + (r.errs.length > 15 ? `\n… 외 ${r.errs.length - 15}건` : '')); throw e; }
    S.people = r.people; S.tickets = r.tickets; S.rosterRev++;
    for (const R of S.rounds) for (const g of Object.keys(R.counts)) if (!groups().includes(g)) delete R.counts[g];
    bump(); return { people: r.people.length, tickets: r.tickets.length };
  }
  if (a === 'config') {
    if (b.title != null) S.title = str(b.title, 60) || S.title;
    if (b.spin != null) S.spin = clampInt(b.spin, 1, 10, 3);
    if (b.interval != null) S.interval = clampInt(b.interval, S.spin + 1, 60, 6);
    if (S.interval <= S.spin) S.interval = S.spin + 1;
    if (b.finalSpin != null) S.finalSpin = clampInt(b.finalSpin, 2, 20, 7);
    if (b.onePrize != null && !S.wins.length) S.onePrize = !!b.onePrize;
    if (Array.isArray(b.rounds)) b.rounds.slice(0, 2).forEach((x, r) => {
      const R = S.rounds[r]; if (!x) return;
      if (x.name != null) R.name = str(x.name, 40) || R.name;
      if (x.counts && R.state === 'ready') { R.counts = {}; for (const g of groups()) R.counts[g] = clampInt(x.counts[g], 0, 100000, 0); }
    });
    if (Array.isArray(b.prizes)) {
      if (S.wins.length) throw new Error('최종 추첨을 시작한 뒤에는 경품 목록을 바꿀 수 없습니다 (이름·순서가 어긋남)');
      S.prizes = b.prizes.slice(0, 200).map((p) => ({ name: str(p.name, 60), g: p.g === '*' ? '*' : normGroup(p.g) || '*', n: clampInt(p.n, 1, 1000, 1) })).filter((p) => p.name);
    }
    bump(); return {};
  }
  if (a === 'start') {                                  // 탈락 발표 시작
    const r = clampInt(b.r, 0, 1, 0), R = S.rounds[r];
    if (S.run) throw new Error('진행 중인 추첨이 있습니다');
    if (!S.tickets.length) throw new Error('명단을 먼저 넣으세요');
    if (S.wins.length) throw new Error('최종 추첨을 시작한 뒤에는 탈락 발표를 할 수 없습니다');
    if (R.state !== 'ready') throw new Error(`${R.name}는 이미 진행했습니다`);
    for (let i = 0; i < r; i++) if (S.rounds[i].state !== 'done' && total(S.rounds[i]) > 0) throw new Error(`${S.rounds[i].name}를 먼저 하세요`);
    let seq = [];
    for (const g of groups()) {
      const n = clampInt(R.counts[g], 0, 100000, 0); if (!n) continue;
      const pool = aliveIdx(g);
      if (n >= pool.length) throw new Error(`${g}그룹: 남은 응모권 ${pool.length}장보다 적게 탈락시켜야 합니다 (지금 ${n})`);
      seq = seq.concat(shuffle(pool).slice(0, n));
    }
    if (!seq.length) throw new Error('탈락 인원(장수)을 설정에서 먼저 정하세요');
    Object.assign(R, { state: 'run', seq: shuffle(seq), shown: 0, startedAt: now, by });
    S.run = { type: 'round', r, nextAt: now + 4000 + S.spin * 1000, paused: false };
    bump(); return {};
  }
  if (a === 'pause' || a === 'resume') {
    if (!S.run || S.run.type !== 'round') throw new Error('진행 중인 탈락 발표가 없습니다');
    S.run.paused = a === 'pause';
    S.run.nextAt = S.run.paused ? null : now + S.spin * 1000 + 1500;
    bump(); return {};
  }
  if (a === 'flush') {                                  // 남은 탈락자 한꺼번에 발표
    if (!S.run || S.run.type !== 'round') throw new Error('진행 중인 탈락 발표가 없습니다');
    const r = S.run.r, R = S.rounds[r];
    while (R.shown < R.seq.length) reveal(r);
    finishRound(r); bump(); return {};
  }
  if (a === 'undo-round') {                             // 리허설용: 마지막으로 진행한 탈락 발표를 되돌림
    if (S.wins.length) throw new Error('최종 추첨 결과가 있으면 먼저 그것부터 되돌리세요');
    let r = -1; S.rounds.forEach((R, i) => { if (R.state !== 'ready') r = i; });
    if (r < 0) throw new Error('되돌릴 탈락 발표가 없습니다');
    for (const t of S.tickets) if (t.out === r + 1) { t.out = 0; t.ord = 0; }
    Object.assign(S.rounds[r], { state: 'ready', seq: [], shown: 0 });
    if (S.run && S.run.type === 'round') S.run = null;
    bump(); return { r };
  }
  if (a === 'draw') {                                   // 최종 추첨: 지금 경품 1명 (all 이면 그 경품 남은 수량 모두)
    if (S.run) throw new Error('진행 중인 추첨이 끝난 뒤에 누르세요');
    for (const R of S.rounds) if (R.state !== 'done' && total(R) > 0) throw new Error(`${R.name}를 먼저 끝내세요`);
    const k = S.prizes.findIndex((p, i) => S.wins.filter((w) => w.k === i).length < p.n);
    if (k < 0) throw new Error(S.prizes.length ? '모든 경품 추첨이 끝났습니다' : '설정에서 경품을 먼저 넣으세요');
    const P = S.prizes[k], left = P.n - S.wins.filter((w) => w.k === k).length;
    const wp = S.onePrize ? winnerPeople() : new Set();
    const pool = aliveIdx(P.g).filter((i) => !wp.has(S.tickets[i].p));
    if (!pool.length) throw new Error(`${P.name}: 뽑을 수 있는 응모권이 없습니다`);
    const m = Math.min(b.all ? left : 1, pool.length);
    const pick = [];
    for (const i of shuffle(pool)) {                     // 한 사람 한 경품이면 같은 사람의 다른 응모권은 건너뜀
      if (pick.length >= m) break;
      if (S.onePrize && pick.some((j) => S.tickets[j].p === S.tickets[i].p)) continue;
      pick.push(i);
    }
    const revealAt = now + S.finalSpin * 1000;
    for (const t of pick) S.wins.push({ k, t, at: revealAt });
    S.run = { type: 'prize', k, revealAt, count: pick.length };
    bump(); return {};
  }
  if (a === 'undo-win') {                               // 마지막 당첨 묶음 되돌리기
    if (S.run) throw new Error('추첨 중에는 되돌릴 수 없습니다');
    if (!S.wins.length) throw new Error('되돌릴 당첨이 없습니다');
    const last = S.wins[S.wins.length - 1].at;
    S.wins = S.wins.filter((w) => w.at !== last);
    bump(); return {};
  }
  if (a === 'reset') {                                  // 처음부터 다시 (명단·설정은 그대로)
    for (const t of S.tickets) { t.out = 0; t.ord = 0; }
    for (const R of S.rounds) Object.assign(R, { state: 'ready', seq: [], shown: 0 });
    S.wins = []; S.run = null;
    bump(); return {};
  }
  throw new Error('알 수 없는 동작: ' + a);
}
const total = (R) => Object.values(R.counts || {}).reduce((s, n) => s + (Number(n) || 0), 0);

// ---- 화면으로 보내는 내용 (발표된 것만) ----
function live(admin) {
  const now = Date.now();
  const shownWins = S.wins.filter((w) => w.at <= now);
  const won = new Set(shownWins.map((w) => w.t));
  let out = '';
  for (let i = 0; i < S.tickets.length; i++) out += won.has(i) ? 'W' : String(S.tickets[i].out || 0);
  const orders = S.rounds.map((R, r) => S.tickets.map((t, i) => [t, i]).filter(([t]) => t.out === r + 1).sort((a, b) => a[0].ord - b[0].ord).map(([, i]) => i));
  const run = !S.run ? null : S.run.type === 'round'
    ? { type: 'round', r: S.run.r, nextAt: S.run.nextAt, paused: !!S.run.paused }
    : { type: 'prize', k: S.run.k, revealAt: S.run.revealAt, count: S.run.count };
  return {
    ok: true, rev: S.rev, now, admin, rosterRev: S.rosterRev,
    title: S.title, interval: S.interval, spin: S.spin, finalSpin: S.finalSpin, onePrize: S.onePrize,
    rounds: S.rounds.map((R) => ({ name: R.name, counts: R.counts, state: R.state, shown: R.shown, total: R.state === 'ready' ? total(R) : R.seq.length })),
    out, orders, run,
    prizes: S.prizes.map((p, k) => ({ name: p.name, g: p.g, n: p.n, wins: shownWins.filter((w) => w.k === k).map((w) => w.t) })),
  };
}
function rosterView() {
  return { ok: true, rosterRev: S.rosterRev, groups: groups(), people: S.people.map((p) => [p.g, p.team, p.name]), tickets: S.tickets.map((t) => [t.no, t.p]) };
}
function csv() {
  const q = (v) => `"${String(v == null ? '' : v).replace(/"/g, '""')}"`;
  const rows = [['구분', '순서', '응모번호', '그룹', '팀', '이름', '경품']];
  S.rounds.forEach((R, r) => {
    S.tickets.filter((t) => t.out === r + 1).sort((a, b) => a.ord - b.ord).forEach((t) => { const p = S.people[t.p]; rows.push([R.name, t.ord, t.no, p.g, p.team, p.name, '']); });
  });
  S.wins.forEach((w, i) => { const t = S.tickets[w.t], p = S.people[t.p]; rows.push(['최종 당첨', i + 1, t.no, p.g, p.team, p.name, (S.prizes[w.k] || {}).name || '']); });
  const won = wonSet();
  S.tickets.forEach((t, i) => { if (!t.out && !won.has(i)) { const p = S.people[t.p]; rows.push(['남은 응모권', '', t.no, p.g, p.team, p.name, '']); } });
  return '﻿' + rows.map((r) => r.map(q).join(',')).join('\r\n');
}

// ---- 요청 처리 (server.js 가 /event 로 시작하는 주소를 넘겨준다) ----
function send(res, code, body, type) {
  res.writeHead(code, { 'Content-Type': type || 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
  res.end(typeof body === 'string' || Buffer.isBuffer(body) ? body : JSON.stringify(body));
}
const TYPES = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.svg': 'image/svg+xml', '.webp': 'image/webp', '.mp3': 'audio/mpeg', '.wav': 'audio/wav', '.ico': 'image/x-icon' };

async function handle(req, res, url, ctx) {
  const p = url.pathname.replace(/^\/event/, '') || '/';
  const user = ctx.user, admin = !!(user && user.admin);
  if (req.method === 'GET' && (p === '/' || p === '/index.html')) {
    return fs.readFile(path.join(PUB, 'index.html'), (e, d) => (e ? send(res, 500, '화면 파일이 없습니다', 'text/plain; charset=utf-8') : send(res, 200, d, TYPES['.html'])));
  }
  if (req.method === 'GET' && p === '/api/live') {
    if (Number(url.searchParams.get('rev')) === S.rev) return send(res, 200, { same: true, rev: S.rev, now: Date.now() });
    return send(res, 200, live(admin));
  }
  if (req.method === 'GET' && p === '/api/roster') return send(res, 200, rosterView());
  if (req.method === 'GET' && p === '/api/config') {
    if (!admin) return send(res, 403, { ok: false, error: '관리자만' });
    return send(res, 200, { ok: true, rosterText: rosterText(), started: started(), prizes: S.prizes, rounds: S.rounds.map((R) => ({ name: R.name, counts: R.counts, state: R.state })), groups: groups() });
  }
  if (req.method === 'GET' && p === '/api/result.csv') {
    if (!admin) return send(res, 403, { ok: false, error: '관리자만' });
    res.writeHead(200, { 'Content-Type': 'text/csv; charset=utf-8', 'Content-Disposition': `attachment; filename="event-result-${new Date().toISOString().slice(0, 10)}.csv"` });
    return res.end(csv());
  }
  if (req.method === 'POST' && p === '/api/admin') {
    if (!admin) return send(res, 403, { ok: false, error: '모니터링 관리자(admin)로 로그인해야 진행할 수 있습니다' });
    try {
      const body = JSON.parse((await ctx.readBody(req, 2)) || '{}');
      const r = act(body, user.id);
      saveNow();
      if (ctx.log && body.act !== 'config' && body.act !== 'roster') ctx.log(`[경품 추첨] ${user.id}: ${body.act}${body.r != null ? ' ' + body.r : ''}`);
      return send(res, 200, Object.assign({ ok: true }, r));
    } catch (e) { return send(res, 400, { ok: false, error: String(e.message || e) }); }
  }
  const m = /^\/([\w.-]+)$/.exec(p);
  if (req.method === 'GET' && m && !m[1].startsWith('.') && TYPES[path.extname(m[1]).toLowerCase()]) {
    return fs.readFile(path.join(PUB, m[1]), (e, d) => (e ? send(res, 404, 'not found', 'text/plain') : send(res, 200, d, TYPES[path.extname(m[1]).toLowerCase()])));
  }
  return send(res, 404, { ok: false, error: 'not found' });
}

function flush() { if (dirty) saveNow(); }
module.exports = { handle, flush, _test: { act, live, parseRoster, tick, state: () => S } };
