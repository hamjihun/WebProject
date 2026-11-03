// 연말 경품 추첨 - 동시 접속 서버 (외부 패키지 없음, Node.js 18+)
//   실행 : node server.js            (PORT=3000, HOST_KEY 자동 생성)
//          PORT=8080 HOST_KEY=mykey node server.js
//   진행자: http://서버주소:3000/?host=<HOST_KEY>
//   관람자: http://서버주소:3000/
'use strict';
const http = require('http');
const fs = require('fs');
const path = require('path');
const os = require('os');
const crypto = require('crypto');

const PORT = +process.env.PORT || 3000;
const HOST_KEY = process.env.HOST_KEY || crypto.randomBytes(4).toString('hex');
const ROOT = __dirname;
const STATE_FILE = path.join(ROOT, 'state.json');
const MAX_BODY = 5 * 1024 * 1024;

let state = null;
try { state = JSON.parse(fs.readFileSync(STATE_FILE, 'utf8')); } catch (e) { state = null; }
let saveTimer = null;
function persist() {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => {
    fs.writeFile(STATE_FILE + '.tmp', JSON.stringify(state), err => {
      if (!err) fs.rename(STATE_FILE + '.tmp', STATE_FILE, () => {});
    });
  }, 300);
}

const clients = new Set();
function send(res, obj) { res.write(`data: ${JSON.stringify(obj)}\n\n`); }
function broadcast(obj) { const s = `data: ${JSON.stringify(obj)}\n\n`; for (const c of clients) c.write(s); }
function broadcastViewers() { broadcast({ event: 'viewers', data: { n: clients.size } }); }
setInterval(() => { for (const c of clients) c.write(': ping\n\n'); }, 20000);

function json(res, code, obj) {
  res.writeHead(code, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' });
  res.end(JSON.stringify(obj));
}
const MIME = {
  '.html': 'text/html; charset=utf-8', '.js': 'application/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8',
  '.png': 'image/png', '.jpg': 'image/jpeg', '.svg': 'image/svg+xml', '.ico': 'image/x-icon', '.json': 'application/json',
};
const isHost = req => req.headers['x-host-key'] === HOST_KEY;

const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://localhost');
  const p = url.pathname;

  if (p === '/api/state' && req.method === 'GET') return json(res, 200, { state });
  if (p === '/api/check') return json(res, isHost(req) ? 200 : 403, { ok: isHost(req) });

  if (p === '/api/events') {
    res.writeHead(200, { 'content-type': 'text/event-stream; charset=utf-8', 'cache-control': 'no-cache', connection: 'keep-alive', 'x-accel-buffering': 'no' });
    res.write('retry: 2000\n\n');
    clients.add(res);
    broadcastViewers();
    req.on('close', () => { clients.delete(res); broadcastViewers(); });
    return;
  }

  if (p === '/api/emit' && req.method === 'POST') {
    if (!isHost(req)) return json(res, 403, { ok: false });
    let size = 0; const chunks = [];
    req.on('data', c => { size += c.length; if (size > MAX_BODY) { req.destroy(); } else chunks.push(c); });
    req.on('end', () => {
      let body;
      try { body = JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch (e) { return json(res, 400, { ok: false }); }
      if (body.state) { state = body.state; persist(); }
      broadcast({ event: body.event, data: body.data || {}, state: body.state || null });
      json(res, 200, { ok: true });
    });
    return;
  }

  // 정적 파일
  if (req.method !== 'GET' && req.method !== 'HEAD') { res.writeHead(405); return res.end(); }
  let rel = decodeURIComponent(p === '/' ? '/index.html' : p);
  const file = path.normalize(path.join(ROOT, rel));
  if (!file.startsWith(ROOT + path.sep) || /server\.js$|state\.json/.test(file)) { res.writeHead(404); return res.end(); }
  fs.readFile(file, (err, buf) => {
    if (err) { res.writeHead(404); return res.end('Not found'); }
    res.writeHead(200, { 'content-type': MIME[path.extname(file).toLowerCase()] || 'application/octet-stream', 'cache-control': 'no-cache' });
    res.end(buf);
  });
});
server.requestTimeout = 0;
server.listen(PORT, () => {
  const ips = Object.values(os.networkInterfaces()).flat().filter(i => i && i.family === 'IPv4' && !i.internal).map(i => i.address);
  const host = ips[0] || 'localhost';
  console.log('\n🎁 연말 경품 추첨 서버 실행 중');
  console.log(`   진행자(추첨 조작) : http://${host}:${PORT}/?host=${HOST_KEY}`);
  console.log(`   관람자(실시간 시청): http://${host}:${PORT}/`);
  console.log('   ※ 진행자 주소는 외부에 공유하지 마세요.\n');
});
