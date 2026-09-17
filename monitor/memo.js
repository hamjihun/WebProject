'use strict';
// 메모 보드 (포스트잇처럼 붙이는 메모판). 사람마다 자기 보드를 여러 개 가진다.
// 저장 위치: data/memo.json  { "<계정 id>": { active: "<보드 id>", boards: [ { id, name, color, notes: [...], areas: [...] } ] } }
const fs = require('fs');
const path = require('path');

const MAX_BOARDS = 20, MAX_NOTES = 500, MAX_AREAS = 60, MAX_LINKS = 200, MAX_TEXT = 5000, MAX_TRASH = 50;
const MAX_IMG = 3 * 1024 * 1024;          // 사진 한 장 (data URL 글자 수)
const MAX_USER = 40 * 1024 * 1024;        // 한 사람이 쓸 수 있는 총 용량
const num = (v, d = 0) => { const n = Number(v); return Number.isFinite(n) ? Math.round(n) : d; };
const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));
const str = (v, n) => String(v == null ? '' : v).slice(0, n);
const color = (v, d) => /^[a-z0-9-]{1,20}$/i.test(String(v || '')) ? String(v) : d;
const rid = () => Math.random().toString(36).slice(2, 10);
// 바로가기 주소: 웹(http/https)과 원격데스크톱(mstsc:)만 허용한다 (javascript: 같은 건 버린다)
const href = (v) => { const t = String(v == null ? '' : v).trim().slice(0, 500); return /^(https?:\/\/|mstsc:)/i.test(t) ? t : ''; };

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
      fs: clamp(num(n.fs, 13), 10, 40), min: !!n.min, updated: num(n.updated, Date.now()),
    };
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
    const c = { del: num(t && t.del, Date.now()), b: str(t && t.b, 32), bn: str(t && t.bn, 20) };
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
    fs: clamp(num(p && p.fs, 13), 10, 40),
    w: clamp(num(p && p.w, 200), 80, 1600),
    h: clamp(num(p && p.h, 200), 60, 1600),
    acolor: color(p && p.acolor, 'green'),
    magnet: !(p && p.magnet === false),
  });
  // 바로가기 타일 (바탕화면 아이콘처럼 눌러서 여는 것)
  const link = (l) => ({
    id: str(l.id, 32) || rid(),
    x: clamp(num(l.x), 0, 20000), y: clamp(num(l.y), 0, 20000),
    w: clamp(num(l.w, 96), 60, 400), h: clamp(num(l.h, 88), 50, 400),
    name: str(l.name, 30), url: href(l.url), icon: str(l.icon, 8), color: color(l.color, 'gray'),
  });
  const board = (b, i) => ({
    id: str(b.id, 32) || rid(),
    name: str(b.name, 20) || `메모 ${i + 1}`,
    color: color(b.color, 'yellow'),
    notes: (Array.isArray(b.notes) ? b.notes : []).slice(0, MAX_NOTES).map(note),
    areas: (Array.isArray(b.areas) ? b.areas : []).slice(0, MAX_AREAS).map(area),
    links: (Array.isArray(b.links) ? b.links : []).slice(0, MAX_LINKS).map(link),
  });

  // 예전 형식({ notes, areas })을 보드 하나로 옮긴다
  function boardsOf(uid) {
    const u = all[uid];
    if (!u) return { boards: [], active: '' };
    if (Array.isArray(u.boards)) return { boards: u.boards, active: str(u.active, 32) };
    if (u.notes || u.areas) return { boards: [{ id: rid(), name: '메모 1', color: 'yellow', notes: u.notes || [], areas: u.areas || [] }], active: '' };
    return { boards: [], active: '' };
  }

  return {
    get(uid) {
      const { boards, active } = boardsOf(uid);
      const list = boards.slice(0, MAX_BOARDS).map(board);
      if (!list.length) list.push({ id: rid(), name: '메모 1', color: 'yellow', notes: [], areas: [], links: [] });
      const act = list.some((b) => b.id === active) ? active : list[0].id;
      return { boards: list, active: act, trash: trashOf(all[uid], boards), prefs: prefs(all[uid] && all[uid].prefs) };
    },
    set(uid, data) {
      const list = (Array.isArray(data && data.boards) ? data.boards : []).slice(0, MAX_BOARDS).map(board);
      if (!list.length) list.push({ id: rid(), name: '메모 1', color: 'yellow', notes: [], areas: [], links: [] });
      const active = list.some((b) => b.id === data.active) ? data.active : list[0].id;
      const trash = (Array.isArray(data && data.trash) ? data.trash : []).slice(0, MAX_TRASH).map(trashItem);
      const next = { active, boards: list, trash, prefs: prefs(data && data.prefs) };
      const size = JSON.stringify(next).length;
      if (size > MAX_USER) throw new Error('사진이 너무 많습니다. 오래된 사진 메모를 지운 뒤 다시 저장해 주세요');
      all[uid] = next;
      save();
      return { boards: list, active, trash, prefs: next.prefs };
    },
    removeUser(uid) { if (all[uid]) { delete all[uid]; save(); } },
  };
}

module.exports = { create };
