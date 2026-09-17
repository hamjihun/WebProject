'use strict';
// 메모 보드 (포스트잇처럼 붙이는 메모판). 사람마다 자기 보드를 여러 개 가진다.
// 저장 위치: data/memo.json  { "<계정 id>": { active: "<보드 id>", boards: [ { id, name, color, notes: [...], areas: [...] } ] } }
const fs = require('fs');
const path = require('path');

const MAX_BOARDS = 20, MAX_NOTES = 500, MAX_AREAS = 60, MAX_TEXT = 5000;
const MAX_IMG = 3 * 1024 * 1024;          // 사진 한 장 (data URL 글자 수)
const MAX_USER = 40 * 1024 * 1024;        // 한 사람이 쓸 수 있는 총 용량
const num = (v, d = 0) => { const n = Number(v); return Number.isFinite(n) ? Math.round(n) : d; };
const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));
const str = (v, n) => String(v == null ? '' : v).slice(0, n);
const color = (v, d) => /^[a-z0-9-]{1,20}$/i.test(String(v || '')) ? String(v) : d;
const rid = () => Math.random().toString(36).slice(2, 10);

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
  const board = (b, i) => ({
    id: str(b.id, 32) || rid(),
    name: str(b.name, 20) || `메모 ${i + 1}`,
    color: color(b.color, 'yellow'),
    notes: (Array.isArray(b.notes) ? b.notes : []).slice(0, MAX_NOTES).map(note),
    areas: (Array.isArray(b.areas) ? b.areas : []).slice(0, MAX_AREAS).map(area),
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
      if (!list.length) list.push({ id: rid(), name: '메모 1', color: 'yellow', notes: [], areas: [] });
      const act = list.some((b) => b.id === active) ? active : list[0].id;
      return { boards: list, active: act };
    },
    set(uid, data) {
      const list = (Array.isArray(data && data.boards) ? data.boards : []).slice(0, MAX_BOARDS).map(board);
      if (!list.length) list.push({ id: rid(), name: '메모 1', color: 'yellow', notes: [], areas: [] });
      const active = list.some((b) => b.id === data.active) ? data.active : list[0].id;
      const next = { active, boards: list };
      const size = JSON.stringify(next).length;
      if (size > MAX_USER) throw new Error('사진이 너무 많습니다. 오래된 사진 메모를 지운 뒤 다시 저장해 주세요');
      all[uid] = next;
      save();
      return { boards: list, active };
    },
    removeUser(uid) { if (all[uid]) { delete all[uid]; save(); } },
  };
}

module.exports = { create };
