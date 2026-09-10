// 공통: 상단 탭, 포맷 함수. 각 페이지에서 <script src="common.js"></script> 로 불러온다.
(function () {
  const UI_VERSION = '1.10.1';
  const PAGES = [['dashboard.html', '대시보드'], ['topology.html', '구성도'], ['index.html', '서버 현황'], ['stats.html', '통계 · 리포트']];
  const here = (location.pathname.split('/').pop() || 'index.html');
  const params = new URLSearchParams(location.search);
  const embed = params.get('embed') === '1' || params.get('tv') === '1';

  function esc(s) { return String(s ?? '').replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c])); }
  function fmtBytes(b) { if (!b) return '0 B'; const u = ['B', 'KB', 'MB', 'GB', 'TB']; let i = 0; while (b >= 1024 && i < 4) { b /= 1024; i++; } return (i >= 3 ? b.toFixed(1) : Math.round(b)) + ' ' + u[i]; }
  function fmtUptime(s) { s = Math.floor(s || 0); const d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60); return d ? `${d}일 ${h}시간` : h ? `${h}시간 ${m}분` : `${m}분`; }
  function shortOs(os) { return String(os || '').replace(/^Microsoft\s+/i, '').replace(/\s+\d+\.\d+\.\d+(\.\d+)?\s*$/, '').replace(/\s+build-\d+/i, '').replace(/ProLiant\s+/i, '').replace(/\s*\(Core\)/i, '').trim(); }
  function fmtTime(t) { const d = new Date(t); return `${d.getMonth() + 1}/${d.getDate()} ${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`; }
  function label(s) { return s.name ? s.name : s.host; }
  // 서버 상태 등급: bad(오프라인/경고) > warn(75% 이상) > ok
  function grade(s, activeAlerts) {
    if (!s.online) return 'off';
    if ((activeAlerts || []).some(a => a.host === s.host)) return 'bad';
    const maxDisk = Math.max(0, ...(s.disks || []).map(d => d.pct || 0));
    if (s.cpu >= 90 || s.mem_pct >= 90 || maxDisk >= 90) return 'bad';
    if (s.cpu >= 75 || s.mem_pct >= 75 || maxDisk >= 75) return 'warn';
    return 'ok';
  }

  function renderNav(active) {
    if (embed) return;
    const nav = document.createElement('nav');
    nav.id = 'topnav';
    nav.innerHTML = `<div class="brand">서버 모니터</div>` +
      PAGES.map(([f, t]) => `<a href="${f}" class="${f === (active || here) ? 'on' : ''}">${t}</a>`).join('') +
      `<span class="spacer"></span><span class="ver" id="navver"></span><button class="snd" id="navfs" title="전체화면 (F11 과 같음, 다시 누르거나 Esc 로 해제)">⛶ 전체화면</button><button class="snd" id="navsnd" title="알림 소리 설정">🔊</button><a href="index.html#alerts" class="bell" id="navbell">🔔 알림<b id="navcnt" hidden>0</b></a>`;
    document.body.insertBefore(nav, document.body.firstChild);
    const st = document.createElement('style');
    st.textContent = `#topnav{display:flex;align-items:center;gap:4px;padding:0 16px;height:44px;background:var(--card,#1e293b);border-bottom:1px solid var(--line,#334155);font-family:"Malgun Gothic","Apple SD Gothic Neo",system-ui,sans-serif}
#topnav .brand{font-weight:700;font-size:15px;color:var(--text,#e2e8f0);margin-right:14px}
#topnav a{color:var(--muted,#94a3b8);text-decoration:none;font-size:13px;padding:6px 12px;border-radius:6px}
#topnav a:hover{color:var(--text,#e2e8f0);background:rgba(148,163,184,.12)}
#topnav a.on{color:#fff;background:var(--accent,#38bdf8);font-weight:700}
:root[data-theme="light"] #topnav a.on{color:#0f172a}
#topnav .spacer{flex:1}#topnav .ver{font-size:11px;color:var(--muted,#94a3b8);margin-right:8px}
#topnav .bell b{background:#ef4444;color:#fff;border-radius:9px;padding:0 6px;font-size:11px;margin-left:4px}
#topnav .snd{background:none;border:1px solid var(--line,#334155);color:var(--muted,#94a3b8);border-radius:6px;padding:4px 8px;cursor:pointer;font-size:13px;margin-right:6px;font-family:inherit}
#topnav .snd.on{color:var(--text,#e2e8f0)}#topnav .snd.ring{background:#ef4444;color:#fff;border-color:#ef4444;animation:sndblink 1s infinite}
@keyframes sndblink{50%{opacity:.5}}`;
    document.head.appendChild(st);
    sndInit();
    const fs = document.getElementById('navfs');
    if (fs) { fs.onclick = () => { if (document.fullscreenElement) document.exitFullscreen(); else document.documentElement.requestFullscreen().catch(() => {}); };
      document.addEventListener('fullscreenchange', () => { fs.textContent = document.fullscreenElement ? '⛶ 전체화면 해제' : '⛶ 전체화면'; }); }
  }
  async function pollNav() {
    try {
      const r = await fetch('api/alerts'); const j = await r.json();
      const c = document.getElementById('navcnt'); if (c) { c.hidden = !(j.active || []).length; c.textContent = (j.active || []).length; }
      sndCheck(j.recent);
    } catch (e) {}
  }
  if (embed) document.addEventListener('DOMContentLoaded', sndInit);
  // ---- 알림 소리 (브라우저별 설정, localStorage) ----
  const SND_KEY = 'mon_sound';
  const sndDef = { on: false, mode: 'beep', dur: 15, vol: 0.6, quietOn: false, quietFrom: '22:00', quietTo: '07:00', remind: false, dict: '' };
  // 음성용 발음 변환: 영문 약자를 한글로 (한국어 TTS 가 ERP 를 "이앒"처럼 읽는 것 방지). 사용자 사전(snd.dict, "ERP=이알피" 한 줄씩)이 우선
  const LETTER = { A: '에이', B: '비', C: '씨', D: '디', E: '이', F: '에프', G: '지', H: '에이치', I: '아이', J: '제이', K: '케이', L: '엘', M: '엠', N: '엔', O: '오', P: '피', Q: '큐', R: '알', S: '에스', T: '티', U: '유', V: '브이', W: '더블유', X: '엑스', Y: '와이', Z: '지' };
  const WORDS = { ACE: '에이스', ERP: '이알피', MES: '엠이에스', CPU: '씨피유', NAS: '나스', DB: '디비', PC: '피씨', VM: '브이엠', ESXI: '이에스엑스아이', IMS: '아이엠에스', SQL: '에스큐엘', WEB: '웹', DNS: '디엔에스', AD: '에이디', SRV: '서버', SERVER: '서버', FILE: '파일', DEV: '개발', TEST: '테스트', BACKUP: '백업', WIN: '윈', APP: '앱', API: '에이피아이', GW: '지더블유', VPN: '브이피엔', HR: '에이치알', ILSAN: '일산', V3: '브이쓰리', NAS1: '나스 원', OLD: '올드', NEW: '뉴', MAIN: '메인', SUB: '서브', PROD: '운영', ADMIN: '어드민', WATCHING: '워칭' };
  function toSpeech(text) {
    let t = String(text || '');
    for (const line of (snd.dict || '').split(/\n/)) { const m = /^\s*([^=]+?)\s*=\s*(.+?)\s*$/.exec(line); if (m) t = t.replace(new RegExp('\\b' + m[1].replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '\\b', 'gi'), m[2]); }
    return t.replace(/[A-Za-z][A-Za-z0-9]*/g, (w) => {
      const u = w.toUpperCase();
      if (WORDS[u]) return WORDS[u];
      if (/^[A-Z0-9]{1,6}$/.test(w) || /^[A-Z]{2,}$/.test(u) && w.length <= 6) return u.split('').map((c) => LETTER[c] || c).join(' ');
      return w;   // 긴 이름은 그대로 (TTS 가 단어처럼 읽음)
    });
  }
  const RULE_KO = { cpu: 'CPU 경고', mem: '메모리 경고', disk: '디스크 경고', full: '디스크 소진 예상', offline: '오프라인' };
  let snd = { ...sndDef }; try { snd = { ...sndDef, ...JSON.parse(localStorage.getItem(SND_KEY) || '{}') }; } catch (e) {}
  let actx = null, ringTimer = null, ringUntil = 0, lastEvId = null, ringing = false, phrases = [], tick = 0;
  function sndSave() { try { localStorage.setItem(SND_KEY, JSON.stringify(snd)); } catch (e) {} sndBtn(); }
  function inQuiet() {
    if (!snd.quietOn) return false;
    const d = new Date(), cur = d.getHours() * 60 + d.getMinutes(), [fh, fm] = snd.quietFrom.split(':').map(Number), [th, tm] = snd.quietTo.split(':').map(Number), f = fh * 60 + fm, t = th * 60 + tm;
    return f <= t ? (cur >= f && cur < t) : (cur >= f || cur < t);
  }
  function ctx() { if (!actx) { try { actx = new (window.AudioContext || window.webkitAudioContext)(); } catch (e) { return null; } } if (actx.state === 'suspended') actx.resume().catch(() => {}); return actx; }
  function tone(freq, at, len) { const c = ctx(); if (!c) return; const o = c.createOscillator(), g = c.createGain(); o.type = 'square'; o.frequency.value = freq; g.gain.setValueAtTime(0.0001, at); g.gain.exponentialRampToValueAtTime(snd.vol * 0.3, at + 0.01); g.gain.exponentialRampToValueAtTime(0.0001, at + len); o.connect(g).connect(c.destination); o.start(at); o.stop(at + len + 0.05); }
  function beepOnce() { const c = ctx(); if (!c) return; const t = c.currentTime; tone(880, t, 0.18); tone(660, t + 0.22, 0.18); tone(880, t + 0.44, 0.18); }
  function koVoice() { try { const vs = speechSynthesis.getVoices(); return vs.find(v => /ko/i.test(v.lang) && /Heami|Google|Natural|Sun/i.test(v.name)) || vs.find(v => /ko/i.test(v.lang)) || null; } catch (e) { return null; } }
  function speak(text) {
    if (!('speechSynthesis' in window) || !text) return;
    try { speechSynthesis.cancel(); const u = new SpeechSynthesisUtterance(toSpeech(text)); u.lang = 'ko-KR'; u.volume = snd.vol; u.rate = 0.95; const v = koVoice(); if (v) u.voice = v; speechSynthesis.speak(u); } catch (e) {}
  }
  function sndStop() { ringing = false; clearInterval(ringTimer); ringTimer = null; try { speechSynthesis.cancel(); } catch (e) {} sndBtn(); }
  // text: 음성으로 읽을 문장 (없으면 알림음만)
  function sndStart(force, text) {
    if (!force && (!snd.on || inQuiet())) return;
    ringUntil = snd.dur > 0 ? Date.now() + snd.dur * 1000 : Infinity;
    if (text) phrases = [text]; else if (!ringing) phrases = [];
    const useBeep = snd.mode !== 'voice', useVoice = snd.mode !== 'beep' && phrases.length;
    if (ringing) { if (useVoice) speak(phrases.join('. ')); return; }
    ringing = true; tick = 0; sndBtn();
    if (useBeep) beepOnce();
    if (useVoice) setTimeout(() => speak(phrases.join('. ')), useBeep ? 700 : 0);
    ringTimer = setInterval(() => {
      if (Date.now() > ringUntil) return sndStop();
      tick++;
      if (useBeep && (!useVoice || tick % 8 < 5)) beepOnce();       // 음성과 같이 쓰면 말하는 동안은 비프 잠깐 쉼
      if (useVoice && tick % 8 === 5) speak(phrases.join('. '));      // 8초마다 다시 읽기
    }, 1000);
  }
  // 최근 이벤트 목록(api/alerts 의 recent, 최신이 앞)에서 새 경고가 있으면 소리
  function sndCheck(recent) {
    if (!Array.isArray(recent) || !recent.length) return;
    if (lastEvId !== null) {
      const say = [];
      for (const ev of recent) {
        if (ev.id <= lastEvId) break;
        if (ev.delivery === 'held') continue;                        // 오프라인 유예 중이면 아직 조용히
        if (ev.kind === 'alert' || (ev.kind === 'remind' && snd.remind)) say.push(`${ev.name || ev.host} ${RULE_KO[ev.rule] || '경고'}`);
      }
      if (say.length) sndStart(false, say.slice(0, 3).join('. '));
    }
    lastEvId = recent[0].id;
  }
  function sndBtn() { const b = document.getElementById('navsnd'); if (!b) return; b.classList.toggle('on', snd.on); b.classList.toggle('ring', ringing); b.textContent = ringing ? '🔕 소리 끄기' : (snd.on ? '🔊' : '🔇'); b.title = ringing ? '클릭하면 소리가 멈춥니다' : ('알림 소리 ' + (snd.on ? '켜짐' : '꺼짐') + ' · 클릭해서 설정'); }
  function sndPanel() {
    let p = document.getElementById('sndpanel');
    if (p) { p.remove(); return; }
    p = document.createElement('div'); p.id = 'sndpanel';
    p.innerHTML = `<style>#sndpanel{position:fixed;top:48px;right:12px;width:290px;background:var(--card,#1e293b);border:1px solid var(--line,#334155);border-radius:10px;padding:14px;z-index:50;font-size:13px;color:var(--text,#e2e8f0);box-shadow:0 10px 30px rgba(0,0,0,.5);font-family:"Malgun Gothic","Apple SD Gothic Neo",system-ui,sans-serif}
#sndpanel h4{margin:0 0 8px;font-size:14px}#sndpanel .f{display:flex;align-items:center;justify-content:space-between;gap:8px;padding:5px 0;color:var(--muted,#94a3b8)}
#sndpanel select,#sndpanel input[type=time]{background:var(--bg,#0f172a);color:var(--text,#e2e8f0);border:1px solid var(--line,#334155);border-radius:6px;padding:4px 6px;font-family:inherit;font-size:12px}
#sndpanel input[type=range]{width:120px}#sndpanel button{background:none;border:1px solid var(--line,#334155);color:var(--text,#e2e8f0);border-radius:6px;padding:5px 10px;cursor:pointer;font-family:inherit;font-size:12px;margin-top:6px}
#sndpanel .note{font-size:11px;color:var(--muted,#94a3b8);margin-top:8px;line-height:1.5}#sndpanel .sw{width:40px;height:22px;border-radius:11px;background:#475569;position:relative;cursor:pointer;border:0;padding:0;margin:0}#sndpanel .sw.on{background:#22c55e}#sndpanel .sw::after{content:"";position:absolute;top:3px;left:3px;width:16px;height:16px;border-radius:50%;background:#fff;transition:left .15s}#sndpanel .sw.on::after{left:21px}</style>
<h4>알림 소리 (이 PC 브라우저)</h4>
<div class="f"><span>소리 알림</span><button class="sw ${snd.on ? 'on' : ''}" id="sndOn"></button></div>
<div class="f"><span>소리 종류</span><select id="sndMode">${[['beep', '알림음'], ['voice', '음성 (서버 이름 + 내용)'], ['both', '알림음 + 음성']].map(([v, t]) => `<option value="${v}" ${snd.mode === v ? 'selected' : ''}>${t}</option>`).join('')}</select></div>
<div class="f"><span>지속 시간</span><select id="sndDur">${[[5, '5초'], [15, '15초'], [30, '30초'], [60, '1분'], [180, '3분'], [0, '끌 때까지 계속']].map(([v, t]) => `<option value="${v}" ${snd.dur === v ? 'selected' : ''}>${t}</option>`).join('')}</select></div>
<div class="f"><span>볼륨</span><input type="range" id="sndVol" min="0.1" max="1" step="0.1" value="${snd.vol}"></div>
<div class="f"><span>"계속" 알림에도 소리</span><button class="sw ${snd.remind ? 'on' : ''}" id="sndRemind"></button></div>
<div class="f"><span>방해 금지 시간</span><button class="sw ${snd.quietOn ? 'on' : ''}" id="sndQuiet"></button></div>
<div class="f"><span></span><span><input type="time" id="sndFrom" value="${snd.quietFrom}"> ~ <input type="time" id="sndTo" value="${snd.quietTo}"></span></div>
<div class="f" style="flex-direction:column;align-items:stretch"><span>음성 발음 바꾸기 (한 줄에 하나, 예: ERP=이알피)</span><textarea id="sndDict" rows="3" style="background:var(--bg,#0f172a);color:var(--text,#e2e8f0);border:1px solid var(--line,#334155);border-radius:6px;padding:5px;font-family:inherit;font-size:12px;resize:vertical">${snd.dict || ''}</textarea></div>
<div style="display:flex;gap:6px"><button id="sndTest">🔔 소리 테스트</button><button id="sndClose">닫기</button></div>
<div class="note">새 경고(텔레그램으로 나가는 "경고")가 생기면 울립니다. 복귀는 울리지 않습니다. 음성은 예: "ACE ERP 서버 오프라인", "MES 서버 메모리 경고".<br>브라우저 정책상 페이지를 연 뒤 한 번은 클릭해야 소리가 납니다. 이 설정은 PC·브라우저마다 따로 저장됩니다. 영문 약자(ERP, MES, CPU 등)는 자동으로 한글 발음으로 읽고, 어색한 것은 위 칸에서 바꿉니다.</div>`;
    document.body.appendChild(p);
    const q = (id) => p.querySelector('#' + id);
    const sw = (id, key) => { q(id).onclick = () => { snd[key] = !snd[key]; q(id).classList.toggle('on', snd[key]); sndSave(); if (key === 'on' && snd.on) ctx(); }; };
    sw('sndOn', 'on'); sw('sndRemind', 'remind'); sw('sndQuiet', 'quietOn');
    q('sndDur').onchange = (e) => { snd.dur = Number(e.target.value); sndSave(); };
    q('sndMode').onchange = (e) => { snd.mode = e.target.value; sndSave(); };
    q('sndDict').onchange = (e) => { snd.dict = e.target.value; sndSave(); };
    q('sndVol').oninput = (e) => { snd.vol = Number(e.target.value); sndSave(); };
    q('sndFrom').onchange = (e) => { snd.quietFrom = e.target.value || '22:00'; sndSave(); };
    q('sndTo').onchange = (e) => { snd.quietTo = e.target.value || '07:00'; sndSave(); };
    q('sndTest').onclick = () => { ctx(); if (ringing) sndStop(); else { const d = snd.dur; snd.dur = Math.min(d || 6, 6); sndStart(true, 'ACE ERP 서버 오프라인. MES 서버 메모리 경고'); snd.dur = d; } };
    q('sndClose').onclick = () => p.remove();
  }
  function sndInit() {
    if (embed) { // TV 모드: 상단 탭이 없으므로 오른쪽 아래 작은 버튼
      const b = document.createElement('button'); b.id = 'navsnd'; b.style.cssText = 'position:fixed;right:12px;bottom:12px;z-index:40;background:rgba(30,41,59,.9);border:1px solid #334155;color:#94a3b8;border-radius:8px;padding:6px 10px;cursor:pointer;font-size:14px;font-family:inherit';
      document.body.appendChild(b);
      const st = document.createElement('style'); st.textContent = '#navsnd.ring{background:#ef4444!important;color:#fff!important;animation:sndblink 1s infinite}@keyframes sndblink{50%{opacity:.5}}'; document.head.appendChild(st);
    }
    const b = document.getElementById('navsnd'); if (!b) return;
    b.onclick = (e) => { e.preventDefault(); ctx(); if (ringing) { sndStop(); return; } sndPanel(); };
    sndBtn();
    document.addEventListener('click', () => { if (snd.on) ctx(); }, { capture: true });
    document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && ringing) sndStop(); });
  }

  window.MON = { UI_VERSION, sound: { check: sndCheck, start: sndStart, stop: sndStop, init: sndInit, settings: () => snd }, esc, fmtBytes, fmtUptime, shortOs, fmtTime, label, grade, renderNav, pollNav, embed, params,
    setVersion(v) { const e = document.getElementById('navver'); if (e) e.textContent = v ? '수집기 v' + v : ''; } };
})();
