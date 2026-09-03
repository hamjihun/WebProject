'use strict';
// 서버 모니터링 수집기 (내 PC에서 실행)
// - 에이전트가 POST /api/metrics 로 보내는 JSON을 메모리에 쌓고
// - GET / 에서 대시보드 화면을 보여줍니다.
// 외부 패키지 없이 Node.js 내장 모듈만 사용합니다.

const http = require('http');
const fs = require('fs');
const path = require('path');

const PORT = Number(process.env.PORT || 8787);
const BIND = process.env.BIND || '0.0.0.0';             // IMS 웹서버 뒤에 둘 때는 127.0.0.1 (외부 노출 안 함)
const TOKEN = process.env.TOKEN || '';                 // 설정하면 에이전트도 같은 값을 보내야 함
const HISTORY = Number(process.env.HISTORY || 720);     // 서버당 보관 포인트 수 (5초 간격이면 1시간)
const OFFLINE_AFTER = Number(process.env.OFFLINE_AFTER || 90) * 1000; // 이 시간 동안 데이터 없으면 오프라인
const LOG_FILE = process.env.LOG_FILE || '';            // 지정하면 JSON Lines 로 파일에도 기록
const STATE_FILE = process.env.STATE_FILE === '' ? '' : (process.env.STATE_FILE || path.join(__dirname, 'data', 'state.json')); // 재시작 대비 스냅샷
const SAVE_EVERY = Number(process.env.SAVE_EVERY || 30) * 1000;
const DAILY_KEEP = Number(process.env.DAILY_KEEP || 400);     // 디스크 일별 스냅샷 보관 일수 (전일/주/월 증가량 계산용)

// { host: { latest: {...}, history: [ {...}, ... ] } }
const store = new Map();

