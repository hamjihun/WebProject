'use strict';
// 로그인 · 계정 관리 (외부 패키지 없이 Node.js 내장 crypto 만 사용)
// - 계정과 로그인 세션은 data/users.json 에 저장된다 (수집기를 새로 덮어써도 data 폴더는 유지)
// - 비밀번호를 잊었을 때: users.json 을 지우고 수집기를 다시 시작하면 admin / rhksflwk1@ 로 초기화된다
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

// 화면 묶음(앱). 여기에 한 줄 추가하면 홈 화면 타일과 계정 권한 목록에 자동으로 나온다.
const APPS = [
  {
    key: 'monitor', name: '서버 모니터링', desc: '서버 상태 · 백업 · 통계', icon: '🖥️', ready: true, home: 'dashboard.html',
    pages: [['dashboard.html', '대시보드'], ['topology.html', '구성도'], ['index.html', '서버 현황'], ['backup.html', '백업'], ['stats.html', '통계 · 리포트']],
  },
  {
    key: 'schedule', name: '일정 관리', desc: '일정 · 메모 (준비 중)', icon: '📅', ready: false, home: 'schedule.html',
    pages: [['schedule.html', '일정']],
  },
];
const ALL_PAGES = APPS.reduce((a, app) => a.concat(app.pages.map((p) => p[0])), []);
const ADMIN_PAGE = 'users.html';                   // 계정 관리 (관리자만)
const OPEN_FILES = new Set(['login.html', 'common.js', 'favicon.ico', 'app.ico']);   // 로그인 없이 볼 수 있는 파일
const DEFAULT_ADMIN = { id: 'admin', name: '관리자', pw: 'rhksflwk1@' };
const SESS_HOURS = 12, KEEP_DAYS = 30;

function hashPw(pw, salt) { return crypto.scryptSync(String(pw), salt, 32).toString('hex'); }
function newSalt() { return crypto.randomBytes(16).toString('hex'); }
function newSid() { return crypto.randomBytes(24).toString('hex'); }
function safeEq(a, b) { const x = Buffer.from(String(a)), y = Buffer.from(String(b)); return x.length === y.length && crypto.timingSafeEqual(x, y); }

