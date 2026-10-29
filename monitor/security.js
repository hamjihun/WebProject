// 보안 감시 — 에이전트(security.ps1·파일 감시)가 보낸 보안 이벤트를 서버별로 모아 두고, 처음 보는 이벤트만 알림으로 넘긴다.
// data/security.json = { 호스트: { ts, status:{audit,logs,canary,bitlocker,vss,defender,rdp_known,fs}, events:[{id,t,sev,kind,msg,ack,ackBy,ackAt}] } }
// 에이전트는 최근 3일치 이벤트(최대 60개)를 매번 함께 보내므로 id 로 겹치는 것을 거른다.
const fs = require('fs');
const path = require('path');

const SEV = ['crit', 'warn', 'info'];
const KEEP_DAYS = 90, KEEP_N = 400;
const str = (v, n) => String(v == null ? '' : v).slice(0, n);

function create({ file, log = console.log }) {
  let db = {};
  try { const v = JSON.parse(fs.readFileSync(file, 'utf8')); if (v && typeof v === 'object') db = v; }
  catch (e) { if (e.code !== 'ENOENT') log('보안 기록 읽기 실패: ' + e.message); }
  let timer = null;
  function save() {
    if (timer) return;
    timer = setTimeout(() => {
      timer = null;
      try { fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file + '.tmp', JSON.stringify(db)); fs.renameSync(file + '.tmp', file); }
      catch (e) { log('보안 기록 저장 실패: ' + e.message); }
    }, 2000);
  }

  function normEvent(e) {
    if (!e || typeof e !== 'object' || !e.id) return null;
    const t = Date.parse(e.t) || Date.now();
    return { id: str(e.id, 160), t, sev: SEV.includes(e.sev) ? e.sev : 'info', kind: str(e.kind, 20), msg: str(e.msg, 500) };
  }
  function normStatus(s, fsw) {
    if (!s || typeof s !== 'object') s = {};
    const c = s.canary && typeof s.canary === 'object' ? s.canary : null;
    const b = s.bitlocker && typeof s.bitlocker === 'object' ? s.bitlocker : null;
    const d = s.defender && typeof s.defender === 'object' ? s.defender : null;
    return {
      audit: s.audit === true ? true : s.audit === false ? false : null,
      logs: s.logs !== false,
      canary: c ? { dirs: (Array.isArray(c.dirs) ? c.dirs : []).slice(0, 20).map((x) => str(x, 200)), files: Number(c.files) || 0, ok: c.ok !== false } : null,
      bitlocker: b ? { avail: !!b.avail, vols: (Array.isArray(b.vols) ? b.vols : []).slice(0, 26).map((v) => ({ m: str(v.m, 4), conv: Number(v.conv), pct: Number(v.pct) || 0, prot: Number(v.prot) || 0, keys: Number(v.keys) || 0 })) } : null,
      vss: s.vss == null ? null : Number(s.vss),
      defender: d ? { on: !!d.on, rt: !!d.rt, sig: Number(d.sig) } : null,
      rdp_known: Number(s.rdp_known) || 0,
      fs: fsw && typeof fsw === 'object' && Array.isArray(fsw.roots) ? { roots: fsw.roots.slice(0, 20).map((x) => str(x, 200)) } : null,
    };
  }

  // 에이전트가 보낸 security 를 반영하고, 새로 본 이벤트를 돌려준다
  function ingest(host, raw) {
    if (!raw || typeof raw !== 'object') return [];
    const h = db[host] || (db[host] = { ts: 0, status: null, events: [] });
    h.ts = Date.now();
    if (raw.status || raw.fs) h.status = normStatus(raw.status, raw.fs);
    const have = new Set(h.events.map((e) => e.id));
    const oldest = h.events.length >= KEEP_N ? h.events[h.events.length - 1].t : 0;
    const fresh = [];
    for (const r of (Array.isArray(raw.events) ? raw.events : []).slice(0, 80)) {
      const e = normEvent(r);
      if (!e || have.has(e.id) || e.t <= oldest) continue;
      have.add(e.id); h.events.push(e); fresh.push(e);
    }
    if (fresh.length) {
      const cut = Date.now() - KEEP_DAYS * 86400000;
      h.events = h.events.filter((e) => e.t > cut).sort((a, b) => b.t - a.t).slice(0, KEEP_N);
      save();
    }
    return fresh;
  }

  function summary(host) {
    const h = db[host]; if (!h) return null;
    let crit = 0, warn = 0;
    for (const e of h.events) if (!e.ack) { if (e.sev === 'crit') crit++; else if (e.sev === 'warn') warn++; }
    const top = h.events.find((e) => !e.ack && e.sev === 'crit') || h.events.find((e) => !e.ack && e.sev === 'warn') || null;
    return { level: crit ? 'crit' : warn ? 'warn' : 'ok', crit, warn, ts: h.ts, top: top ? { t: top.t, sev: top.sev, msg: top.msg } : null, status: h.status };
  }
  function events(host, n = 100) { const h = db[host]; return h ? h.events.slice(0, n) : []; }
  function ack(host, ids, by) {             // ids: 배열 또는 'all'
    const h = db[host]; if (!h) return 0;
    let n = 0; const want = ids === 'all' ? null : new Set((Array.isArray(ids) ? ids : [ids]).map(String));
    for (const e of h.events) if (!e.ack && (!want || want.has(e.id))) { e.ack = true; e.ackBy = str(by, 40); e.ackAt = Date.now(); n++; }
    if (n) save();
    return n;
  }
  function forget(host) { if (db[host]) { delete db[host]; save(); } }
  return { ingest, summary, events, ack, forget, hosts: () => Object.keys(db) };
}

module.exports = { create };
