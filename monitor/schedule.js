'use strict';
// 일정 관리 (부서별 업무 일정). 외부 패키지 없이 Node.js 내장 모듈만 사용.
// 저장 위치: data/schedule.json  { events: { id: {...} }, depts: [...] }
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const DEFAULT_DEPTS = ['지원팀', '생산팀', '영업팀', '관리팀', '품질팀'];
const STATUS = ['예정', '진행', '완료', '보류'];
const REPEATS = ['none', 'week', 'month', 'year'];
const MAX_EVENTS = 5000;

const isDay = (v) => /^\d{4}-\d{2}-\d{2}$/.test(String(v || ''));
const isTime = (v) => v === '' || /^\d{2}:\d{2}$/.test(String(v || ''));
const str = (v, n) => String(v == null ? '' : v).trim().slice(0, n);

function create(opts) {
  const FILE = opts.file;
  const log = opts.log || (() => {});
  let events = {};
  let depts = DEFAULT_DEPTS.slice();

  function save() {
    try {
      fs.mkdirSync(path.dirname(FILE), { recursive: true });
      fs.writeFileSync(FILE, JSON.stringify({ events, depts }, null, 1));
    } catch (e) { log('일정 저장 실패: ' + e.message); }
  }
  function load() {
    try {
      const o = JSON.parse(fs.readFileSync(FILE, 'utf8'));
      events = o.events || {};
      if (Array.isArray(o.depts) && o.depts.length) depts = o.depts;
    } catch (e) { if (e.code !== 'ENOENT') log('일정 파일 읽기 실패: ' + e.message); }
  }
  load();

  // 등록·수정 공통: 들어온 값을 확인해서 일정 하나로 만든다
  function apply(raw, base, by) {
    const e = base || { id: crypto.randomBytes(6).toString('hex'), created: Date.now(), created_by: by, notes: [], occ: {} };
    if (raw.title != null) e.title = str(raw.title, 100);
    if (!e.title) throw new Error('제목을 입력하세요');
    if (raw.dept != null) e.dept = str(raw.dept, 20);
    if (raw.owner != null) e.owner = str(raw.owner, 20);
    if (raw.start != null) { if (!isDay(raw.start)) throw new Error('시작 날짜를 골라 주세요'); e.start = raw.start; }
    if (!e.start) throw new Error('시작 날짜를 골라 주세요');
    if (raw.end !== undefined) e.end = isDay(raw.end) ? raw.end : e.start;
    if (!e.end || e.end < e.start) e.end = e.start;
    if (raw.time != null) { if (!isTime(raw.time)) throw new Error('시간 형식이 올바르지 않습니다'); e.time = raw.time; }
    if (raw.time_end != null) { if (!isTime(raw.time_end)) throw new Error('시간 형식이 올바르지 않습니다'); e.time_end = raw.time_end; }
    if (raw.status != null) e.status = STATUS.includes(raw.status) ? raw.status : '예정';
    if (!e.status) e.status = '예정';
    if (raw.repeat != null) {
      const kind = REPEATS.includes(raw.repeat.kind) ? raw.repeat.kind : 'none';
      const until = isDay(raw.repeat.until) ? raw.repeat.until : '';
      e.repeat = { kind, until };
      if (kind === 'none') { e.occ = {}; }
    }
    if (!e.repeat) e.repeat = { kind: 'none', until: '' };
    if (raw.desc != null) e.desc = str(raw.desc, 2000);
    e.updated = Date.now(); e.updated_by = by;
    return e;
  }

  return {
    STATUS, REPEATS,
    all() { return Object.values(events).sort((a, b) => (a.start || '').localeCompare(b.start || '')); },
    depts() { return depts.slice(); },
    setDepts(list) {
      const out = [];
      for (const d of (Array.isArray(list) ? list : [])) { const v = str(d, 20); if (v && !out.includes(v)) out.push(v); }
      if (!out.length) throw new Error('부서를 하나 이상 남겨 주세요');
      depts = out.slice(0, 30); save();
      return depts.slice();
    },
    create(raw, by) {
      if (Object.keys(events).length >= MAX_EVENTS) throw new Error('일정이 너무 많습니다');
      const e = apply(raw, null, by);
      events[e.id] = e; save();
      return e;
    },
    update(raw, by) {
      const e = events[String(raw.id || '')];
      if (!e) throw new Error('없는 일정입니다');
      const n = apply(raw, e, by);
      events[n.id] = n; save();
      return n;
    },
    // 반복 일정의 특정 날짜만 상태를 따로 기록 (예: 9/21 회차만 완료)
    setOccurrence(id, date, status, by) {
      const e = events[String(id || '')];
      if (!e) throw new Error('없는 일정입니다');
      if (!isDay(date)) throw new Error('날짜가 올바르지 않습니다');
      if (!STATUS.includes(status)) throw new Error('상태가 올바르지 않습니다');
      if (e.repeat && e.repeat.kind !== 'none') {
        e.occ = e.occ || {};
        e.occ[date] = Object.assign({}, e.occ[date], { status, by, at: Date.now() });
      } else { e.status = status; }
      e.updated = Date.now(); e.updated_by = by; save();
      return e;
    },
    addNote(id, date, text, by) {
      const e = events[String(id || '')];
      if (!e) throw new Error('없는 일정입니다');
      const t = str(text, 1000);
      if (!t) throw new Error('메모 내용을 입력하세요');
      e.notes = e.notes || [];
      if (e.notes.length >= 200) e.notes.shift();
      const note = { id: crypto.randomBytes(4).toString('hex'), date: isDay(date) ? date : e.start, text: t, by, at: Date.now() };
      e.notes.push(note); e.updated = Date.now(); save();
      return { event: e, note };
    },
    delNote(id, noteId) {
      const e = events[String(id || '')];
      if (!e) throw new Error('없는 일정입니다');
      e.notes = (e.notes || []).filter((n) => n.id !== noteId);
      save();
      return e;
    },
    remove(id) {
      if (!events[String(id || '')]) throw new Error('없는 일정입니다');
      delete events[String(id)]; save();
    },
    // 반복 일정에서 하루만 빼기 (그 날은 안 함)
    skip(id, date) {
      const e = events[String(id || '')];
      if (!e) throw new Error('없는 일정입니다');
      if (!isDay(date)) throw new Error('날짜가 올바르지 않습니다');
      e.occ = e.occ || {};
      e.occ[date] = Object.assign({}, e.occ[date], { skip: true });
      e.updated = Date.now(); save();
      return e;
    },
  };
}

module.exports = { create, STATUS, DEFAULT_DEPTS };
