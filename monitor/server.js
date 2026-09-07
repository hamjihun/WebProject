'use strict';
// 서버 모니터링 수집기 (내 PC에서 실행)
// - 에이전트가 POST /api/metrics 로 보내는 JSON을 메모리에 쌓고
// - GET / 에서 대시보드 화면을 보여줍니다.
// 외부 패키지 없이 Node.js 내장 모듈만 사용합니다.

const VERSION = '1.9.0';
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
const DAILY_KEEP = Number(process.env.DAILY_KEEP || 400);
const HOURLY_FILE = process.env.HOURLY_FILE === '' ? '' : (process.env.HOURLY_FILE || path.join(__dirname, 'data', 'hourly.json'));  // 시간별 집계 (통계용, 1년)
const HOURLY_KEEP = Number(process.env.HOURLY_KEEP || 366 * 24);
const SETTINGS_FILE = process.env.SETTINGS_FILE || path.join(__dirname, 'data', 'settings.json');   // 알림 설정
const alerter = require('./alerts').create({ settingsFile: SETTINGS_FILE, log: console.log });     // 디스크 일별 스냅샷 보관 일수 (전일/주/월 증가량 계산용)

// { host: { latest: {...}, history: [ {...}, ... ], daily: {...} } }
const store = new Map();

// ---- 시간별 집계 (통계·리포트용): host → [ { h: 시각(ms, 정시), n: 표본수, ca: cpu평균, cx: cpu최대, ma: 메모리평균, mx: 메모리최대, off: 오프라인초 } ] ----
const hourly = {};            // 닫힌 시간대
const hourCur = {};           // 진행 중인 시간대 { host: { h, n, cs, cx, ms, mx, off } }
let hourlyDirty = false;
function hourOf(ts) { const d = new Date(ts); d.setMinutes(0, 0, 0); return d.getTime(); }
function closeHour(host) {
  const b = hourCur[host]; if (!b) return;
  (hourly[host] = hourly[host] || []).push({ h: b.h, n: b.n, ca: b.n ? Math.round(b.cs / b.n * 10) / 10 : null, cx: b.cx, ma: b.n ? Math.round(b.ms / b.n * 10) / 10 : null, mx: b.mx, off: b.off });
  if (hourly[host].length > HOURLY_KEEP) hourly[host].splice(0, hourly[host].length - HOURLY_KEEP);
  delete hourCur[host]; hourlyDirty = true;
}
function hourBucket(host, ts) {
  const h = hourOf(ts);
  if (hourCur[host] && hourCur[host].h !== h) closeHour(host);
  if (!hourCur[host]) hourCur[host] = { h, n: 0, cs: 0, cx: 0, ms: 0, mx: 0, off: 0 };
  return hourCur[host];
}
function recordHourly(m) {
  const b = hourBucket(m.host, m.ts);
  b.n++; b.cs += m.cpu; b.cx = Math.max(b.cx, m.cpu); b.ms += m.mem_pct; b.mx = Math.max(b.mx, m.mem_pct);
}
function loadHourly() {
  if (!HOURLY_FILE) return;
  try { const o = JSON.parse(fs.readFileSync(HOURLY_FILE, 'utf8')); Object.assign(hourly, o.hourly || {}); Object.assign(hourCur, o.cur || {}); } catch (e) { if (e.code !== 'ENOENT') console.warn('시간별 집계 읽기 실패:', e.message); }
}
function saveHourly(sync) {
  if (!HOURLY_FILE || !hourlyDirty) return;
  hourlyDirty = false;
  const data = JSON.stringify({ hourly, cur: hourCur });
  try {
    fs.mkdirSync(path.dirname(HOURLY_FILE), { recursive: true });
    if (sync) fs.writeFileSync(HOURLY_FILE, data); else fs.writeFile(HOURLY_FILE + '.tmp', data, (err) => { if (!err) fs.rename(HOURLY_FILE + '.tmp', HOURLY_FILE, () => {}); });
  } catch (e) { console.warn('시간별 집계 저장 실패:', e.message); }
}
function hourlyView(host, days) {
  const from = Date.now() - days * 86400000;
  const rows = (hourly[host] || []).filter((r) => r.h >= from);
  const c = hourCur[host]; if (c) rows.push({ h: c.h, n: c.n, ca: c.n ? Math.round(c.cs / c.n * 10) / 10 : null, cx: c.cx, ma: c.n ? Math.round(c.ms / c.n * 10) / 10 : null, mx: c.mx, off: c.off, open: true });
  return rows;
}

