'use strict';
// 메모 보드 (포스트잇처럼 붙이는 메모판). 사람마다 자기 보드를 가진다.
// 저장 위치: data/memo.json  { "<계정 id>": { notes: [...], areas: [...] } }
const fs = require('fs');
const path = require('path');

const MAX_NOTES = 500, MAX_AREAS = 60, MAX_TEXT = 5000;
const num = (v, d = 0) => { const n = Number(v); return Number.isFinite(n) ? Math.round(n) : d; };
const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));
const str = (v, n) => String(v == null ? '' : v).slice(0, n);
const color = (v) => /^[a-z0-9-]{1,20}$/i.test(String(v || '')) ? String(v) : 'yellow';

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

  const note = (n) => ({
    id: str(n.id, 32) || Math.random().toString(36).slice(2, 10),
    x: clamp(num(n.x), 0, 20000), y: clamp(num(n.y), 0, 20000),
    w: clamp(num(n.w, 220), 120, 1200), h: clamp(num(n.h, 180), 90, 1200),
    text: str(n.text, MAX_TEXT), color: color(n.color), z: num(n.z, 1),
    updated: num(n.updated, Date.now()),
  });
  const area = (a) => ({
    id: str(a.id, 32) || Math.random().toString(36).slice(2, 10),
    x: clamp(num(a.x), 0, 20000), y: clamp(num(a.y), 0, 20000),
    w: clamp(num(a.w, 520), 160, 4000), h: clamp(num(a.h, 380), 120, 4000),
    title: str(a.title, 40), color: color(a.color),
  });

  return {
    get(uid) {
      const b = all[uid] || {};
      return { notes: (b.notes || []).map(note), areas: (b.areas || []).map(area) };
    },
    set(uid, board) {
      const notes = (Array.isArray(board && board.notes) ? board.notes : []).slice(0, MAX_NOTES).map(note);
      const areas = (Array.isArray(board && board.areas) ? board.areas : []).slice(0, MAX_AREAS).map(area);
      all[uid] = { notes, areas };
      save();
      return { notes, areas };
    },
    removeUser(uid) { if (all[uid]) { delete all[uid]; save(); } },
  };
}

module.exports = { create };
