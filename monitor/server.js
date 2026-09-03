'use strict';
// 서버 모니터링 수집기 (내 PC에서 실행)
// - 에이전트가 POST /api/metrics 로 보내는 JSON을 메모리에 쌓고
// - GET / 에서 대시보드 화면을 보여줍니다.
// 외부 패키지 없이 Node.js 내장 모듈만 사용합니다.

const http = require('http');
const fs = require('fs');
const path = require('path');

const PORT = Number(process.env.PORT || 8787);
const TOKEN = process.env.TOKEN || '';                 // 설정하면 에이전트도 같은 값을 보내야 함
const HISTORY = Number(process.env.HISTORY || 720);     // 서버당 보관 포인트 수 (5초 간격이면 1시간)
const OFFLINE_AFTER = Number(process.env.OFFLINE_AFTER || 90) * 1000; // 이 시간 동안 데이터 없으면 오프라인
const LOG_FILE = process.env.LOG_FILE || '';            // 지정하면 JSON Lines 로 파일에도 기록

// { host: { latest: {...}, history: [ {...}, ... ] } }
const store = new Map();

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

function ingest(raw, remoteIp) {
  const m = normalize(raw, remoteIp);
  let entry = store.get(m.host);
  if (!entry) { entry = { latest: null, history: [] }; store.set(m.host, entry); }
  entry.latest = m;
  entry.history.push({ ts: m.ts, cpu: m.cpu, mem_pct: m.mem_pct, net_rx: m.net_rx, net_tx: m.net_tx });
  if (entry.history.length > HISTORY) entry.history.splice(0, entry.history.length - HISTORY);
  if (LOG_FILE) fs.appendFile(LOG_FILE, JSON.stringify(m) + '\n', () => {});
  return m;
}

function serversView() {
  const now = Date.now();
  const list = [];
  for (const [host, e] of store) {
    list.push({ ...e.latest, online: now - e.latest.ts < OFFLINE_AFTER, age: Math.round((now - e.latest.ts) / 1000) });
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
  const remoteIp = (req.socket.remoteAddress || '').replace(/^::ffff:/, '');

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

  if (req.method === 'GET' && url.pathname === '/api/history') {
    const host = url.searchParams.get('host') || '';
    const e = store.get(host);
    if (!e) return json(res, 404, { ok: false, error: 'unknown host' });
    return json(res, 200, { host, history: e.history });
  }

  if (req.method === 'GET' && (url.pathname === '/' || url.pathname === '/index.html')) return serveStatic(res, 'index.html');
  if (req.method === 'GET' && !url.pathname.includes('..')) return serveStatic(res, url.pathname.slice(1));

  res.writeHead(404); res.end('not found');
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`서버 모니터 수집기 실행 중: http://0.0.0.0:${PORT}/`);
  console.log(`에이전트 전송 주소: http://<이 PC IP>:${PORT}/api/metrics` + (TOKEN ? ' (토큰 사용)' : ' (토큰 없음)'));
});
