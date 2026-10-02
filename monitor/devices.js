'use strict';
// 에이전트 없는 장비 감시 (스위치 · 방화벽 · 공유기 · 프린터 · CCTV · UPS · ipTIME NAS 등)
// 수집기가 30초마다 Ping 또는 TCP 포트 연결로 살아 있는지 본다. 외부 패키지 없음.
// 저장 위치: data/devices.json  [ { id, name, host, mode:'ping'|'tcp', port, kind, alert, memo } ]
// 확인 결과(응답 시간·최근 기록)는 메모리에만 둔다 (수집기를 다시 켜면 새로 쌓인다).
const fs = require('fs');
const path = require('path');
const net = require('net');
const crypto = require('crypto');
const { execFile } = require('child_process');

const KINDS = ['switch', 'firewall', 'router', 'wifi', 'printer', 'camera', 'nas', 'ups', 'server', 'pc', 'storage', 'etc'];
const MAX_DEV = 200;
const HIST = 2880;                 // 30초 간격이면 24시간
const DOWN_AFTER = 3;              // 연속 3번(약 1분 30초) 실패하면 "응답 없음"
const isHost = (v) => /^[A-Za-z0-9][A-Za-z0-9.\-:]{0,99}$/.test(String(v || ''));
const str = (v, n) => String(v == null ? '' : v).trim().slice(0, n);

function pingOnce(host, timeoutMs) {
  return new Promise((resolve) => {
    const win = process.platform === 'win32';
    const args = win ? ['-n', '1', '-w', String(timeoutMs), host] : ['-c', '1', '-W', String(Math.ceil(timeoutMs / 1000)), host];
    const t0 = Date.now();
    execFile('ping', args, { timeout: timeoutMs + 3000, windowsHide: true, encoding: 'latin1' }, (err, out) => {
      out = String(out || '');
      // 윈도우는 "대상 호스트에 연결할 수 없습니다" 에도 성공(0)으로 끝나는 경우가 있어, 실제 응답(TTL=)이 있는지로 판단한다
      const ok = /ttl[=:]/i.test(out);
      const m = /[=<]\s*([\d.]+)\s*ms/i.exec(out);
      resolve({ ok, ms: ok ? (m ? Math.max(0, Math.round(Number(m[1]))) : Date.now() - t0) : null, err: ok ? '' : (err && err.code === 'ENOENT' ? 'ping 명령 없음' : '응답 없음') });
    });
  });
}
function tcpOnce(host, port, timeoutMs) {
  return new Promise((resolve) => {
    const t0 = Date.now();
    const s = net.connect({ host, port });
    let done = false;
    const end = (ok, err) => { if (done) return; done = true; s.destroy(); resolve({ ok, ms: ok ? Date.now() - t0 : null, err: ok ? '' : err }); };
    s.setTimeout(timeoutMs, () => end(false, '시간 초과'));
    s.once('connect', () => end(true));
    s.once('error', (e) => end(false, e.code === 'ECONNREFUSED' ? '포트 닫힘' : '연결 실패'));
  });
}

