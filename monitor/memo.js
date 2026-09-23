'use strict';
// 메모 보드 (포스트잇처럼 붙이는 메모판). 사람마다 자기 보드를 여러 개 가진다.
// 저장 위치: data/memo.json  { "<계정 id>": { active, boards: [ { id, name, color, ap, pages: [ { id, name, notes, areas, links } ] } ], trash, prefs } }
// 상단 탭 = boards(메모판), 왼쪽 탭 = pages(그 메모판 안의 쪽). 예전 형식(보드가 바로 notes 를 들고 있던 것)은 읽을 때 쪽 하나로 옮긴다.
const fs = require('fs');
const path = require('path');

const MAX_BOARDS = 20, MAX_PAGES = 50, MAX_NOTES = 500, MAX_AREAS = 60, MAX_LINKS = 200, MAX_TEXT = 5000, MAX_TRASH = 50;
const MAX_STROKES = 600, MAX_PTS = 2000;   // 그림 메모: 선 개수 · 선 하나의 점 개수
const MAX_ALARMS = 100;                    // 알림판에 담아 둘 수 있는 알림 개수
const MAX_IMG = 3 * 1024 * 1024;          // 사진 한 장 (data URL 글자 수)
const MAX_USER = 40 * 1024 * 1024;        // 한 사람이 쓸 수 있는 총 용량
const num = (v, d = 0) => { const n = Number(v); return Number.isFinite(n) ? Math.round(n) : d; };
const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));
const str = (v, n) => String(v == null ? '' : v).slice(0, n);
// 메모 본문 서식: 굵게·기울임·밑줄·취소선·줄바꿈·글자 크기·링크만 남기고 전부 걷어낸다
const TAG_OK = { b: 1, strong: 1, i: 1, em: 1, u: 1, s: 1, strike: 1, br: 1, div: 1, p: 1 };
function safeHtml(v, max) {
  let t = String(v == null ? '' : v);
  t = t.replace(/<!--[\s\S]*?-->/g, '');
  t = t.replace(/<(script|style)[\s\S]*?<\/\1>/gi, '');
  t = t.replace(/<\/?([a-z0-9]+)([^>]*)>/gi, (m, tag, attr) => {
    tag = tag.toLowerCase();
    const close = m[1] === '/';
    if (tag === 'span') {                                  // 글자 크기만 허용
      if (close) return '</span>';
      const f = /font-size\s*:\s*(\d{1,3})px/i.exec(attr || '');
      const px = f ? Math.min(72, Math.max(8, Number(f[1]))) : 0;
      return px ? `<span style="font-size:${px}px">` : '<span>';
    }
    if (tag === 'a') {                                     // 웹 주소만 허용
      if (close) return '</a>';
      const h = /href\s*=\s*["']?(https?:\/\/[^"'\s>]+)/i.exec(attr || '');
      if (!h) return '';
      const url = h[1].replace(/"/g, '%22').slice(0, 500);
      return `<a href="${url}" target="_blank" rel="noopener noreferrer">`;
    }
    if (!TAG_OK[tag]) return '';
    return close ? `</${tag}>` : (tag === 'br' ? '<br>' : `<${tag}>`);
  });
  return t.slice(0, max);
}
const color = (v, d) => /^[a-z0-9-]{1,20}$/i.test(String(v || '')) ? String(v) : d;
const rid = () => Math.random().toString(36).slice(2, 10);
// 바로가기 주소: 웹(http/https)만 허용한다 (javascript: 같은 건 버린다)
const href = (v) => { const t = String(v == null ? '' : v).trim().slice(0, 500); return /^https?:\/\//i.test(t) ? t : ''; };
// 그림 메모(그림판): 선 목록만 저장한다. { w, h(기준 크기), s:[ { c:색, w:굵기, e:지우개, p:[x,y,x,y…] } ] }
const hex = (v, d) => (/^#[0-9a-f]{6}$/i.test(String(v || '')) ? String(v) : d);
function drawing(d) {
  if (!d || typeof d !== 'object' || !Array.isArray(d.s)) return undefined;
  const s = d.s.slice(0, MAX_STROKES).map((k) => ({
    c: hex(k && k.c, '#1f2937'),
    w: clamp(num(k && k.w, 4), 1, 200),
    e: (k && k.e) ? 1 : 0,
    p: (Array.isArray(k && k.p) ? k.p : []).slice(0, MAX_PTS).map((v) => clamp(num(v), -8000, 8000)),
  })).filter((k) => k.p.length >= 2);
  return { w: clamp(num(d.w, 320), 40, 4000), h: clamp(num(d.h, 232), 40, 4000), s };
}

// 알림 (알림판). 시각은 1970년부터의 밀리초, rep = 반복
const REP_OK = { none: 1, day: 1, week: 1, month: 1 };
const alarm = (a) => ({
  id: str(a && a.id, 32) || rid(),
  txt: str(a && a.txt, 200),
  at: clamp(num(a && a.at, Date.now()), 0, 4102444800000),      // 2100년까지
  rep: REP_OK[a && a.rep] ? a.rep : 'none',
  done: !!(a && a.done),
});

function create(opts) {
  const FILE = opts.file;
  const log = opts.log || (() => {});
  let all = {};

  function save() {
    try { fs.mkdirSync(path.dirname(FILE), { recursive: true }); fs.writeFileSync(FILE, JSON.stringify(all)); }
    catch (e) { log('메모 저장 실패: ' + e.message); }
  }
  function load() {
    try { all = JSON.parse(fs.readFileSync(FILE, 'utf8')) || {}; }
    catch (e) { if (e.code !== 'ENOENT') log('메모 파일 읽기 실패: ' + e.message); }
  }
  load();

  const note = (n) => {
    const o = {
      id: str(n.id, 32) || rid(),
      x: clamp(num(n.x), 0, 20000), y: clamp(num(n.y), 0, 20000),
      w: clamp(num(n.w, 200), 80, 1600), h: clamp(num(n.h, 200), 60, 1600),
      title: str(n.title, 60), text: str(n.text, MAX_TEXT), color: color(n.color, 'yellow'), z: num(n.z, 1),
      html: safeHtml(n.html, MAX_TEXT * 3),
      fs: clamp(num(n.fs, 13), 8, 72), min: !!n.min, updated: num(n.updated, Date.now()),
    };
    const dr = drawing(n.draw);
    if (dr) o.draw = dr;
    if (typeof n.img === 'string' && n.img.startsWith('data:image/')) {
      if (n.img.length > MAX_IMG) throw new Error('사진 한 장이 너무 큽니다 (3MB 넘음)');
      o.img = n.img;
    }
    return o;
  };
  const area = (a) => ({
    id: str(a.id, 32) || rid(),
    x: clamp(num(a.x), 0, 20000), y: clamp(num(a.y), 0, 20000),
    w: clamp(num(a.w, 520), 160, 4000), h: clamp(num(a.h, 380), 120, 4000),
    title: str(a.title, 40), color: color(a.color, 'green'),
  });
  // 휴지통: 사람마다 하나. 지운 메모·범위를 최근 50개까지 들고 있다 (b/bn = 원래 있던 메모판)
  const trashItem = (t) => {
    const c = { del: num(t && t.del, Date.now()), b: str(t && t.b, 32), p: str(t && t.p, 32), bn: str(t && t.bn, 50) };
    if (t && t.k === 'a') return { k: 'a', ...c, o: area(t.o || {}) };
    if (t && t.k === 'l') return { k: 'l', ...c, o: link(t.o || {}) };
    return { k: 'n', ...c, o: note((t && t.o) || {}) };
  };
  const trashOf = (u, boards) => {
    let list = Array.isArray(u && u.trash) ? u.trash : null;
    if (!list) {                                   // 예전 형식: 메모판마다 휴지통 → 하나로 합친다
      list = [];
      for (const b of boards) if (Array.isArray(b.trash)) for (const t of b.trash) list.push({ ...t, b: b.id, bn: b.name });
      list.sort((x, y) => num(y.del) - num(x.del));
    }
    return list.slice(0, MAX_TRASH).map(trashItem);
  };
  // 기본값 (새 메모·새 범위를 만들 때 쓰는 설정)
  const prefs = (p) => ({
    color: color(p && p.color, 'yellow'),
    fs: clamp(num(p && p.fs, 13), 8, 72),
    w: clamp(num(p && p.w, 200), 80, 1600),
    h: clamp(num(p && p.h, 200), 60, 1600),
    acolor: color(p && p.acolor, 'green'),
    magnet: !(p && p.magnet === false),
    side: !(p && p.side === false),        // 왼쪽 탭 보이기
    alarm: !(p && p.alarm === false),      // 오른쪽 알림판 보이기
    theme: (p && p.theme) === 'dark' ? 'dark' : 'light',   // 화면 테마 (기본: 밝게)
    pc: hex(p && p.pc, '#1f2937'),                         // 그림판 펜 색
    pw: clamp(num(p && p.pw, 4), 1, 60),                   // 그림판 펜 굵기
  });
  // 바로가기 타일 (바탕화면 아이콘처럼 눌러서 여는 것)
  const link = (l) => ({
    id: str(l.id, 32) || rid(),
    x: clamp(num(l.x), 0, 20000), y: clamp(num(l.y), 0, 20000),
    w: clamp(num(l.w, 96), 60, 400), h: clamp(num(l.h, 88), 50, 400),
    name: str(l.name, 30), url: href(l.url), icon: str(l.icon, 8), color: color(l.color, 'gray'),
  });
  const page = (g, i) => ({
    id: str(g.id, 32) || rid(),
    name: str(g.name, 30) || `쪽 ${i + 1}`,
    notes: (Array.isArray(g.notes) ? g.notes : []).slice(0, MAX_NOTES).map(note),
    areas: (Array.isArray(g.areas) ? g.areas : []).slice(0, MAX_AREAS).map(area),
    links: (Array.isArray(g.links) ? g.links : []).slice(0, MAX_LINKS).map(link),
  });
  const board = (b, i) => {
    const name = str(b.name, 20) || `메모 ${i + 1}`;
    const raw = Array.isArray(b.pages) && b.pages.length ? b.pages
      : [{ id: rid(), name, notes: b.notes, areas: b.areas, links: b.links }];   // 예전 형식 → 쪽 하나로
    const pages = raw.slice(0, MAX_PAGES).map(page);
    return {
      id: str(b.id, 32) || rid(), name, color: color(b.color, 'yellow'),
      pages, ap: pages.some((g) => g.id === b.ap) ? b.ap : pages[0].id,
    };
  };

  // 예전 형식({ notes, areas })을 보드 하나로 옮긴다
  function boardsOf(uid) {
    const u = all[uid];
    if (!u) return { boards: [], active: '' };
    if (Array.isArray(u.boards)) return { boards: u.boards, active: str(u.active, 32) };
    if (u.notes || u.areas) return { boards: [{ id: rid(), name: '메모 1', color: 'yellow', notes: u.notes || [], areas: u.areas || [] }], active: '' };   // board() 가 쪽 하나로 옮긴다
    return { boards: [], active: '' };
  }

  return {
    get(uid) {
      const { boards, active } = boardsOf(uid);
      const list = boards.slice(0, MAX_BOARDS).map(board);
      if (!list.length) list.push({ id: rid(), name: '메모 1', color: 'yellow', pages: [{ id: rid(), name: '메모 1', notes: [], areas: [], links: [] }] });
      const act = list.some((b) => b.id === active) ? active : list[0].id;
      const al = (Array.isArray(all[uid] && all[uid].alarms) ? all[uid].alarms : []).slice(0, MAX_ALARMS).map(alarm);
      return { boards: list, active: act, trash: trashOf(all[uid], boards), prefs: prefs(all[uid] && all[uid].prefs), alarms: al };
    },
    set(uid, data) {
      const list = (Array.isArray(data && data.boards) ? data.boards : []).slice(0, MAX_BOARDS).map(board);
      if (!list.length) list.push({ id: rid(), name: '메모 1', color: 'yellow', pages: [{ id: rid(), name: '메모 1', notes: [], areas: [], links: [] }] });
      const active = list.some((b) => b.id === data.active) ? data.active : list[0].id;
      const trash = (Array.isArray(data && data.trash) ? data.trash : []).slice(0, MAX_TRASH).map(trashItem);
      const alarms = (Array.isArray(data && data.alarms) ? data.alarms : []).slice(0, MAX_ALARMS).map(alarm);
      const next = { active, boards: list, trash, prefs: prefs(data && data.prefs), alarms };
      const size = JSON.stringify(next).length;
      if (size > MAX_USER) throw new Error('사진이 너무 많습니다. 오래된 사진 메모를 지운 뒤 다시 저장해 주세요');
      all[uid] = next;
      save();
      return { boards: list, active, trash, prefs: next.prefs, alarms };
    },
    removeUser(uid) { if (all[uid]) { delete all[uid]; save(); } },
  };
}

module.exports = { create };