function create(opts) {
  const FILE = opts.file;
  const log = opts.log || (() => {});
  let users = {};          // id → { id, name, admin, pages[], salt, hash, created, last_login }
  let sessions = {};       // sid → { id, exp }

  function save() {
    try {
      fs.mkdirSync(path.dirname(FILE), { recursive: true });
      fs.writeFileSync(FILE, JSON.stringify({ users, sessions }, null, 1));
    } catch (e) { log('계정 저장 실패: ' + e.message); }
  }
  function load() {
    try {
      const o = JSON.parse(fs.readFileSync(FILE, 'utf8'));
      users = o.users || {}; sessions = o.sessions || {};
      const now = Date.now(); for (const k of Object.keys(sessions)) if (!sessions[k] || sessions[k].exp < now) delete sessions[k];
    } catch (e) { if (e.code !== 'ENOENT') log('계정 파일 읽기 실패: ' + e.message); }
    if (!Object.keys(users).length) {
      const salt = newSalt();
      users[DEFAULT_ADMIN.id] = { id: DEFAULT_ADMIN.id, name: DEFAULT_ADMIN.name, admin: true, pages: ALL_PAGES.slice(), salt, hash: hashPw(DEFAULT_ADMIN.pw, salt), created: Date.now(), last_login: null };
      save();
      log(`관리자 계정을 만들었습니다: ${DEFAULT_ADMIN.id} (비밀번호는 설치 안내 참고, 화면에서 바꿀 수 있습니다)`);
    }
  }
  load();

  function pub(u) { return u ? { id: u.id, name: u.name || u.id, admin: !!u.admin, pages: u.admin ? ALL_PAGES.slice() : (u.pages || []), created: u.created, last_login: u.last_login } : null; }
  function can(u, file) {
    if (!u) return false;
    if (u.admin) return true;
    if (file === ADMIN_PAGE) return false;
    if (!ALL_PAGES.includes(file)) return true;          // 목록에 없는 보조 파일(그림 등)은 로그인만 되어 있으면 허용
    return (u.pages || []).includes(file);
  }

  return {
    APPS, ALL_PAGES, ADMIN_PAGE, OPEN_FILES,
    isOpenFile(file) { return OPEN_FILES.has(file); },
    // 쿠키에서 로그인한 사용자 찾기
    fromCookie(cookie) {
      const m = /(?:^|;\s*)ims_sess=([a-f0-9]+)/.exec(String(cookie || ''));
      if (!m) return null;
      const s = sessions[m[1]];
      if (!s || s.exp < Date.now()) { if (s) { delete sessions[m[1]]; save(); } return null; }
      return users[s.id] || null;
    },
    login(id, pw, keep) {
      const u = users[String(id || '').trim().toLowerCase()];
      if (!u) return null;
      if (!safeEq(hashPw(pw, u.salt), u.hash)) return null;
      const sid = newSid();
      sessions[sid] = { id: u.id, exp: Date.now() + (keep ? KEEP_DAYS * 86400000 : SESS_HOURS * 3600000) };
      u.last_login = Date.now();
      const now = Date.now(); for (const k of Object.keys(sessions)) if (sessions[k].exp < now) delete sessions[k];
      save();
      return { sid, user: pub(u), keep: !!keep };
    },
    logout(cookie) {
      const m = /(?:^|;\s*)ims_sess=([a-f0-9]+)/.exec(String(cookie || ''));
      if (m && sessions[m[1]]) { delete sessions[m[1]]; save(); }
    },
    can,
    pub,
    list() { return Object.values(users).sort((a, b) => (b.admin ? 1 : 0) - (a.admin ? 1 : 0) || a.id.localeCompare(b.id)).map(pub); },
    count() { return Object.keys(users).length; },
    // 계정 만들기 / 고치기. raw: { id, name, pw, admin, pages }
    upsert(raw, isNew) {
      const id = String(raw.id || '').trim().toLowerCase();
      if (!/^[a-z0-9_.-]{2,20}$/.test(id)) throw new Error('아이디는 영문 소문자·숫자로 2~20자입니다');
      if (isNew && users[id]) throw new Error('이미 있는 아이디입니다');
      if (!isNew && !users[id]) throw new Error('없는 계정입니다');
      const u = users[id] || { id, created: Date.now(), last_login: null, pages: [] };
      if (raw.name != null) u.name = String(raw.name).trim().slice(0, 30) || id;
      if (raw.pw) {
        if (String(raw.pw).length < 4) throw new Error('비밀번호는 4자 이상이어야 합니다');
        u.salt = newSalt(); u.hash = hashPw(raw.pw, u.salt);
      } else if (isNew) throw new Error('비밀번호를 입력하세요');
      if (raw.admin != null) u.admin = !!raw.admin;
      if (Array.isArray(raw.pages)) u.pages = raw.pages.filter((p) => ALL_PAGES.includes(p));
      if (u.admin) u.pages = ALL_PAGES.slice();
      users[id] = u;
      if (!Object.values(users).some((x) => x.admin)) { u.admin = true; u.pages = ALL_PAGES.slice(); }   // 관리자가 한 명도 없어지는 것은 막는다
      save();
      return pub(u);
    },
    remove(id, bySelf) {
      id = String(id || '').trim().toLowerCase();
      const u = users[id];
      if (!u) throw new Error('없는 계정입니다');
      if (bySelf === id) throw new Error('지금 로그인한 계정은 지울 수 없습니다');
      if (u.admin && Object.values(users).filter((x) => x.admin).length <= 1) throw new Error('관리자 계정이 하나뿐이라 지울 수 없습니다');
      delete users[id];
      for (const k of Object.keys(sessions)) if (sessions[k].id === id) delete sessions[k];
      save();
    },
    // 홈 화면에 보여줄 앱 목록 (이 사용자가 볼 수 있는 것만)
    appsFor(u) {
      const out = APPS.filter((a) => a.pages.some((p) => can(u, p[0]))).map((a) => ({ key: a.key, name: a.name, desc: a.desc, icon: a.icon, ready: a.ready, home: a.pages.filter((p) => can(u, p[0]))[0][0], pages: a.pages.filter((p) => can(u, p[0])) }));
      if (u && u.admin) out.push({ key: 'admin', name: '계정 관리', desc: '사용자 만들기 · 권한 설정', icon: '👤', ready: true, home: ADMIN_PAGE, pages: [[ADMIN_PAGE, '계정 관리']] });
      return out;
    },
  };
}

module.exports = { create, APPS, ALL_PAGES };