function create(opts) {
  const FILE = opts.file;
  const log = opts.log || (() => {});
  let list = [];
  const st = new Map();             // id → { up, ms, fails, since, last, err, hist:[[t, ms|-1]] }

  function save() {
    try { fs.mkdirSync(path.dirname(FILE), { recursive: true }); fs.writeFileSync(FILE, JSON.stringify(list, null, 1)); }
    catch (e) { log('장비 목록 저장 실패: ' + e.message); }
  }
  function load() {
    try { const v = JSON.parse(fs.readFileSync(FILE, 'utf8')); if (Array.isArray(v)) list = v.map((d) => norm(d)).filter(Boolean); }
    catch (e) { if (e.code !== 'ENOENT') log('장비 목록 읽기 실패: ' + e.message); }
  }
  function norm(d, base) {
    if (!d || typeof d !== 'object') return null;
    const o = base ? { ...base } : { id: crypto.randomBytes(5).toString('hex') };
    if (d.name != null) o.name = str(d.name, 40);
    if (d.host != null) { const h = str(d.host, 100); if (!isHost(h)) throw new Error('주소를 확인해 주세요 (예: 192.168.0.1)'); o.host = h; }
    if (d.mode != null) o.mode = d.mode === 'tcp' ? 'tcp' : 'ping';
    if (d.port != null) o.port = Math.max(0, Math.min(65535, Math.round(Number(d.port) || 0)));
    if (d.kind != null) o.kind = KINDS.includes(d.kind) ? d.kind : 'etc';
    if (d.alert != null) o.alert = d.alert !== false;
    if (d.memo != null) o.memo = str(d.memo, 200);
    if (d.id && !base) o.id = str(d.id, 20);
    if (!o.host) return null;
    if (!o.name) o.name = o.host;
    if (!o.mode) o.mode = 'ping';
    if (o.mode === 'tcp' && !o.port) throw new Error('포트 번호를 적어 주세요 (예: 80, 443, 3389)');
    if (!o.kind) o.kind = 'etc';
    if (o.alert === undefined) o.alert = true;
    return o;
  }
  load();

  async function checkOne(d) {
    const once = () => (d.mode === 'tcp' ? tcpOnce(d.host, d.port, 2000) : pingOnce(d.host, 1500));
    let r = await once();
    if (!r.ok) r = await once();                       // 한 번 더 (순간 손실은 넘긴다)
    const now = Date.now();
    let s = st.get(d.id);
    if (!s) { s = { up: null, ms: null, fails: 0, since: now, last: 0, err: '', hist: [] }; st.set(d.id, s); }
    s.last = now; s.ms = r.ms; s.err = r.err;
    s.fails = r.ok ? 0 : s.fails + 1;
    const up = r.ok ? true : (s.fails >= DOWN_AFTER ? false : (s.up === null ? null : s.up));
    if (up !== s.up && up !== null) { if (s.up !== null) log(`[장비] ${d.name} (${d.host}) ${up ? '응답 복구' : '응답 없음'}`); s.since = now; }
    s.up = up;
    s.hist.push([now, r.ok ? r.ms : -1]); if (s.hist.length > HIST) s.hist.splice(0, s.hist.length - HIST);
  }
  let running = false;
  async function checkAll() {
    if (running) return; running = true;
    try {
      const q = list.slice();
      const worker = async () => { while (q.length) { const d = q.shift(); try { await checkOne(d); } catch (e) { log('[장비] 확인 오류: ' + e.message); } } };
      await Promise.all(Array.from({ length: Math.min(16, q.length) }, worker));
    } finally { running = false; }
  }
  function view(d) {
    const s = st.get(d.id) || {};
    const h = s.hist || [], day = h.length ? h.filter((x) => x[1] >= 0).length / h.length : null;
    // 화면용 최근 1시간 (2분 단위 30칸: 응답 비율)
    const now = Date.now(), bins = [];
    for (let i = 29; i >= 0; i--) {
      const a = now - (i + 1) * 120000, b = now - i * 120000;
      const seg = h.filter((x) => x[0] > a && x[0] <= b);
      bins.push(seg.length ? Math.round(seg.filter((x) => x[1] >= 0).length / seg.length * 100) : null);
    }
    return { ...d, up: s.up === undefined ? null : s.up, ms: s.ms, err: s.err || '', since: s.since || null, last: s.last || null, fails: s.fails || 0, avail: day == null ? null : Math.round(day * 1000) / 10, bins };
  }

  return {
    KINDS,
    list() { return list.map(view); },
    get(id) { const d = list.find((x) => x.id === id); return d ? view(d) : null; },
    upsert(raw) {
      const i = list.findIndex((x) => x.id === raw.id);
      if (i < 0 && list.length >= MAX_DEV) throw new Error('장비는 200개까지 등록할 수 있습니다');
      const d = norm(raw, i >= 0 ? list[i] : null);
      if (!d) throw new Error('주소를 적어 주세요');
      if (i >= 0) { if (list[i].host !== d.host || list[i].mode !== d.mode || list[i].port !== d.port) st.delete(d.id); list[i] = d; }
      else list.push(d);
      save();
      checkOne(d).catch(() => {});                       // 저장하자마자 한 번 확인
      return view(d);
    },
    remove(id) { list = list.filter((x) => x.id !== id); st.delete(id); save(); },
    checkAll,
    checkNow(id) { const d = list.find((x) => x.id === id); return d ? checkOne(d).then(() => view(d)) : Promise.resolve(null); },
  };
}

module.exports = { create, KINDS, pingOnce, tcpOnce };
