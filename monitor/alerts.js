'use strict';
// 알림 엔진: 임계치 감지 + 텔레그램 전송
// 외부 패키지 없음. server.js 가 10초마다 evaluate() 를 호출한다.
const https = require('https');
const fs = require('fs');
const path = require('path');

const DEFAULTS = {
  telegram: { enabled: false, token: '', chatId: '' },
  rules: {
    cpu: 80, cpu_minutes: 1,       // CPU 80% 이상이 1분 이상 지속
    mem: 90, mem_minutes: 1,       // 메모리 90% 이상이 1분 이상 지속
    disk: 90,                      // 디스크 사용률 90% 이상
    days_left: 30,                 // 예상 소진 30일 이내
    offline: true,                 // 오프라인 알림
  },
  remind_min: 60,                  // 계속 경고 상태면 이 간격으로 다시 알림 (0 = 처음 한 번만)
  recovery: true,                  // 정상 복귀 알림
  quiet: { enabled: false, from: '23:00', to: '07:00' },  // 조용 시간 (오프라인 알림은 예외)
  title: 'IMS 모니터',
};

function deepMerge(base, patch) {
  const out = { ...base };
  for (const [k, v] of Object.entries(patch || {})) {
    if (v && typeof v === 'object' && !Array.isArray(v) && base[k] && typeof base[k] === 'object') out[k] = deepMerge(base[k], v);
    else if (v !== undefined) out[k] = v;
  }
  return out;
}
function fmtBytes(b) { if (!b) return '0 B'; const u = ['B', 'KB', 'MB', 'GB', 'TB']; let i = 0; while (b >= 1024 && i < 4) { b /= 1024; i++; } return (i >= 3 ? b.toFixed(1) : Math.round(b)) + ' ' + u[i]; }
function ts(d = new Date()) { const p = (n) => String(n).padStart(2, '0'); return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`; }
function esc(s) { return String(s ?? '').replace(/[&<>]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c])); }

function create({ settingsFile, log = console.log }) {
  let settings = { ...DEFAULTS };
  try { settings = deepMerge(DEFAULTS, JSON.parse(fs.readFileSync(settingsFile, 'utf8'))); } catch (e) { if (e.code !== 'ENOENT') log('알림 설정 읽기 실패:', e.message); }
  function saveSettings() {
    try { fs.mkdirSync(path.dirname(settingsFile), { recursive: true }); fs.writeFileSync(settingsFile, JSON.stringify(settings, null, 2)); } catch (e) { log('알림 설정 저장 실패:', e.message); }
  }

  // key = host|rule[|mount]  →  { since, active, notified, lastSent, msg }
  const states = new Map();
  let recent = [];            // 최근 이벤트 (최신이 앞)
  const RECENT_MAX = 300;
  let seq = 0;

  // ---- 텔레그램 ----
  function tgRequest(method, body) {
    return new Promise((resolve, reject) => {
      const token = settings.telegram.token;
      if (!token) return reject(new Error('텔레그램 봇 토큰이 없습니다'));
      const data = JSON.stringify(body || {});
      const req = https.request({ hostname: 'api.telegram.org', path: `/bot${token}/${method}`, method: 'POST', timeout: 10000,
        headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(data) } }, (res) => {
        let buf = ''; res.on('data', (c) => buf += c); res.on('end', () => {
          try { const j = JSON.parse(buf); if (j.ok) resolve(j.result); else reject(new Error(j.description || `HTTP ${res.statusCode}`)); }
          catch (e) { reject(new Error(res.statusCode === 401 || res.statusCode === 404 ? `봇 토큰이 잘못되었습니다 (HTTP ${res.statusCode})` : `텔레그램 응답 오류 (HTTP ${res.statusCode}) - 인터넷 차단 또는 프록시 확인`)); }
        });
      });
      req.on('timeout', () => { req.destroy(new Error('텔레그램 연결 시간 초과 (IMS 서버에서 인터넷이 되는지 확인)')); });
      req.on('error', (e) => reject(new Error(`텔레그램 연결 실패: ${e.message}`)));
      req.end(data);
    });
  }
  async function sendTelegram(text) {
    if (!settings.telegram.enabled) return { skipped: 'disabled' };
    if (!settings.telegram.chatId) throw new Error('채팅 ID가 없습니다 ("채팅 ID 찾기"로 선택)');
    if (!/^-?\d{5,}$/.test(String(settings.telegram.chatId))) throw new Error('채팅 ID는 숫자여야 합니다 (봇 아이디 @... 가 아님)');
    await tgRequest('sendMessage', { chat_id: settings.telegram.chatId, text, parse_mode: 'HTML', disable_web_page_preview: true });
    return { sent: true };
  }
  async function discoverChats() {
    const updates = await tgRequest('getUpdates', { limit: 100 });
    const seen = new Map();
    for (const u of updates) {
      const m = u.message || u.channel_post || u.my_chat_member?.chat && { chat: u.my_chat_member.chat };
      const c = m && m.chat; if (!c) continue;
      seen.set(String(c.id), { id: String(c.id), type: c.type, name: c.title || [c.first_name, c.last_name].filter(Boolean).join(' ') || c.username || String(c.id) });
    }
    return [...seen.values()];
  }

  function inQuiet(now = new Date()) {
    const q = settings.quiet; if (!q.enabled) return false;
    const [fh, fm] = q.from.split(':').map(Number), [th, tm] = q.to.split(':').map(Number);
    const cur = now.getHours() * 60 + now.getMinutes(), from = fh * 60 + fm, to = th * 60 + tm;
    return from <= to ? (cur >= from && cur < to) : (cur >= from || cur < to);
  }

  function push(ev) {
    ev.id = ++seq; ev.time = Date.now();
    recent.unshift(ev); if (recent.length > RECENT_MAX) recent.length = RECENT_MAX;
    return ev;
  }
  async function deliver(ev, critical) {
    const label = ev.name ? `${ev.name} (${ev.host})` : ev.host;
    const icon = ev.kind === 'recovery' ? '🟢' : ev.kind === 'remind' ? '🟠' : '🔴';
    const text = `${icon} <b>[${esc(settings.title)}] ${esc(label)}</b>\n${esc(ev.msg)}\n<i>${ts(new Date(ev.time))}</i>`;
    if (inQuiet() && !critical) { ev.delivery = 'quiet'; return; }
    try { const r = await sendTelegram(text); ev.delivery = r.sent ? 'telegram' : 'off'; }
    catch (e) { ev.delivery = 'error'; ev.error = e.message; log('텔레그램 전송 실패:', e.message); }
  }

  // ---- 규칙 평가 ----
  function check(key, host, name, cond, msgFn, opts = {}) {
    const now = Date.now();
    let st = states.get(key);
    if (!st) { st = { since: null, active: false, notified: false, lastSent: 0 }; states.set(key, st); }
    if (cond) {
      if (!st.since) st.since = now;
      const sustainMs = (opts.minutes || 0) * 60000;
      if (!st.active && now - st.since >= sustainMs) {
        st.active = true; st.notified = true; st.lastSent = now; st.msg = msgFn();
        deliver(push({ kind: 'alert', host, name, rule: opts.rule, msg: st.msg }), opts.critical);
      } else if (st.active && settings.remind_min > 0 && now - st.lastSent >= settings.remind_min * 60000) {
        st.lastSent = now; st.msg = msgFn();
        deliver(push({ kind: 'remind', host, name, rule: opts.rule, msg: '(계속) ' + st.msg }), opts.critical);
      }
    } else {
      st.since = null;
      if (st.active) {
        st.active = false;
        if (st.notified && settings.recovery) deliver(push({ kind: 'recovery', host, name, rule: opts.rule, msg: opts.recoverMsg ? opts.recoverMsg() : '정상 복귀' }), opts.critical);
        st.notified = false;
      }
    }
  }

  function evaluate(servers) {
    const r = settings.rules;
    const live = new Set();
    for (const s of servers) {
      live.add(s.host);
      const H = s.host, N = s.name;
      // 오프라인
      check(`${H}|offline`, H, N, r.offline && !s.online,
        () => `서버 응답 없음 (마지막 수신 ${Math.round(s.age / 60)}분 전)`, { rule: 'offline', critical: true, recoverMsg: () => '서버 응답 복구' });
      if (!s.online) {   // 오프라인이면 다른 규칙은 판단 보류 (값이 오래된 것)
        for (const k of ['cpu', 'mem']) { const st = states.get(`${H}|${k}`); if (st) st.since = null; }
        continue;
      }
      // CPU / 메모리 (지속 시간, 히스테리시스 5%)
      const cpuSt = states.get(`${H}|cpu`);
      check(`${H}|cpu`, H, N, s.cpu >= r.cpu || (cpuSt && cpuSt.active && s.cpu >= r.cpu - 5),
        () => `CPU ${s.cpu}% 가 ${r.cpu_minutes}분 이상 지속 (기준 ${r.cpu}%)`, { rule: 'cpu', minutes: r.cpu_minutes, recoverMsg: () => `CPU 정상 복귀 (${s.cpu}%)` });
      const memSt = states.get(`${H}|mem`);
      check(`${H}|mem`, H, N, s.mem_pct >= r.mem || (memSt && memSt.active && s.mem_pct >= r.mem - 5),
        () => `메모리 ${s.mem_pct}% 가 ${r.mem_minutes}분 이상 지속 (${fmtBytes(s.mem_used)} / ${fmtBytes(s.mem_total)})`, { rule: 'mem', minutes: r.mem_minutes, recoverMsg: () => `메모리 정상 복귀 (${s.mem_pct}%)` });
      // 디스크
      const gmap = {}; for (const g of (s.growth || [])) gmap[g.mount] = g;
      for (const d of (s.disks || [])) {
        const k = `${H}|disk|${d.mount}`, st = states.get(k);
        check(k, H, N, d.pct >= r.disk || (st && st.active && d.pct >= r.disk - 2),
          () => `${d.mount} 드라이브 ${d.pct}% 사용 (${fmtBytes(d.used)} / ${fmtBytes(d.total)}, 기준 ${r.disk}%)`, { rule: 'disk', recoverMsg: () => `${d.mount} 드라이브 사용률 정상 (${d.pct}%)` });
        const g = gmap[d.mount];
        check(`${H}|full|${d.mount}`, H, N, !!(g && g.days_left != null && g.days_left <= r.days_left),
          () => `${d.mount} 드라이브 약 ${g.days_left}일 후 가득 찰 것으로 예상 (하루 +${fmtBytes(g.rate_day)})`, { rule: 'full', recoverMsg: () => `${d.mount} 드라이브 소진 예상 해제` });
      }
    }
    for (const key of [...states.keys()]) if (!live.has(key.split('|')[0])) states.delete(key);
  }

  return {
    evaluate,
    forget(host) { for (const key of [...states.keys()]) if (key.split('|')[0] === host) states.delete(key); },
    getActive() { const out = []; for (const [key, st] of states) if (st.active) { const [host, rule, mount] = key.split('|'); out.push({ host, rule, mount, since: st.since, msg: st.msg }); } return out; },
    getRecent(n = 100) { return recent.slice(0, n); },
    getSettings(masked = true) {
      const s = JSON.parse(JSON.stringify(settings));
      if (masked && s.telegram.token) s.telegram.token = '****' + s.telegram.token.slice(-4);
      return s;
    },
    updateSettings(patch) {
      if (patch && patch.telegram && typeof patch.telegram.token === 'string' && patch.telegram.token.startsWith('****')) delete patch.telegram.token;  // 마스킹된 값은 유지
      settings = deepMerge(settings, patch);
      saveSettings();
      return this.getSettings(true);
    },
    async sendTest() {
      if (!/^-?\d{5,}$/.test(String(settings.telegram.chatId))) throw new Error('채팅 ID는 숫자여야 합니다. 봇에게 메시지를 보낸 뒤 "채팅 ID 찾기"로 본인을 선택하세요');
      const r = await tgRequest('sendMessage', { chat_id: settings.telegram.chatId, parse_mode: 'HTML',
        text: `✅ <b>[${esc(settings.title)}] 테스트</b>\n알림 연결이 정상입니다.\n<i>${ts()}</i>` });
      return { ok: true, message_id: r.message_id };
    },
    discoverChats,
    exportState() { return { recent, states: [...states.entries()], seq }; },
    importState(st) {
      if (!st) return;
      if (Array.isArray(st.recent)) recent = st.recent.slice(0, RECENT_MAX);
      if (Array.isArray(st.states)) for (const [k, v] of st.states) states.set(k, v);
      if (st.seq) seq = st.seq;
    },
  };
}

module.exports = { create, DEFAULTS };
