'use strict';
// 서버 모니터링 수집기 (내 PC에서 실행)
// - 에이전트가 POST /api/metrics 로 보내는 JSON을 메모리에 쌓고
// - GET / 에서 대시보드 화면을 보여줍니다.
// 외부 패키지 없이 Node.js 내장 모듈만 사용합니다.

const VERSION = '1.30.4';
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
const alerter = require('./alerts').create({ settingsFile: SETTINGS_FILE, log: console.log });
const USERS_FILE = process.env.USERS_FILE || path.join(__dirname, 'data', 'users.json');            // 로그인 계정·권한
const auth = require('./auth').create({ file: USERS_FILE, log: console.log });
const SCHEDULE_FILE = process.env.SCHEDULE_FILE || path.join(__dirname, 'data', 'schedule.json');   // 일정 관리
const sched = require('./schedule').create({ file: SCHEDULE_FILE, log: console.log });
const MEMO_FILE = process.env.MEMO_FILE || path.join(__dirname, 'data', 'memo.json');             // 메모 보드 (사람별)
const memo = require('./memo').create({ file: MEMO_FILE, log: console.log });     // 디스크 일별 스냅샷 보관 일수 (전일/주/월 증가량 계산용)

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

// ---- 통계 (기간별 집계) ----
// gran: 'hour' | 'day'. 서버별로 { series:[{t,ca,cx,ma,mx,off,sec}], cpu_avg, cpu_max, mem_avg, mem_max, off_sec, tracked_sec, uptime, disks:[{mount,total,used,start,delta,pct}] }
function statsView(from, to, gran) {
  const now = Date.now();
  const hosts = {};
  const fromKey = dayKey(from), toKey = dayKey(to);
  for (const [host, e] of store) {
    const rows = hourlyView(host, 400).filter((r) => r.h >= from && r.h <= to);
    const buckets = new Map();
    let cs = 0, cn = 0, cx = 0, ms = 0, mn = 0, mx = 0, off = 0, tracked = 0;
    for (const r of rows) {
      const sec = r.open ? Math.max(0, Math.min(3600, (now - r.h) / 1000)) : 3600;
      const o = Math.min(sec, r.off || 0);
      off += o; tracked += sec;
      if (r.ca != null) { cs += r.ca * r.n; cn += r.n; cx = Math.max(cx, r.cx || 0); }
      if (r.ma != null) { ms += r.ma * r.n; mn += r.n; mx = Math.max(mx, r.mx || 0); }
      const key = gran === 'hour' ? r.h : new Date(new Date(r.h).setHours(0, 0, 0, 0)).getTime();
      const b = buckets.get(key) || { t: key, cs: 0, cn: 0, cx: 0, ms: 0, mn: 0, mx: 0, off: 0, sec: 0 };
      b.sec += sec; b.off += o;
      if (r.ca != null) { b.cs += r.ca * r.n; b.cn += r.n; b.cx = Math.max(b.cx, r.cx || 0); }
      if (r.ma != null) { b.ms += r.ma * r.n; b.mn += r.n; b.mx = Math.max(b.mx, r.mx || 0); }
      buckets.set(key, b);
    }
    const series = [...buckets.values()].sort((a, b) => a.t - b.t).map((b) => ({ t: b.t, ca: b.cn ? Math.round(b.cs / b.cn * 10) / 10 : null, cx: b.cn ? b.cx : null, ma: b.mn ? Math.round(b.ms / b.mn * 10) / 10 : null, mx: b.mn ? b.mx : null, off: Math.round(b.off), sec: Math.round(b.sec) }));
    // 디스크: 기간 시작 시점 스냅샷 vs 최신
    const daily = e.daily || {}; const keys = Object.keys(daily).sort();
    let startKey = null; for (const k of keys) { if (k <= fromKey) startKey = k; else break; }
    if (!startKey) startKey = keys.find((k) => k >= fromKey && k <= toKey) || null;
    let endKey = null; for (const k of keys) if (k <= toKey) endKey = k;
    const disks = [];
    const cur = e.latest && e.latest.disks ? e.latest.disks : [];
    const endSnap = endKey ? daily[endKey].disks : {};
    const startSnap = startKey ? daily[startKey].disks : {};
    for (const d of cur) {
      const en = endSnap[d.mount] || d, st = startSnap[d.mount];
      disks.push({ mount: d.mount, total: d.total, used: en.used, pct: d.total ? Math.round(en.used / d.total * 1000) / 10 : null, start: st ? st.used : null, delta: st ? en.used - st.used : null, start_date: st ? startKey : null, end_date: endKey });
    }
    const diskSeries = keys.filter((k) => k >= (startKey || fromKey) && k <= toKey).map((k) => ({ date: k, disks: daily[k].disks }));
    hosts[host] = {
      host, name: e.latest ? e.latest.name || '' : '', os: e.latest ? e.latest.os || '' : '', online: e.latest ? now - e.latest.ts < OFFLINE_AFTER : false,
      cpu_avg: cn ? Math.round(cs / cn * 10) / 10 : null, cpu_max: cn ? cx : null, mem_avg: mn ? Math.round(ms / mn * 10) / 10 : null, mem_max: mn ? mx : null,
      off_sec: Math.round(off), tracked_sec: Math.round(tracked), uptime: tracked ? Math.round((1 - off / tracked) * 10000) / 100 : null,
      series, disks, disk_series: diskSeries,
    };
  }
  return hosts;
}
function parseRange(url) {
  const now = Date.now();
  let from, to = now;
  const days = Number(url.searchParams.get('days') || 0);
  const month = url.searchParams.get('month') || '';
  if (/^\d{4}-\d{2}$/.test(month)) { const [y, m] = month.split('-').map(Number); from = new Date(y, m - 1, 1).getTime(); to = Math.min(now, new Date(y, m, 1).getTime() - 1); }
  else if (url.searchParams.get('from')) { from = new Date(url.searchParams.get('from')).getTime(); if (url.searchParams.get('to')) to = Math.min(now, new Date(url.searchParams.get('to')).setHours(23, 59, 59, 999)); }
  else { const d = new Date(now); d.setHours(0, 0, 0, 0); d.setDate(d.getDate() - Math.max(0, Math.min(400, days || 7) - 1)); from = d.getTime(); }
  if (!(from > 0)) { const d = new Date(now); d.setHours(0, 0, 0, 0); d.setDate(d.getDate() - 6); from = d.getTime(); }
  const gran = url.searchParams.get('gran') || (to - from <= 8 * 86400000 ? 'hour' : 'day');
  return { from, to, gran };
}
function csvEscape(v) { const s = v == null ? '' : String(v); return /[",\r\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s; }
function reportCsv(from, to, gran) {
  const hosts = statsView(from, to, gran), ev = alerter.countEvents(from, to);
  const fmtD = (t) => { const d = new Date(t); const p = (n) => String(n).padStart(2, '0'); return gran === 'hour' ? `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:00` : `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`; };
  const gb = (b) => b == null ? '' : (b / 1024 ** 3).toFixed(1);
  const lines = [];
  lines.push(['서버 모니터 리포트', `기간 ${fmtD(from)} ~ ${fmtD(to)}`, `생성 ${new Date().toLocaleString('ko-KR')}`]);
  lines.push([]);
  lines.push(['[서버별 요약]']);
  lines.push(['서버', '호스트명', 'OS', 'CPU 평균(%)', 'CPU 최대(%)', '메모리 평균(%)', '메모리 최대(%)', '가동률(%)', '오프라인(시간)', '경고 건수', 'CPU 경고', '메모리 경고', '디스크 경고', '오프라인 경고', '백업 경고']);
  const list = Object.values(hosts).sort((a, b) => (order.indexOf(a.host) + 1 || 1e9) - (order.indexOf(b.host) + 1 || 1e9) || a.host.localeCompare(b.host));
  for (const h of list) { const a = ev.byHost[h.host] || {}; lines.push([h.name || h.host, h.host, h.os, h.cpu_avg, h.cpu_max, h.mem_avg, h.mem_max, h.uptime, (h.off_sec / 3600).toFixed(1), a.total || 0, a.cpu || 0, a.mem || 0, (a.disk || 0) + (a.full || 0), a.offline || 0, a.backup || 0]); }
  lines.push([]);
  lines.push(['[디스크 증감]']);
  lines.push(['서버', '드라이브', '전체(GB)', '기간 시작 사용(GB)', '현재 사용(GB)', '증감(GB)', '사용률(%)', '기준일']);
  for (const h of list) for (const d of h.disks) lines.push([h.name || h.host, d.mount, gb(d.total), gb(d.start), gb(d.used), gb(d.delta), d.pct, d.start_date || '']);
  lines.push([]);
  lines.push([gran === 'hour' ? '[시간별 추이]' : '[일별 추이]']);
  lines.push(['서버', gran === 'hour' ? '일시' : '날짜', 'CPU 평균(%)', 'CPU 최대(%)', '메모리 평균(%)', '메모리 최대(%)', '오프라인(분)']);
  for (const h of list) for (const r of h.series) lines.push([h.name || h.host, fmtD(r.t), r.ca, r.cx, r.ma, r.mx, Math.round(r.off / 60)]);
  lines.push([]);
  lines.push(['[경고 이력]']);
  lines.push(['일시', '서버', '구분', '내용']);
  const RULE = { cpu: 'CPU', mem: '메모리', disk: '디스크', full: '디스크 소진', offline: '오프라인', backup: '백업', etc: '기타' };
  for (const e of ev.events) lines.push([new Date(e.time).toLocaleString('ko-KR'), e.name || e.host, RULE[e.rule] || e.rule, e.msg]);
  return '﻿' + lines.map((l) => l.map(csvEscape).join(',')).join('\r\n') + '\r\n';
}

let topology = { nodes: {}, links: [], groups: [], notes: [] };   // 구성도 (화면에서 편집)
let order = [];   // 화면 카드 순서 (호스트명 배열). 화면에서 드래그하면 갱신됨
let backupDays = {};   // 일자별 백업 이력 { host: { 'YYYY-MM-DD': { sql:{...}, usb:{...}, veeam:{ 작업명:{...} } } } } — 에이전트가 보낸 최신 상태에서 날짜별로 누적
const BACKUP_DAYS_KEEP = 400;
// 에이전트가 보낸 backups 를 날짜별 이력에 반영 (같은 날짜는 최신 값으로 덮어씀)
function recordBackupDays(host, b) {
  if (!b) return;
  const H = backupDays[host] = backupDays[host] || {};
  const day = (t) => { if (!t) return null; const d = new Date(t); return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`; };
  const get = (k) => (H[k] = H[k] || {});
  if (Array.isArray(b.files) && b.files.length) {
    const f = b.files.reduce((a, x) => (x.newest_time || 0) > (a.newest_time || 0) ? x : a, b.files[0]);
    const k = day(f.newest_time); if (k) get(k).sql = { time: f.newest_time, file: f.newest_file, size: f.newest_size, count: f.count, total: f.size, path: f.path };
  }
  if (b.sql && Array.isArray(b.sql.dbs)) for (const d of b.sql.dbs) { const k = day(d.full); if (k) { const s = get(k); s.dbs = s.dbs || {}; s.dbs[d.db] = { time: d.full, size: d.size }; } }
  if (Array.isArray(b.usbs)) for (const u of b.usbs) { const t = Math.max(u.copied_time || 0, u.done_time || 0) || u.newest_time; const k = day(t); if (k) { const s = get(k); s.usbs = s.usbs || {}; s.usbs[u.name || ''] = { time: t, count: u.count, free: u.free, total: u.total, ok: u.done_ok, code: u.done_code, drive: u.drive, path: u.path, file: u.newest_file }; } }
  if (Array.isArray(b.jobs)) for (const j of b.jobs) { const k = day(j.end || j.start); if (k && j.result && j.result !== 'None') { const s = get(k); s.veeam = s.veeam || {}; s.veeam[j.name] = { result: j.result, end: j.end, size: j.size, duration: j.duration, type: j.type }; } }
  const keys = Object.keys(H); if (keys.length > BACKUP_DAYS_KEEP) { keys.sort(); for (const k of keys.slice(0, keys.length - BACKUP_DAYS_KEEP)) delete H[k]; }
}

// ---- 스냅샷 저장/복원 (재시작해도 이력 유지) ----
function loadState() {
  if (!STATE_FILE) return;
  try {
    const obj = JSON.parse(fs.readFileSync(STATE_FILE, 'utf8'));
    const hosts = obj.hosts || obj;                       // 구버전 파일은 호스트 맵 그대로
    if (Array.isArray(obj.order)) order = obj.order.filter((h) => typeof h === 'string');
    if (obj.topology && typeof obj.topology === 'object') topology = { nodes: {}, links: [], groups: [], notes: [], ...obj.topology };
    if (obj.backupDays && typeof obj.backupDays === 'object') backupDays = obj.backupDays;
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
  const obj = { hosts, order, topology, backupDays, alerts: alerter.exportState() };
  const tmp = STATE_FILE + '.tmp';
  try {
    fs.mkdirSync(path.dirname(STATE_FILE), { recursive: true });
    if (sync) { fs.writeFileSync(tmp, JSON.stringify(obj)); fs.renameSync(tmp, STATE_FILE); return; }
    fs.writeFile(tmp, JSON.stringify(obj), (err) => { if (!err) fs.rename(tmp, STATE_FILE, () => {}); });
  } catch (e) { console.warn('스냅샷 저장 실패:', e.message); }
}

function readBody(req, maxMB = 1) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (c) => {
      size += c.length;
      if (size > maxMB * 1024 * 1024) { reject(new Error('보낸 내용이 너무 큽니다')); req.destroy(); return; }
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
// 온습도 센서 값 (에이전트 1.7.0+ 가 보냄). 말이 안 되는 값은 버린다.
function normalizeEnv(e) {
  if (!e || typeof e !== 'object') return undefined;
  const t = Number(e.t), h = Number(e.h);
  if (!Number.isFinite(t) || !Number.isFinite(h)) return undefined;
  if (t < -50 || t > 100 || h < 0 || h > 100) return undefined;
  return { t: Math.round(t * 10) / 10, h: Math.round(h * 10) / 10 };
}
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
    backups: normalizeBackups(raw.backups),               // Veeam 백업 서버만 보냄 (없으면 undefined → JSON 에서 빠짐)
    env: normalizeEnv(raw.env),                           // 서버실 온습도 (센서 꽂힌 서버만)
    agent: raw.agent && typeof raw.agent === 'object' ? { version: String(raw.agent.version || '').slice(0, 20), veeam: !!raw.agent.veeam, backup: !!raw.agent.backup, env: !!raw.agent.env, paths: (Array.isArray(raw.agent.paths) ? raw.agent.paths : []).slice(0, 10).map((p) => String(p).slice(0, 200)) } : undefined,   // 에이전트 자기 정보 (1.5.4+)
  };
}
// Veeam 에이전트가 보낸 백업 작업/저장소 상태
function normalizeBackups(b) {
  if (!b || typeof b !== 'object') return undefined;   // 백업 정보 없는 서버 (이 검사가 먼저여야 함 — 1.14.0 에서 순서가 바뀌어 전 서버가 오프라인으로 뜬 적 있음)
  const usbList = Array.isArray(b.usbs) && b.usbs.length ? b.usbs.filter((u) => u && typeof u === 'object') : (b.usb && typeof b.usb === 'object' ? [b.usb] : []);
  const t = (v) => { const x = Date.parse(v); return isNaN(x) ? null : x; };
  return {
    time: t(b.time) || Date.now(), error: b.error ? String(b.error).slice(0, 200) : '', diag: b.diag ? String(b.diag).slice(0, 400) : '',
    jobs: (Array.isArray(b.jobs) ? b.jobs : []).slice(0, 100).map((j) => ({
      name: String(j.name || '').slice(0, 80), type: String(j.type || ''), enabled: j.enabled !== false, result: String(j.result || 'None'), state: String(j.state || ''),
      progress: j.progress == null ? null : num(j.progress), start: t(j.start), end: t(j.end), ok_end: t(j.ok_end), duration: num(j.duration), size: num(j.size), next: t(j.next),
    })),
    repos: (Array.isArray(b.repos) ? b.repos : []).slice(0, 50).map((r) => ({ name: String(r.name || '').slice(0, 80), total: num(r.total), free: num(r.free), pct: num(r.total) ? Math.round((num(r.total) - num(r.free)) / num(r.total) * 1000) / 10 : null })),
    // 1차: SQL 백업 폴더(.bak 최신 파일) + msdb 기록, 3차: USB 복사
    files: Array.isArray(b.files) ? b.files.slice(0, 10).map((f) => ({ path: String(f.path || ''), exists: f.exists !== false, newest_file: f.newest_file ? String(f.newest_file).slice(0, 200) : null, newest_time: t(f.newest_time), newest_size: num(f.newest_size), count: num(f.count), size: num(f.size), error: f.error ? String(f.error).slice(0, 200) : '' })) : undefined,
    sql: b.sql && typeof b.sql === 'object' ? { instance: String(b.sql.instance || ''), error: b.sql.error ? String(b.sql.error).slice(0, 200) : '', dbs: (Array.isArray(b.sql.dbs) ? b.sql.dbs : []).slice(0, 200).map((d) => ({ db: String(d.db || ''), full: t(d.full), diff: t(d.diff), log: t(d.log), size: num(d.size), path: String(d.path || '').slice(0, 260), recovery: String(d.recovery || '') })) } : undefined,
    usbs: usbList.length ? usbList.slice(0, 10).map((u) => ({ name: String(u.name || '').slice(0, 60), spec: u.spec ? String(u.spec).slice(0, 200) : '', connected: !!u.connected, drive: String(u.drive || ''), label: String(u.label || ''), path: String(u.path || ''), newest_file: u.newest_file ? String(u.newest_file).slice(0, 200) : null, newest_time: t(u.newest_time), copied_time: t(u.copied_time), copied_file: u.copied_file ? String(u.copied_file).slice(0, 200) : null, count: u.count == null ? null : num(u.count), size: num(u.size), free: num(u.free), total: num(u.total), light: !!u.light, last_seen: t(u.last_seen), done_time: t(u.done_time), done_code: u.done_code == null ? null : num(u.done_code), done_ok: u.done_ok == null ? null : !!u.done_ok, error: u.error ? String(u.error).slice(0, 200) : '', note: u.note ? String(u.note).slice(0, 200) : '' })) : undefined,   // 3차 USB (여러 개 가능; 구버전 에이전트의 usb 하나짜리도 목록으로)
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
  if (m.backups) recordBackupDays(m.host, visibleBackups(m.backups));
  recordHourly(m); hourlyDirty = true;
  entry.history.push(m.env
    ? { ts: m.ts, cpu: m.cpu, mem_pct: m.mem_pct, net_rx: m.net_rx, net_tx: m.net_tx, t: m.env.t, h: m.env.h }
    : { ts: m.ts, cpu: m.cpu, mem_pct: m.mem_pct, net_rx: m.net_rx, net_tx: m.net_tx });
  if (entry.history.length > HISTORY) entry.history.splice(0, entry.history.length - HISTORY);
  dirty = true;
  if (LOG_FILE) fs.appendFile(LOG_FILE, JSON.stringify(m) + '\n', () => {});
  return m;
}

// 알림 설정의 backup_hide 에 적힌 Veeam 작업은 화면과 판단에서 뺀다
// 화면·알림에서 뺄 이름 (rules.backup_hide) — Veeam 작업 이름과 SQL DB 이름 모두에 적용
function visibleBackups(b) {
  if (!b) return b;
  const hide = String(alerter.getSettings().rules.backup_hide || '').split(',').map((x) => x.trim().toLowerCase()).filter(Boolean);
  if (!hide.length) return b;
  const out = { ...b };
  if (Array.isArray(b.jobs)) out.jobs = b.jobs.filter((j) => !hide.includes(String(j.name || '').toLowerCase()));
  if (b.sql && Array.isArray(b.sql.dbs)) out.sql = { ...b.sql, dbs: b.sql.dbs.filter((d) => !hide.includes(String(d.db || '').toLowerCase())) };
  return out;
}
function serversView() {
  const now = Date.now();
  const list = [];
  for (const [host, e] of store) {
    list.push({ ...e.latest, backups: visibleBackups(e.latest.backups), online: now - e.latest.ts < OFFLINE_AFTER, age: Math.round((now - e.latest.ts) / 1000), growth: diskGrowth(e), days_tracked: Object.keys(e.daily || {}).length, muted: alerter.isMuted(host), host_rules: alerter.getHostRules(host), host_conf: alerter.getHostConf(host) });
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
  order = order.filter((h) => h !== host); delete backupDays[host];
  alerter.forget(host);
  if (existed) dirty = true;
  return existed;
}

// 오늘과 이번 주(오늘부터 7일) 할 일 + 기한이 지난 미완료 일정
function todoView(me, list) {
  const dayKeyOf = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
  const now = new Date(); now.setHours(0, 0, 0, 0);
  const today = dayKeyOf(now);
  const end = new Date(now); end.setDate(end.getDate() + 6);
  const hol = sched.holidays();
  const item = (o) => ({
    id: o.ev.id, title: o.ev.title, time: o.ev.time || '', dept: o.ev.dept || '', owner: o.ev.owner || '',
    status: o.status, prio: o.ev.prio || '보통', share: o.ev.share || 'team', date: o.date, end: o.end,
    desc: o.ev.desc || '', repeat: (o.ev.repeat && o.ev.repeat.kind) || 'none',
    notes: (o.ev.notes || []).filter((n) => ((o.ev.repeat && o.ev.repeat.kind) || 'none') === 'none' || n.date === o.date)
      .sort((a, b) => b.at - a.at).slice(0, 5).map((n) => ({ text: n.text, by: n.by, at: n.at })),
  });
  const days = [];
  for (let i = 0; i < 7; i++) {
    const d = new Date(now); d.setDate(d.getDate() + i);
    const k = dayKeyOf(d);
    days.push({ date: k, holiday: hol[k] || '', items: [] });
  }
  for (const o of sched.occurrences(list, today, dayKeyOf(end))) {
    for (const day of days) if (day.date >= o.date && day.date <= o.end) day.items.push(item(o));
  }
  // 기한이 지났는데 아직 안 끝난 일 (지난 60일)
  const past = new Date(now); past.setDate(past.getDate() - 60);
  const late = sched.occurrences(list, dayKeyOf(past), today).filter((o) => o.end < today && o.status !== '완료').map(item).reverse().slice(0, 20);
  return { ok: true, today, days, late, me: me.name || me.id };
}

// 이 시스템 자체(data 폴더) 백업 결과 — deploy/backup-status.ps1 이 남긴 파일을 읽는다
const SELF_BACKUP_FILE = path.join(__dirname, 'data', 'backup-status.json');
let selfBkCache = { at: 0, val: null };
function selfBackup() {
  if (Date.now() - selfBkCache.at < 30000) return selfBkCache.val;
  let val = null;
  try {
    const o = JSON.parse(fs.readFileSync(SELF_BACKUP_FILE, 'utf8'));
    const t = (v) => { const x = Date.parse(v); return isNaN(x) ? null : x; };
    val = {
      time: t(o.time),
      targets: (Array.isArray(o.targets) ? o.targets : []).slice(0, 10).map((x) => ({
        path: String(x.path || '').slice(0, 300), reachable: !!x.reachable,
        last_date: x.last_date ? String(x.last_date).slice(0, 10) : null, last_time: t(x.last_time),
        files: num(x.files), size: num(x.size), keep: num(x.keep), full_time: t(x.full_time),
        message: String(x.message || '').slice(0, 300),
      })),
    };
  } catch (e) { val = null; }
  selfBkCache = { at: Date.now(), val };
  return val;
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

  // ---- 로그인 확인 ----
  // 에이전트가 쓰는 주소(/api/metrics, /api/unregister)는 토큰으로만 확인하므로 로그인과 무관하다.
  const AGENT_PATHS = url.pathname === '/api/metrics' || url.pathname === '/api/unregister';
  const me = AGENT_PATHS ? null : auth.fromCookie(req.headers.cookie);

  if (req.method === 'POST' && url.pathname === '/api/login') {
    try {
      const raw = JSON.parse((await readBody(req)) || '{}');
      const r = auth.login(raw.id, raw.pw, !!raw.keep);
      if (!r) { console.log(`[${new Date().toLocaleTimeString()}] 로그인 실패: ${String(raw.id || '').slice(0, 20)} (${remoteIp})`); return json(res, 401, { ok: false, error: '아이디 또는 비밀번호가 맞지 않습니다' }); }
      console.log(`[${new Date().toLocaleTimeString()}] 로그인: ${r.user.id} (${remoteIp})`);
      const cookie = `ims_sess=${r.sid}; Path=/; HttpOnly; SameSite=Lax` + (r.keep ? `; Max-Age=${30 * 86400}` : '');
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8', 'Set-Cookie': cookie, 'Cache-Control': 'no-store' });
      return res.end(JSON.stringify({ ok: true, user: r.user, apps: auth.appsFor(auth.fromCookie(`ims_sess=${r.sid}`)) }));
    } catch (e) { return json(res, 400, { ok: false, error: String(e.message || e) }); }
  }
  if (req.method === 'POST' && url.pathname === '/api/logout') {
    auth.logout(req.headers.cookie);
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8', 'Set-Cookie': 'ims_sess=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0' });
    return res.end(JSON.stringify({ ok: true }));
  }
  if (req.method === 'GET' && url.pathname === '/api/me') {
    if (!me) return json(res, 401, { ok: false, error: 'login' });
    return json(res, 200, { ok: true, user: auth.pub(me), apps: auth.appsFor(me), version: VERSION });
  }

  // 비밀번호를 바꿔야 하는 계정은 비밀번호 화면 말고는 열리지 않는다
  if (me && me.must_change) {
    const pwOk = url.pathname === '/password.html' || url.pathname === '/api/password' || url.pathname === '/api/me' || url.pathname === '/api/logout';
    if (!pwOk) {
      if (url.pathname.startsWith('/api/')) return json(res, 403, { ok: false, error: '비밀번호를 먼저 바꿔 주세요' });
      if (url.pathname === '/' || /\.html$/.test(url.pathname)) { res.writeHead(302, { Location: '/password.html' }); return res.end(); }
    }
  }

  if (req.method === 'POST' && url.pathname === '/api/password') {
    if (!me) return json(res, 401, { ok: false, error: 'login' });
    try {
      const raw = JSON.parse((await readBody(req)) || '{}');
      const u = auth.changePassword(me.id, raw.old, raw.new);
      console.log(`[${new Date().toLocaleTimeString()}] 비밀번호 변경: ${u.id}`);
      return json(res, 200, { ok: true, user: u });
    } catch (e) { return json(res, 400, { ok: false, error: String(e.message || e) }); }
  }

  if (!AGENT_PATHS && !me && url.pathname !== '/api/health') {
    const file = url.pathname === '/' ? 'home.html' : url.pathname.slice(1);
    if (url.pathname.startsWith('/api/')) return json(res, 401, { ok: false, error: 'login' });
    if (!auth.isOpenFile(file)) { res.writeHead(302, { Location: '/login.html?next=' + encodeURIComponent(req.url) }); return res.end(); }
  }
  if (me && /\.html$/.test(url.pathname) && !auth.can(me, url.pathname.slice(1))) {
    res.writeHead(302, { Location: '/home.html?denied=' + encodeURIComponent(url.pathname.slice(1)) }); return res.end();
  }

  // ---- 계정 관리 (관리자만) ----
  if (url.pathname === '/api/users') {
    if (!me || !me.admin) return json(res, 403, { ok: false, error: '관리자만 쓸 수 있습니다' });
    try {
      if (req.method === 'GET') return json(res, 200, { ok: true, users: auth.list(), pages: auth.APPS.map((a) => ({ key: a.key, name: a.name, pages: a.pages })), depts: sched.depts(), me: me.id });
      if (req.method === 'POST' || req.method === 'PUT') {
        const raw = JSON.parse((await readBody(req)) || '{}');
        const u = auth.upsert(raw, req.method === 'POST');
        console.log(`[${new Date().toLocaleTimeString()}] 계정 ${req.method === 'POST' ? '생성' : '수정'}: ${u.id}`);
        return json(res, 200, { ok: true, user: u, users: auth.list() });
      }
      if (req.method === 'DELETE') {
        const id = url.searchParams.get('id') || '';
        auth.remove(id, me.id);
        console.log(`[${new Date().toLocaleTimeString()}] 계정 삭제: ${id}`);
        return json(res, 200, { ok: true, users: auth.list() });
      }
    } catch (e) { return json(res, 400, { ok: false, error: String(e.message || e) }); }
  }

  // ---- 메모 보드 (사람마다 자기 보드) ----
  if (url.pathname === '/api/memo') {
    if (!me || !auth.can(me, 'memo.html')) return json(res, 403, { ok: false, error: '메모 화면 권한이 없습니다' });
    try {
      if (req.method === 'GET') { const g = memo.get(me.id); return json(res, 200, { ok: true, boards: g.boards, active: g.active, trash: g.trash, prefs: g.prefs, me: me.name || me.id }); }
      if (req.method === 'PUT') {
        const raw = JSON.parse((await readBody(req, 48)) || '{}');   // 사진이 들어가므로 넉넉히
        const g = memo.set(me.id, raw);
        return json(res, 200, { ok: true, boards: g.boards, active: g.active, trash: g.trash, prefs: g.prefs });
      }
    } catch (e) { return json(res, 400, { ok: false, error: String(e.message || e) }); }
  }

  // ---- 일정 관리 ----
  if (url.pathname === '/api/schedule' || url.pathname === '/api/schedule/depts' || url.pathname === '/api/schedule/holidays' || url.pathname === '/api/schedule/todo') {
    if (!me || !auth.can(me, 'schedule.html')) return json(res, 403, { ok: false, error: '일정 화면 권한이 없습니다' });
    const who = me.name || me.id;
    const myDepts = auth.deptsOf(me);                                    // 빈 배열이면 전체 부서
    // 개인 일정(share:'me')은 만든 사람만 본다. 팀 공유(share:'team')는 그 부서를 볼 수 있는 사람이 본다.
    // (예전 버전에서 만든 일정은 share 값이 없으므로 팀 공유로 본다)
    const mine = (e) => e.owner_id ? e.owner_id === me.id : (e.created_by === (me.name || me.id));
    const canSee = (e) => ((e.share || 'team') !== 'me' ? auth.canDept(me, e.dept) : mine(e));
    const visible = () => sched.all().filter(canSee);
    const checkDept = (d) => { if (!auth.canDept(me, d)) throw new Error('그 부서의 일정은 다룰 수 없습니다'); };
    const checkOwn = (e) => { if (e && (e.share || 'team') === 'me' && !mine(e)) throw new Error('다른 사람의 개인 일정입니다'); };
    try {
      // 오늘 · 이번 주 할 일 (홈 화면 요약용). 메모도 같이 내려보낸다.
      if (req.method === 'GET' && url.pathname === '/api/schedule/todo') return json(res, 200, todoView(me, visible()));
      if (req.method === 'GET') return json(res, 200, {
        ok: true, events: visible(), depts: myDepts.length ? myDepts : sched.depts(), all_depts: sched.depts(),
        status: sched.STATUS, prios: sched.PRIOS, holidays: sched.holidays(), me: who, me_id: me.id, admin: !!me.admin, limited: myDepts.length > 0,
      });
      if (req.method === 'PUT' && url.pathname === '/api/schedule/depts') {
        if (!me.admin) return json(res, 403, { ok: false, error: '부서 목록은 관리자만 고칠 수 있습니다' });
        const raw = JSON.parse((await readBody(req)) || '{}');
        return json(res, 200, { ok: true, depts: sched.setDepts(raw.depts) });
      }
      if (req.method === 'PUT' && url.pathname === '/api/schedule/holidays') {
        if (!me.admin) return json(res, 403, { ok: false, error: '공휴일은 관리자만 고칠 수 있습니다' });
        const raw = JSON.parse((await readBody(req)) || '{}');
        return json(res, 200, { ok: true, holidays: sched.setHolidays(raw.holidays) });
      }
      if (req.method === 'POST') {
        const raw = JSON.parse((await readBody(req)) || '{}');
        if (myDepts.length && !raw.dept) raw.dept = myDepts[0];
        checkDept(raw.dept);
        const e = sched.create(raw, who, me.id);
        console.log(`[${new Date().toLocaleTimeString()}] 일정 등록: ${e.title} (${e.start}, ${who})`);
        return json(res, 200, { ok: true, event: e, events: visible() });
      }
      if (req.method === 'PUT') {
        const raw = JSON.parse((await readBody(req)) || '{}');
        const cur0 = sched.get(raw.id);
        if (cur0) { checkOwn(cur0); checkDept(cur0.dept); }
        if (raw.dept != null) checkDept(raw.dept);
        let e;
        if (raw.add_note) e = sched.addNote(raw.id, raw.add_note.date, raw.add_note.text, who).event;
        else if (raw.del_note) e = sched.delNote(raw.id, raw.del_note);
        else if (raw.occ_status) e = sched.setOccurrence(raw.id, raw.occ_status.date, raw.occ_status.status, who);
        else e = sched.update(raw, who);
        return json(res, 200, { ok: true, event: e, events: visible() });
      }
      if (req.method === 'DELETE') {
        const id = url.searchParams.get('id') || '', date = url.searchParams.get('date') || '';
        const cur1 = sched.get(id);
        if (cur1) { checkOwn(cur1); checkDept(cur1.dept); }
        if (date) sched.skip(id, date); else sched.remove(id);
        console.log(`[${new Date().toLocaleTimeString()}] 일정 ${date ? '한 날짜 제외' : '삭제'}: ${id} (${who})`);
        return json(res, 200, { ok: true, events: visible() });
      }
    } catch (e) { return json(res, 400, { ok: false, error: String(e.message || e) }); }
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
      return json(res, 200, { ok: true, agent: { usb_window: String(alerter.getSettings().rules.usb_window || ''), usb_paths: String(alerter.getHostConf(m.host).usb_paths || '') } });   // 에이전트로 내려보내는 설정 (USB 시간대, 이 서버의 USB 경로)
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
  // 서버별 에이전트 설정 (3차 USB 백업 경로 등) — 다음 전송 응답으로 에이전트에 내려간다
  if (req.method === 'PUT' && url.pathname === '/api/hostconf') {
    try {
      const raw = JSON.parse((await readBody(req)) || '{}');
      const host = String(raw.host || '').trim();
      if (!host || !store.has(host)) return json(res, 404, { ok: false, error: 'unknown host' });
      const conf = alerter.setHostConf(host, { usb_paths: raw.usb_paths });
      console.log(`[${new Date().toLocaleTimeString()}] 서버별 설정: ${host} ${JSON.stringify(conf)}`);
      return json(res, 200, { ok: true, host, conf });
    } catch (e) { return json(res, 400, { ok: false, error: String(e.message || e) }); }
  }
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
  // 통계: ?days=30 | ?month=2026-09 | ?from=2026-01-01&to=2026-03-31, gran=hour|day
  if (req.method === 'GET' && url.pathname === '/api/stats') {
    const { from, to, gran } = parseRange(url);
    return json(res, 200, { from, to, gran, hosts: statsView(from, to, gran), alerts: alerter.countEvents(from, to), order, months: alerter.listLogs() });
  }
  if (req.method === 'GET' && url.pathname === '/api/report.csv') {
    const { from, to, gran } = parseRange(url);
    const k = (t) => dayKey(t).replace(/-/g, '');
    res.writeHead(200, { 'Content-Type': 'text/csv; charset=utf-8', 'Content-Disposition': `attachment; filename="report-${k(from)}-${k(to)}.csv"`, 'Cache-Control': 'no-store' });
    return res.end(reportCsv(from, to, gran));
  }
  // 일자별 백업 이력: ?month=YYYY-MM (기본 이번 달) 또는 ?days=N
  if (req.method === 'GET' && url.pathname === '/api/backups') {
    const now = new Date(); let from, to;
    const mo = url.searchParams.get('month') || '';
    if (/^\d{4}-\d{2}$/.test(mo)) { const [y, m] = mo.split('-').map(Number); from = new Date(y, m - 1, 1); to = new Date(y, m, 0); }
    else { const n = Math.min(400, Math.max(1, Number(url.searchParams.get('days') || 31))); to = new Date(now.getFullYear(), now.getMonth(), now.getDate()); from = new Date(to); from.setDate(from.getDate() - n + 1); }
    const days = []; for (let d = new Date(from); d <= to; d.setDate(d.getDate() + 1)) days.push(dayKey(d.getTime()));
    const hosts = [], data = {};
    for (const s of serversView()) {
      if (!s.backups && !backupDays[s.host]) continue;
      const b = s.backups || {}; const H = backupDays[s.host] || {};
      const stages = []; if ((b.files && b.files.length) || Object.values(H).some((x) => x.sql)) stages.push('sql');
      if ((b.jobs && b.jobs.length) || Object.values(H).some((x) => x.veeam)) stages.push('veeam');
      const usbs = new Set((b.usbs || []).map((u) => u.name || '')); for (const k of days) { const e = H[k] || {}; if (e.usb) usbs.add(''); for (const n of Object.keys(e.usbs || {})) usbs.add(n); }
      if (usbs.size) stages.push('usb');
      const jobs = new Set((b.jobs || []).filter((j) => j.enabled !== false).map((j) => j.name)); for (const k of days) for (const jn of Object.keys((H[k] && H[k].veeam) || {})) jobs.add(jn);
      hosts.push({ host: s.host, name: s.name || '', online: s.online, stages, jobs: [...jobs], usbs: [...usbs], latest: b });
      data[s.host] = {}; for (const k of days) if (H[k]) data[s.host][k] = H[k];
    }
    const r = alerter.getSettings().rules;
    return json(res, 200, { from: days[0], to: days[days.length - 1], days, hosts, data, self: selfBackup(), today: dayKey(Date.now()), settings: { skip_weekend: r.backup_skip_weekend !== false, max_hours: r.backup_max_hours, usb_max_hours: r.usb_max_hours, check_time: r.backup_check_time } });
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

  if (req.method === 'GET' && url.pathname === '/api/servers') return json(res, 200, { now: Date.now(), version: VERSION, servers: serversView(), active_alerts: alerter.getActive(), self_backup: selfBackup() });
  if (req.method === 'GET' && url.pathname === '/api/health') return json(res, 200, { ok: true, version: VERSION, servers: store.size, uptime: Math.round(process.uptime()) });

  if (req.method === 'GET' && url.pathname === '/api/history') {
    const host = url.searchParams.get('host') || '';
    const e = store.get(host);
    if (!e) return json(res, 404, { ok: false, error: 'unknown host' });
    const daily = Object.keys(e.daily || {}).sort().map((k) => ({ date: k, disks: e.daily[k].disks }));
    return json(res, 200, { host, history: e.history, daily, growth: diskGrowth(e) });
  }

  if (req.method === 'GET' && (url.pathname === '/' || url.pathname === '/home.html')) return serveStatic(res, 'home.html');
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
