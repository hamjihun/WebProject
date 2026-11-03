// 연말 경품 추첨 - 동시 접속 서버 (외부 패키지 없음, Node.js 18+)
//   실행 : node server.js   (Windows는 start.bat 더블클릭)
//   설정 : config.json  { "port": 3000, "hostKey": "진행자 비밀키", "openBrowser": true }
//          처음 실행 시 자동 생성됩니다. 환경변수 PORT / HOST_KEY 가 있으면 그 값이 우선합니다.
//   진행자: http://서버주소:포트/?host=<hostKey>
//   관람자: http://서버주소:포트/
'use strict';
const http = require('http');
const fs = require('fs');
const path = require('path');
const os = require('os');
const crypto = require('crypto');

const { exec } = require('child_process');
const ROOT = __dirname;
const CONFIG_FILE = path.join(ROOT, 'config.json');
let config = {};
try { config = JSON.parse(fs.readFileSync(CONFIG_FILE, 'utf8')); } catch (e) { config = {}; }
if (!config.hostKey) config.hostKey = crypto.randomBytes(4).toString('hex');
if (!config.port) config.port = 3000;
if (config.openBrowser === undefined) config.openBrowser = true;
try { fs.writeFileSync(CONFIG_FILE, JSON.stringify(config, null, 2)); } catch (e) {}
const PORT = +process.env.PORT || +config.port;
const HOST_KEY = process.env.HOST_KEY || String(config.hostKey);
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
  if (!file.startsWith(ROOT + path.sep) || /server\.js$|state\.json|config\.json|접속주소\.txt|\.(bat|ps1|sh)$/.test(file)) { res.writeHead(404); return res.end(); }
  fs.readFile(file, (err, buf) => {
    if (err) { res.writeHead(404); return res.end('Not found'); }
    res.writeHead(200, { 'content-type': MIME[path.extname(file).toLowerCase()] || 'application/octet-stream', 'cache-control': 'no-cache' });
    res.end(buf);
  });
});
server.requestTimeout = 0;
server.on('error', err => {
  if (err.code === 'EADDRINUSE') console.error(`\n❌ ${PORT}번 포트를 이미 사용 중입니다. 서버가 이미 켜져 있거나, config.json의 port 값을 바꿔주세요.\n`);
  else console.error(err);
  process.exitCode = 1;
});
server.listen(PORT, () => {
  const ips = Object.values(os.networkInterfaces()).flat().filter(i => i && i.family === 'IPv4' && !i.internal).map(i => i.address);
  const hosts = ips.length ? ips : ['localhost'];
  const lines = [
    '🎁 연말 경품 추첨 서버 실행 중 (이 창을 닫으면 서버가 꺼집니다)',
    '',
    '[진행자 - 추첨 조작용, TV에 띄우는 화면]  ※ 외부 공유 금지',
    `   http://localhost:${PORT}/?host=${HOST_KEY}`,
    '',
    '[관람자 - 전 직원 공유용 주소]',
    ...hosts.map(h => `   http://${h}:${PORT}/`),
    '',
  ];
  console.log('\n' + lines.join('\n'));
  try { fs.writeFileSync(path.join(ROOT, '접속주소.txt'), lines.join('\r\n') + '\r\n', 'utf8'); } catch (e) {}
  if (config.openBrowser && !process.env.NO_OPEN) {
    const url = `http://localhost:${PORT}/?host=${HOST_KEY}`;
    const cmd = process.platform === 'win32' ? `start "" "${url}"` : process.platform === 'darwin' ? `open "${url}"` : `xdg-open "${url}"`;
    exec(cmd, () => {});
  }
});
