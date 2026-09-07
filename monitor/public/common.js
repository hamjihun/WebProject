// 공통: 상단 탭, 포맷 함수. 각 페이지에서 <script src="common.js"></script> 로 불러온다.
(function () {
  const UI_VERSION = '1.10.0';
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
      `<span class="spacer"></span><span class="ver" id="navver"></span><a href="index.html#alerts" class="bell" id="navbell">🔔 알림<b id="navcnt" hidden>0</b></a>`;
    document.body.insertBefore(nav, document.body.firstChild);
    const st = document.createElement('style');
    st.textContent = `#topnav{display:flex;align-items:center;gap:4px;padding:0 16px;height:44px;background:var(--card,#1e293b);border-bottom:1px solid var(--line,#334155);font-family:"Malgun Gothic","Apple SD Gothic Neo",system-ui,sans-serif}
#topnav .brand{font-weight:700;font-size:15px;color:var(--text,#e2e8f0);margin-right:14px}
#topnav a{color:var(--muted,#94a3b8);text-decoration:none;font-size:13px;padding:6px 12px;border-radius:6px}
#topnav a:hover{color:var(--text,#e2e8f0);background:rgba(148,163,184,.12)}
#topnav a.on{color:#fff;background:var(--accent,#38bdf8);font-weight:700}
:root[data-theme="light"] #topnav a.on{color:#0f172a}
#topnav .spacer{flex:1}#topnav .ver{font-size:11px;color:var(--muted,#94a3b8);margin-right:8px}
#topnav .bell b{background:#ef4444;color:#fff;border-radius:9px;padding:0 6px;font-size:11px;margin-left:4px}`;
    document.head.appendChild(st);
  }
  async function pollNav() {
    try {
      const r = await fetch('api/alerts'); const j = await r.json();
      const c = document.getElementById('navcnt'); if (c) { c.hidden = !(j.active || []).length; c.textContent = (j.active || []).length; }
    } catch (e) {}
  }
  window.MON = { UI_VERSION, esc, fmtBytes, fmtUptime, shortOs, fmtTime, label, grade, renderNav, pollNav, embed, params,
    setVersion(v) { const e = document.getElementById('navver'); if (e) e.textContent = v ? '수집기 v' + v : ''; } };
})();