let topology = { nodes: {}, links: [], groups: [], notes: [] };   // 구성도 (화면에서 편집)
let order = [];   // 화면 카드 순서 (호스트명 배열). 화면에서 드래그하면 갱신됨

// ---- 스냅샷 저장/복원 (재시작해도 이력 유지) ----
function loadState() {
  if (!STATE_FILE) return;
  try {
    const obj = JSON.parse(fs.readFileSync(STATE_FILE, 'utf8'));
    const hosts = obj.hosts || obj;                       // 구버전 파일은 호스트 맵 그대로
    if (Array.isArray(obj.order)) order = obj.order.filter((h) => typeof h === 'string');
    if (obj.topology && typeof obj.topology === 'object') topology = { nodes: {}, links: [], groups: [], notes: [], ...obj.topology };
    alerter.importState(obj.alerts);
    for (const [host, e] of Object.entries(hosts)) if (e && e.latest) store.set(host, { latest: e.latest, history: (e.history || []).slice(-HISTORY), daily: e.daily || {} });
    console.log(`스냅샷 복원: ${store.size}대 (${STATE_FILE})`);
  } catch (e) { if (e.code !== 'ENOENT') console.warn('스냅샷 복원 실패:', e.message); }
}
let dirty = false;
function saveState(sync) {
  if (!STATE_FILE || !dirty) return;
  dirty = false;
  const hosts = {}; for (const [h, e] of store) hosts[h] = e;
  const obj = { hosts, order, topology, alerts: alerter.exportState() };
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
    name: String(raw.name || '').trim().slice(0, 60),   // 트레이에서 설정한 표시 이름
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
  const key = dayKey(m.ts);
  // 디스크 점검 시각이 설정돼 있으면 그 시각 이후 첫 값을 그날 값으로 고정 (새벽 백업 변동 제외)
  const t = /^(\d{1,2}):(\d{2})$/.exec(alerter.diskCheckTime() || '');
  if (t) {
    const d = new Date(m.ts), cur = d.getHours() * 60 + d.getMinutes();
    if (cur < Number(t[1]) * 60 + Number(t[2])) return;
    if (entry.daily[key] && entry.daily[key].fixed) return;
  }
  const disks = {};
  for (const d of m.disks) if (d.mount) disks[d.mount] = { used: d.used, total: d.total };
  entry.daily[key] = { ts: m.ts, disks, fixed: !!t };         // 점검 시각 미설정이면 그날의 마지막 값
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
  recordHourly(m); hourlyDirty = true;
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
    list.push({ ...e.latest, online: now - e.latest.ts < OFFLINE_AFTER, age: Math.round((now - e.latest.ts) / 1000), growth: diskGrowth(e), days_tracked: Object.keys(e.daily || {}).length, muted: alerter.isMuted(host), host_rules: alerter.getHostRules(host) });
  }
  // 저장된 순서 우선, 나머지는 이름순으로 뒤에
  const idx = new Map(order.map((h, i) => [h, i]));
  list.sort((a, b) => {
    const ia = idx.has(a.host) ? idx.get(a.host) : Infinity, ib = idx.has(b.host) ? idx.get(b.host) : Infinity;
    if (ia !== ib) return ia - ib;
    return (a.name || a.host).localeCompare(b.name || b.host, 'ko');
  });
  return list;
}

