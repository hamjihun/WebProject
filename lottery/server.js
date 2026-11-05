// 연말 경품 추첨 - 동시 접속 서버 (외부 패키지 없음, Node.js 18+)
//   실행 : node server.js   (Windows는 start.bat 더블클릭)
//   설정 : config.json  (처음 실행 시 자동 생성)
//     {
//       "port": 15138,            접속 포트
//       "basePath": "/event",     접속 경로  →  http://서버IP:15138/event/
//       "host": "0.0.0.0",        다른 서버가 중계(프록시)만 할 때는 "127.0.0.1"
//       "adminUser": "admin",     관리자 아이디
//       "adminPassword": "...",   관리자 비밀번호 (처음 실행 시 암호화된 값으로 바뀌어 저장됨)
//       "openBrowser": true
//     }
//   관리자: 화면 오른쪽 위 [🔒 관리자] 로 로그인하면 추첨 조작 가능
//   그 외 접속자: 시청만 가능
'use strict';
const http = require('http');
const fs = require('fs');
const path = require('path');
const os = require('os');
const crypto = require('crypto');
const { exec } = require('child_process');

const ROOT = __dirname;
const CONFIG_FILE = path.join(ROOT, 'config.json');
const STATE_FILE = path.join(ROOT, 'state.json');
const LOG_DIR = path.join(ROOT, 'logs');
const MAX_BODY = 5 * 1024 * 1024;
const SESSION_HOURS = 12;

function hashPw(pw) { const salt = crypto.randomBytes(16).toString('hex'); return `scrypt:${salt}:${crypto.scryptSync(pw, salt, 32).toString('hex')}`; }

/* ---------- 설정 ---------- */
let config = {};
try { config = JSON.parse(fs.readFileSync(CONFIG_FILE, 'utf8')); } catch (e) { config = {}; }
if (!config.port) config.port = 15138;
if (config.basePath === undefined) config.basePath = '/event';
if (!config.host) config.host = '0.0.0.0';
if (!config.adminUser) config.adminUser = 'admin';
if (config.openBrowser === undefined) config.openBrowser = true;
let generatedPw = null;
if (config.adminPassword) {                       // 평문 비밀번호 → 해시로 바꿔 저장
  config.adminPasswordHash = hashPw(String(config.adminPassword));
  delete config.adminPassword;
} else if (!config.adminPasswordHash) {           // 비밀번호가 없으면 임의로 만들어 안내
  generatedPw = crypto.randomBytes(6).toString('base64url');
  config.adminPasswordHash = hashPw(generatedPw);
}
delete config.hostKey;
try { fs.writeFileSync(CONFIG_FILE, JSON.stringify(config, null, 2)); } catch (e) {}

const PORT = +process.env.PORT || +config.port;
const BIND = process.env.BIND || config.host;
const BASE = (() => { let b = String(process.env.BASE_PATH ?? config.basePath ?? '').trim(); if (!b || b === '/') return ''; if (!b.startsWith('/')) b = '/' + b; return b.replace(/\/+$/, ''); })();

function checkPw(pw) {
  const [kind, salt, hex] = String(config.adminPasswordHash || '').split(':');
  if (kind !== 'scrypt' || !salt || !hex) return false;
  const a = crypto.scryptSync(String(pw), salt, 32), b = Buffer.from(hex, 'hex');
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}
function safeEq(a, b) { a = Buffer.from(String(a)); b = Buffer.from(String(b)); return a.length === b.length && crypto.timingSafeEqual(a, b); }

/* ---------- 상태 / 로그 ---------- */
let state = null;
try { state = JSON.parse(fs.readFileSync(STATE_FILE, 'utf8')); } catch (e) { state = null; }
let saveTimer = null;
function persist() {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => {
    fs.writeFile(STATE_FILE + '.tmp', JSON.stringify(state), err => { if (!err) fs.rename(STATE_FILE + '.tmp', STATE_FILE, () => {}); });
  }, 300);
}
const p2 = n => String(n).padStart(2, '0');
const today = () => { const d = new Date(); return `${d.getFullYear()}-${p2(d.getMonth() + 1)}-${p2(d.getDate())}`; };
const nowStr = () => { const d = new Date(); return `${today()} ${p2(d.getHours())}:${p2(d.getMinutes())}:${p2(d.getSeconds())}`; };
function appendLog(name, line) { try { fs.mkdirSync(LOG_DIR, { recursive: true }); fs.appendFileSync(path.join(LOG_DIR, name), line + '\n'); } catch (e) { console.error('로그 저장 실패', e.message); } }

// 추첨 로그: 관리자 화면이 남긴 기록을 날짜별 파일(logs/audit-YYYY-MM-DD.jsonl)에 계속 덧붙임
let lastSeq = 0;
if (state && Array.isArray(state.audit) && state.audit.length) lastSeq = state.audit[state.audit.length - 1].seq || 0;
function appendAudit(st) {
  if (!st || !Array.isArray(st.audit)) return;
  const fresh = st.audit.filter(e => e && e.seq > lastSeq);
  if (!fresh.length) return;
  lastSeq = fresh[fresh.length - 1].seq;
  appendLog(`audit-${today()}.jsonl`, fresh.map(e => JSON.stringify(e)).join('\n'));
}
function publicState(st) { if (!st) return st; const { audit, ...rest } = st; return rest; }   // 시청자에게는 로그 제외