// ---- 스냅샷 저장/복원 (재시작해도 이력 유지) ----
function loadState() {
  if (!STATE_FILE) return;
  try {
    const obj = JSON.parse(fs.readFileSync(STATE_FILE, 'utf8'));
    for (const [host, e] of Object.entries(obj)) if (e && e.latest) store.set(host, { latest: e.latest, history: (e.history || []).slice(-HISTORY), daily: e.daily || {} });
    console.log(`스냅샷 복원: ${store.size}대 (${STATE_FILE})`);
  } catch (e) { if (e.code !== 'ENOENT') console.warn('스냅샷 복원 실패:', e.message); }
}
let dirty = false;
function saveState(sync) {
  if (!STATE_FILE || !dirty) return;
  dirty = false;
  const obj = {}; for (const [h, e] of store) obj[h] = e;
  const tmp = STATE_FILE + '.tmp';
  try {
    fs.mkdirSync(path.dirname(STATE_FILE), { recursive: true });
    if (sync) { fs.writeFileSync(tmp, JSON.stringify(obj)); fs.renameSync(tmp, STATE_FILE); return; }
    fs.writeFile(tmp, JSON.stringify(obj), (err) => { if (!err) fs.rename(tmp, STATE_FILE, () => {}); });
  } catch (e) { console.warn('스냅샷 저장 실패:', e.message); }
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (c) => {
      size += c.length;
      if (size > 1024 * 1024) { reject(new Error('body too large')); req.destroy(); return; }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

function json(res, code, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(code, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
    'Access-Control-Allow-Origin': '*',
  });
  res.end(body);
}

function num(v, d = 0) { const n = Number(v); return Number.isFinite(n) ? n : d; }

// 에이전트가 보낸 원본을 화면에서 쓰기 좋은 형태로 정규화
function normalize(raw, remoteIp) {
  const host = String(raw.host || raw.hostname || remoteIp || 'unknown').trim();
  const memTotal = num(raw.mem_total);
  const memUsed = num(raw.mem_used);
  const disks = Array.isArray(raw.disks) ? raw.disks.map((d) => ({
    mount: String(d.mount || d.drive || ''),
    total: num(d.total),
    used: num(d.used),
    pct: d.total ? Math.round(num(d.used) / num(d.total) * 1000) / 10 : num(d.pct),
  })) : [];
  return {
    host,
    ip: remoteIp,
    os: String(raw.os || ''),
    ts: Date.now(),
    cpu: Math.round(num(raw.cpu) * 10) / 10,              // %
    mem_total: memTotal,                                    // bytes
    mem_used: memUsed,
    mem_pct: memTotal ? Math.round(memUsed / memTotal * 1000) / 10 : num(raw.mem_pct),
    load1: num(raw.load1, null),
    uptime: num(raw.uptime),                                // seconds
    net_rx: num(raw.net_rx),                                // bytes/sec
    net_tx: num(raw.net_tx),
    disks,
  };
}

// ---- 디스크 일별 스냅샷 / 증가량 ----
function dayKey(ts) {
  const d = new Date(ts);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}
function daysBetween(k1, k2) { return Math.round((new Date(k2 + 'T00:00:00') - new Date(k1 + 'T00:00:00')) / 86400000); }

function recordDaily(entry, m) {
  if (!m.disks.length) return;
  const disks = {};
  for (const d of m.disks) if (d.mount) disks[d.mount] = { used: d.used, total: d.total };
  entry.daily[dayKey(m.ts)] = { ts: m.ts, disks };            // 그날의 마지막 값이 남음
  const keys = Object.keys(entry.daily);
  if (keys.length > DAILY_KEEP) { keys.sort(); for (const k of keys.slice(0, keys.length - DAILY_KEEP)) delete entry.daily[k]; }
}

// 드라이브별 전일/7일/30일 대비 증가량과 예상 소진일
function diskGrowth(entry) {
  const daily = entry.daily || {};
  const keys = Object.keys(daily).sort();
  if (!keys.length) return [];
  const todayKey = keys[keys.length - 1];
  const today = daily[todayKey];
  const before = (n) => {            // n일 전 이하로 가장 가까운 스냅샷
    const t = new Date(today.ts); t.setDate(t.getDate() - n);
    const target = dayKey(t.getTime());
    let best = null;
    for (const k of keys) { if (k <= target) best = k; else break; }
    return best && best !== todayKey ? best : null;
  };
  const out = [];
  for (const [mount, cur] of Object.entries(today.disks)) {
    const g = { mount, used: cur.used, total: cur.total, day: null, week: null, month: null, rate_day: null, days_left: null };
    for (const [name, n] of [['day', 1], ['week', 7], ['month', 30]]) {
      const k = before(n);
      if (k && daily[k].disks[mount]) { g[name] = cur.used - daily[k].disks[mount].used; g[name + '_days'] = daysBetween(k, todayKey); }
    }
    const basis = ['month', 'week', 'day'].find((b) => g[b] != null);
    if (basis) {
      g.rate_day = g[basis] / g[basis + '_days'];
      g.basis_days = g[basis + '_days'];
      if (g.rate_day > 0) g.days_left = Math.floor((cur.total - cur.used) / g.rate_day);
    }
    out.push(g);
  }
  return out;
}

function ingest(raw, remoteIp) {
  const m = normalize(raw, remoteIp);
  let entry = store.get(m.host);
  if (!entry) { entry = { latest: null, history: [], daily: {} }; store.set(m.host, entry); }
  entry.latest = m;
  recordDaily(entry, m);
  entry.history.push({ ts: m.ts, cpu: m.cpu, mem_pct: m.mem_pct, net_rx: m.net_rx, net_tx: m.net_tx });
  if (entry.history.length > HISTORY) entry.history.splice(0, entry.history.length - HISTORY);
  dirty = true;
  if (LOG_FILE) fs.appendFile(LOG_FILE, JSON.stringify(m) + '\n', () => {});
  return m;
}

function serversView() {
  const now = Date.now();
  const list = [];
  for (const [host, e] of store) {
    list.push({ ...e.latest, online: now - e.latest.ts < OFFLINE_AFTER, age: Math.round((now - e.latest.ts) / 1000), growth: diskGrowth(e), days_tracked: Object.keys(e.daily || {}).length });
  }
  list.sort((a, b) => a.host.localeCompare(b.host));
  return list;
}

function serveStatic(res, file) {
  const p = path.join(__dirname, 'public', file);
  fs.readFile(p, (err, data) => {
    if (err) { res.writeHead(404); res.end('not found'); return; }
    const ext = path.extname(p);
    const type = ext === '.html' ? 'text/html; charset=utf-8' : ext === '.js' ? 'text/javascript' : ext === '.css' ? 'text/css' : 'application/octet-stream';
    res.writeHead(200, { 'Content-Type': type, 'Cache-Control': 'no-store' });
    res.end(data);
  });
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://x');
  // 프록시(nginx/IIS/Apache) 뒤에 있으면 X-Real-IP / X-Forwarded-For 로 실제 에이전트 IP를 받음
  const fwd = String(req.headers['x-real-ip'] || req.headers['x-forwarded-for'] || '').split(',')[0].trim();
  const remoteIp = (fwd || req.socket.remoteAddress || '').replace(/^::ffff:/, '');

  if (req.method === 'OPTIONS') {
    res.writeHead(204, { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'Content-Type, X-Token', 'Access-Control-Allow-Methods': 'POST, GET' });
    return res.end();
  }

  if (req.method === 'POST' && url.pathname === '/api/metrics') {
    try {
      const text = await readBody(req);
      const raw = JSON.parse(text || '{}');
      const token = req.headers['x-token'] || raw.token || '';
      if (TOKEN && token !== TOKEN) return json(res, 401, { ok: false, error: 'bad token' });
      const m = ingest(raw, remoteIp);
      console.log(`[${new Date().toLocaleTimeString()}] ${m.host} (${remoteIp}) cpu=${m.cpu}% mem=${m.mem_pct}%`);
      return json(res, 200, { ok: true });
    } catch (e) {
      return json(res, 400, { ok: false, error: String(e.message || e) });
    }
  }

  if (req.method === 'GET' && url.pathname === '/api/servers') return json(res, 200, { now: Date.now(), servers: serversView() });
  if (req.method === 'GET' && url.pathname === '/api/health') return json(res, 200, { ok: true, servers: store.size, uptime: Math.round(process.uptime()) });

  if (req.method === 'GET' && url.pathname === '/api/history') {
    const host = url.searchParams.get('host') || '';
    const e = store.get(host);
    if (!e) return json(res, 404, { ok: false, error: 'unknown host' });
    const daily = Object.keys(e.daily || {}).sort().map((k) => ({ date: k, disks: e.daily[k].disks }));
    return json(res, 200, { host, history: e.history, daily, growth: diskGrowth(e) });
  }

  if (req.method === 'GET' && (url.pathname === '/' || url.pathname === '/index.html')) return serveStatic(res, 'index.html');
  if (req.method === 'GET' && !url.pathname.includes('..')) return serveStatic(res, url.pathname.slice(1));

  res.writeHead(404); res.end('not found');
});

loadState();
if (STATE_FILE) setInterval(() => saveState(false), SAVE_EVERY).unref();
for (const sig of ['SIGINT', 'SIGTERM']) process.on(sig, () => { saveState(true); process.exit(0); });

server.listen(PORT, BIND, () => {
  console.log(`서버 모니터 수집기 실행 중: http://${BIND}:${PORT}/` + (TOKEN ? ' (토큰 사용)' : ' (토큰 없음)'));
  if (BIND === '127.0.0.1' || BIND === 'localhost') {
    console.log('내부 전용으로 실행 중입니다. IMS 웹서버 프록시(/monitor/)를 통해서만 접근됩니다.');
    console.log('에이전트 전송 주소: http://<IMS 주소>/monitor/api/metrics');
  } else {
    console.log(`에이전트 전송 주소: http://<이 서버 IP>:${PORT}/api/metrics`);
  }
});