function removeHost(host) {
  const existed = store.delete(host);
  delete hourly[host]; delete hourCur[host]; hourlyDirty = true;
  if (topology.nodes[host] && !topology.nodes[host].custom) { delete topology.nodes[host]; topology.links = topology.links.filter((l) => l.a !== host && l.b !== host); }
  order = order.filter((h) => h !== host);
  alerter.forget(host);
  if (existed) dirty = true;
  return existed;
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
    res.writeHead(204, { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'Content-Type, X-Token', 'Access-Control-Allow-Methods': 'POST, GET, PUT' });
    return res.end();
  }

  if (req.method === 'POST' && url.pathname === '/api/metrics') {
    try {
      const text = await readBody(req);
      const raw = JSON.parse(text || '{}');
      const token = req.headers['x-token'] || raw.token || '';
      if (TOKEN && token !== TOKEN) {
        console.log(`[${new Date().toLocaleTimeString()}] 토큰 불일치: ${raw.host || '?'} (${remoteIp}) - 에이전트 토큰과 수집기 TOKEN 이 다릅니다`);
        return json(res, 401, { ok: false, error: 'bad token' });
      }
      const m = ingest(raw, remoteIp);
      console.log(`[${new Date().toLocaleTimeString()}] ${m.host} (${remoteIp}) cpu=${m.cpu}% mem=${m.mem_pct}%`);
      return json(res, 200, { ok: true });
    } catch (e) {
      return json(res, 400, { ok: false, error: String(e.message || e) });
    }
  }

  // 에이전트 제거 시 호출: 목록에서 삭제 (에이전트가 다시 보내면 자동으로 다시 나타남)
  if (req.method === 'POST' && url.pathname === '/api/unregister') {
    try {
      const raw = JSON.parse((await readBody(req)) || '{}');
      const host = String(raw.host || '').trim();
      if (!host) return json(res, 400, { ok: false, error: 'host required' });
      const removed = removeHost(host);
      console.log(`[${new Date().toLocaleTimeString()}] 목록에서 제거: ${host} (${remoteIp})${removed ? '' : ' - 없던 호스트'}`);
      saveState(false);
      return json(res, 200, { ok: true, removed });
    } catch (e) { return json(res, 400, { ok: false, error: String(e.message || e) }); }
  }

  // 서버별 알림 끄기/켜기
  if (req.method === 'POST' && url.pathname === '/api/mute') {
    try {
      const raw = JSON.parse((await readBody(req)) || '{}');
      const host = String(raw.host || '').trim();
      if (!host || !store.has(host)) return json(res, 404, { ok: false, error: 'unknown host' });
      let muted = alerter.isMuted(host);
      if (typeof raw.muted === 'boolean') { muted = alerter.setMuted(host, raw.muted); console.log(`[${new Date().toLocaleTimeString()}] 알림 ${muted ? '끔' : '켬'}: ${host}`); }
      let rules = alerter.getHostRules(host);
      if (raw.rules && typeof raw.rules === 'object') { rules = alerter.setHostRules(host, raw.rules); console.log(`[${new Date().toLocaleTimeString()}] 서버별 규칙: ${host} ${JSON.stringify(rules)}`); }
      return json(res, 200, { ok: true, host, muted, rules });
    } catch (e) { return json(res, 400, { ok: false, error: String(e.message || e) }); }
  }

  // 시간별 집계 조회 (통계용): ?host=이름&days=30
  if (req.method === 'GET' && url.pathname === '/api/hourly') {
    const host = url.searchParams.get('host') || '', days = Math.min(400, Math.max(1, Number(url.searchParams.get('days') || 7)));
    if (host) return json(res, 200, { host, rows: hourlyView(host, days) });
    const all = {}; for (const h of store.keys()) all[h] = hourlyView(h, days);
    return json(res, 200, { days, hosts: all });
  }
  // 구성도 저장/조회
  if (req.method === 'GET' && url.pathname === '/api/topology') return json(res, 200, topology);
  if (req.method === 'PUT' && url.pathname === '/api/topology') {
    try {
      const t = JSON.parse((await readBody(req)) || '{}');
      topology = { nodes: t.nodes && typeof t.nodes === 'object' ? t.nodes : {}, links: Array.isArray(t.links) ? t.links : [], groups: Array.isArray(t.groups) ? t.groups : [], notes: Array.isArray(t.notes) ? t.notes : [] };
      dirty = true; saveState(false);
      return json(res, 200, { ok: true });
    } catch (e) { return json(res, 400, { ok: false, error: String(e.message || e) }); }
  }

  // 화면 카드 순서 저장
  if (req.method === 'PUT' && url.pathname === '/api/order') {
    try {
      const raw = JSON.parse((await readBody(req)) || '{}');
      if (!Array.isArray(raw.order)) return json(res, 400, { ok: false, error: 'order array required' });
      order = raw.order.map(String).filter((h) => store.has(h));
      dirty = true; saveState(false);
      return json(res, 200, { ok: true, order });
    } catch (e) { return json(res, 400, { ok: false, error: String(e.message || e) }); }
  }

  // ---- 알림 ----
  if (req.method === 'GET' && url.pathname === '/api/alerts') return json(res, 200, { active: alerter.getActive(), recent: alerter.getRecent(Number(url.searchParams.get('n') || 10)), months: alerter.listLogs() });
  // 알림 로그 파일: 보기(텍스트) 또는 다운로드. ?month=YYYY-MM, ?download=1
  if (req.method === 'GET' && url.pathname === '/api/alerts/log') {
    const { month, text } = alerter.readLog(url.searchParams.get('month'));
    const headers = { 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store' };
    if (url.searchParams.get('download') === '1') headers['Content-Disposition'] = `attachment; filename="alerts-${month}.txt"`;
    res.writeHead(200, headers);
    return res.end(text || `(${month} 알림 이력 없음)\r\n`);
  }
  if (req.method === 'GET' && url.pathname === '/api/settings') return json(res, 200, alerter.getSettings(true));
  if (req.method === 'PUT' && url.pathname === '/api/settings') {
    try { const patch = JSON.parse((await readBody(req)) || '{}'); return json(res, 200, alerter.updateSettings(patch)); }
    catch (e) { return json(res, 400, { ok: false, error: String(e.message || e) }); }
  }
  if (req.method === 'POST' && url.pathname === '/api/alerts/test') {
    try { return json(res, 200, await alerter.sendTest()); } catch (e) { return json(res, 502, { ok: false, error: String(e.message || e) }); }
  }
  if (req.method === 'POST' && url.pathname === '/api/alerts/discover') {
    try { return json(res, 200, { ok: true, chats: await alerter.discoverChats() }); } catch (e) { return json(res, 502, { ok: false, error: String(e.message || e) }); }
  }

  if (req.method === 'GET' && url.pathname === '/api/servers') return json(res, 200, { now: Date.now(), version: VERSION, servers: serversView(), active_alerts: alerter.getActive() });
  if (req.method === 'GET' && url.pathname === '/api/health') return json(res, 200, { ok: true, version: VERSION, servers: store.size, uptime: Math.round(process.uptime()) });

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
loadHourly();
if (STATE_FILE) setInterval(() => saveState(false), SAVE_EVERY).unref();
if (HOURLY_FILE) setInterval(() => saveHourly(false), 5 * 60000).unref();
setInterval(() => {
  const view = serversView();
  try { alerter.evaluate(view); } catch (e) { console.error('알림 평가 오류:', e.message); }
  for (const s of view) if (!s.online) { hourBucket(s.host, Date.now()).off += 10; hourlyDirty = true; }   // 오프라인 시간 누적 (가동률 통계용)
}, 10000).unref();
for (const sig of ['SIGINT', 'SIGTERM']) process.on(sig, () => { saveState(true); saveHourly(true); process.exit(0); });

server.on('error', (e) => {
  if (e.code === 'EADDRINUSE') { console.error(`포트 ${PORT} 가 이미 사용 중입니다. 예전 수집기가 아직 실행 중일 수 있습니다. (설치 스크립트를 다시 실행하거나 node.exe 를 종료하세요)`); process.exit(2); }
  throw e;
});
server.listen(PORT, BIND, () => {
  console.log(`서버 모니터 수집기 v${VERSION} 실행 중: http://${BIND}:${PORT}/` + (TOKEN ? ' (토큰 사용)' : ' (토큰 없음)'));
  if (BIND === '127.0.0.1' || BIND === 'localhost') {
    console.log('내부 전용으로 실행 중입니다. IMS 웹서버 프록시(/monitor/)를 통해서만 접근됩니다.');
    console.log('에이전트 전송 주소: http://<IMS 주소>/monitor/api/metrics');
  } else {
    console.log(`에이전트 전송 주소: http://<이 서버 IP>:${PORT}/api/metrics`);
  }
});