/* ---------- 관리자 세션 ---------- */
const sessions = new Map();          // token -> 만료시각
const attempts = new Map();          // ip -> [시도 시각]
function cookies(req) { const o = {}; String(req.headers.cookie || '').split(';').forEach(c => { const i = c.indexOf('='); if (i > 0) { try { o[c.slice(0, i).trim()] = decodeURIComponent(c.slice(i + 1).trim()); } catch (e) {} } }); return o; }
function isAdmin(req) {
  const t = cookies(req).lottery_admin; if (!t) return false;
  const exp = sessions.get(t); if (!exp) return false;
  if (exp < Date.now()) { sessions.delete(t); return false; }
  return true;
}
const ipOf = req => String(req.headers['x-forwarded-for'] || req.socket.remoteAddress || '').split(',')[0].trim().replace(/^::ffff:/, '');

/* ---------- 실시간 전송 (SSE) ---------- */
const clients = new Set();
function broadcast(obj) { const s = `data: ${JSON.stringify(obj)}\n\n`; for (const c of clients) c.write(s); }
function broadcastViewers() { broadcast({ event: 'viewers', data: { n: clients.size } }); }
setInterval(() => { for (const c of clients) c.write(': ping\n\n'); }, 20000);

function json(res, code, obj, headers) {
  res.writeHead(code, Object.assign({ 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' }, headers || {}));
  res.end(JSON.stringify(obj));
}
function readBody(req, cb) {
  let size = 0; const chunks = [];
  req.on('data', c => { size += c.length; if (size > MAX_BODY) req.destroy(); else chunks.push(c); });
  req.on('end', () => { let body = null; try { body = JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch (e) {} cb(body); });
}
const MIME = {
  '.html': 'text/html; charset=utf-8', '.js': 'application/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8',
  '.png': 'image/png', '.jpg': 'image/jpeg', '.svg': 'image/svg+xml', '.ico': 'image/x-icon', '.json': 'application/json',
  '.xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', '.txt': 'text/plain; charset=utf-8',
};
const BLOCK = /[\\/](server\.js|state\.json(\.tmp)?|config\.json|접속주소\.txt|package-zip\.py)$|\.(bat|ps1|sh)$|[\\/](logs|node|dist|\.git)([\\/]|$)/;

const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://localhost');
  let p = url.pathname;
  try { p = decodeURIComponent(p); } catch (e) { res.writeHead(400); return res.end(); }
  // 접속 경로(basePath) 처리: /event → /event/ 로 맞춤
  if (BASE) {
    if (p === BASE) { res.writeHead(302, { location: BASE + '/' + url.search }); return res.end(); }
    if (p === '/') { res.writeHead(302, { location: BASE + '/' }); return res.end(); }
    if (!p.startsWith(BASE + '/')) { res.writeHead(404); return res.end('Not found'); }
    p = p.slice(BASE.length);
  }
  const cookiePath = (BASE || '') + '/';

  if (p === '/api/state' && req.method === 'GET') return json(res, 200, { state: isAdmin(req) ? state : publicState(state) });
  if (p === '/api/me') return json(res, 200, { admin: isAdmin(req), user: isAdmin(req) ? config.adminUser : null });

  if (p === '/api/login' && req.method === 'POST') {
    const ip = ipOf(req), now = Date.now();
    const list = (attempts.get(ip) || []).filter(t => now - t < 5 * 60 * 1000);
    if (list.length >= 5) { appendLog('admin-access.log', `${nowStr()}\t${ip}\t차단(시도 초과)`); return json(res, 429, { ok: false, msg: '로그인 시도가 너무 많습니다. 5분 뒤에 다시 시도하세요.' }); }
    return readBody(req, body => {
      const ok = !!body && safeEq(body.user || '', config.adminUser) && checkPw(body.pw || '');
      if (!ok) {
        list.push(now); attempts.set(ip, list);
        appendLog('admin-access.log', `${nowStr()}\t${ip}\t로그인 실패\t${String(body && body.user || '').slice(0, 40)}`);
        return json(res, 401, { ok: false, msg: '아이디 또는 비밀번호가 올바르지 않습니다.' });
      }
      attempts.delete(ip);
      const token = crypto.randomBytes(24).toString('hex');
      sessions.set(token, now + SESSION_HOURS * 3600 * 1000);
      appendLog('admin-access.log', `${nowStr()}\t${ip}\t로그인 성공\t${config.adminUser}`);
      json(res, 200, { ok: true }, { 'set-cookie': `lottery_admin=${token}; Path=${cookiePath}; HttpOnly; SameSite=Strict; Max-Age=${SESSION_HOURS * 3600}` });
    });
  }
  if (p === '/api/logout' && req.method === 'POST') {
    const t = cookies(req).lottery_admin; if (t) sessions.delete(t);
    appendLog('admin-access.log', `${nowStr()}\t${ipOf(req)}\t로그아웃`);
    return json(res, 200, { ok: true }, { 'set-cookie': `lottery_admin=; Path=${cookiePath}; HttpOnly; SameSite=Strict; Max-Age=0` });
  }

  if (p === '/api/events') {
    res.writeHead(200, { 'content-type': 'text/event-stream; charset=utf-8', 'cache-control': 'no-cache', connection: 'keep-alive', 'x-accel-buffering': 'no' });
    res.write('retry: 2000\n\n');
    clients.add(res); broadcastViewers();
    req.on('close', () => { clients.delete(res); broadcastViewers(); });
    return;
  }

  if (p === '/api/emit' && req.method === 'POST') {
    if (!isAdmin(req)) return json(res, 403, { ok: false });
    return readBody(req, body => {
      if (!body) return json(res, 400, { ok: false });
      if (body.state) {
        // 추첨 로그가 줄어드는(지워지는) 상태로는 덮어쓰지 않음
        if (state && Array.isArray(state.audit) && Array.isArray(body.state.audit) && body.state.audit.length < state.audit.length) {
          console.warn('⚠ 추첨 로그가 줄어든 상태가 들어와 기존 로그를 유지합니다.');
          body.state.audit = state.audit;
        }
        state = body.state; appendAudit(state); persist();
      }
      // 시청 화면에는 가벼운 이벤트만 보내고, 전체 상태는 'state' 이벤트일 때만 (로그 제외)
      broadcast({ event: body.event, data: body.data || {}, state: body.event === 'state' ? publicState(state) : null });
      json(res, 200, { ok: true });
    });
  }

  // 정적 파일
  if (req.method !== 'GET' && req.method !== 'HEAD') { res.writeHead(405); return res.end(); }
  const file = path.normalize(path.join(ROOT, p === '/' ? '/index.html' : p));
  if (!file.startsWith(ROOT + path.sep) || BLOCK.test(file)) { res.writeHead(404); return res.end('Not found'); }
  fs.readFile(file, (err, buf) => {
    if (err) { res.writeHead(404); return res.end('Not found'); }
    res.writeHead(200, { 'content-type': MIME[path.extname(file).toLowerCase()] || 'application/octet-stream', 'cache-control': 'no-cache' });
    res.end(buf);
  });
});
server.requestTimeout = 0;
server.on('error', err => {
  if (err.code === 'EADDRINUSE') {
    console.error(`\n❌ ${PORT}번 포트를 이미 다른 프로그램이 사용 중입니다.`);
    console.error('   - 추첨 서버가 이미 켜져 있다면 그 창을 사용하세요.');
    console.error('   - 다른 시스템(예: 서버 모니터링)이 이 포트를 쓰고 있다면, config.json의 port를 다른 번호(예: 3000)로 바꾸고');
    console.error(`     그 시스템에서 ${BASE || '/'} 경로를 이 서버로 중계(프록시)하도록 설정하세요. (README 참고)\n`);
  } else console.error(err);
  process.exitCode = 1;
});
server.listen(PORT, BIND, () => {
  const ips = Object.values(os.networkInterfaces()).flat().filter(i => i && i.family === 'IPv4' && !i.internal).map(i => i.address);
  const hosts = BIND === '127.0.0.1' ? ['127.0.0.1'] : (ips.length ? ips : ['localhost']);
  const lines = [
    '🎁 연말 경품 추첨 서버 실행 중 (이 창을 닫으면 서버가 꺼집니다)',
    '',
    '[접속 주소 - 전 직원 공유용]',
    ...hosts.map(h => `   http://${h}:${PORT}${BASE}/`),
    '',
    `[관리자] 화면 오른쪽 위 [🔒 관리자] → 아이디 ${config.adminUser} 로 로그인하면 추첨을 조작할 수 있습니다.`,
    ...(generatedPw ? [`   ※ 비밀번호가 설정되지 않아 임시 비밀번호를 만들었습니다: ${generatedPw}`, '     config.json 에 "adminPassword": "원하는비밀번호" 를 넣고 다시 시작하면 바뀝니다.'] : []),
    '   일반 접속자는 시청만 할 수 있습니다.',
    '',
    `[식당 TV 현황판]  http://${hosts[0]}:${PORT}${BASE}/?view=board`,
    '',
  ];
  console.log('\n' + lines.join('\n'));
  try { fs.writeFileSync(path.join(ROOT, '접속주소.txt'), lines.filter(l => !l.includes('임시 비밀번호')).join('\r\n') + '\r\n', 'utf8'); } catch (e) {}
  if (config.openBrowser && !process.env.NO_OPEN) {
    const u = `http://localhost:${PORT}${BASE}/`;
    const cmd = process.platform === 'win32' ? `start "" "${u}"` : process.platform === 'darwin' ? `open "${u}"` : `xdg-open "${u}"`;
    exec(cmd, () => {});
  }
});
