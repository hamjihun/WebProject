'use strict';
// 일정 관리 (부서별 업무 일정). 외부 패키지 없이 Node.js 내장 모듈만 사용.
// 저장 위치: data/schedule.json  { events: { id: {...} }, depts: [...] }
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const DEFAULT_DEPTS = ['지원팀', '생산팀', '영업팀', '관리팀', '품질팀'];
const STATUS = ['예정', '진행', '완료', '보류'];
const PRIOS = ['보통', '중요', '긴급'];
// 한국 공휴일 기본값. 음력 명절·대체공휴일은 해마다 달라지고 임시공휴일도 생기므로
// 화면(공휴일 관리)에서 고칠 수 있게 하고, 고치면 data/schedule.json 에 저장된다.
const DEFAULT_HOLIDAYS = {
  '2026-01-01': '신정',
  '2026-02-16': '설날 연휴', '2026-02-17': '설날', '2026-02-18': '설날 연휴',
  '2026-03-01': '삼일절', '2026-03-02': '대체공휴일',
  '2026-05-05': '어린이날', '2026-05-24': '부처님오신날', '2026-05-25': '대체공휴일',
  '2026-06-06': '현충일',
  '2026-08-15': '광복절', '2026-08-17': '대체공휴일',
  '2026-09-24': '추석 연휴', '2026-09-25': '추석', '2026-09-26': '추석 연휴', '2026-09-28': '대체공휴일',
  '2026-10-03': '개천절', '2026-10-05': '대체공휴일', '2026-10-09': '한글날',
  '2026-12-25': '성탄절',
  '2027-01-01': '신정',
  '2027-02-05': '설날 연휴', '2027-02-06': '설날', '2027-02-07': '설날 연휴', '2027-02-08': '대체공휴일',
  '2027-03-01': '삼일절',
  '2027-05-05': '어린이날', '2027-05-13': '부처님오신날',
  '2027-06-06': '현충일',
  '2027-08-15': '광복절', '2027-08-16': '대체공휴일',
  '2027-09-14': '추석 연휴', '2027-09-15': '추석', '2027-09-16': '추석 연휴',
  '2027-10-03': '개천절', '2027-10-04': '대체공휴일', '2027-10-09': '한글날', '2027-10-11': '대체공휴일',
  '2027-12-25': '성탄절', '2027-12-27': '대체공휴일',
};
const REPEATS = ['none', 'week', 'month', 'year'];
const MAX_EVENTS = 5000;

const isDay = (v) => /^\d{4}-\d{2}-\d{2}$/.test(String(v || ''));
const D = (v) => { const [y, m, d] = String(v).split('-').map(Number); return new Date(y, m - 1, d); };
const S = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
const addD = (d, n) => { const x = new Date(d); x.setDate(x.getDate() + n); return x; };
// n개월 뒤 같은 날짜 (없는 날짜면 말일)
const addMK = (base, n, dom) => { const x = new Date(base.getFullYear(), base.getMonth() + n, 1); const last = new Date(x.getFullYear(), x.getMonth() + 1, 0).getDate(); x.setDate(Math.min(dom, last)); return x; };
const isTime = (v) => v === '' || /^\d{2}:\d{2}$/.test(String(v || ''));
const str = (v, n) => String(v == null ? '' : v).trim().slice(0, n);

function create(opts) {
  const FILE = opts.file;
  const log = opts.log || (() => {});
  let events = {};
  let depts = DEFAULT_DEPTS.slice();
  let holidays = Object.assign({}, DEFAULT_HOLIDAYS);

  function save() {
    try {
      fs.mkdirSync(path.dirname(FILE), { recursive: true });
      fs.writeFileSync(FILE, JSON.stringify({ events, depts, holidays }, null, 1));
    } catch (e) { log('일정 저장 실패: ' + e.message); }
  }
  function load() {
    try {
      const o = JSON.parse(fs.readFileSync(FILE, 'utf8'));
      events = o.events || {};
      if (Array.isArray(o.depts) && o.depts.length) depts = o.depts;
      if (o.holidays && typeof o.holidays === 'object') holidays = o.holidays;   // 한 번 고치면 그 값을 쓴다
    } catch (e) { if (e.code !== 'ENOENT') log('일정 파일 읽기 실패: ' + e.message); }
  }
  load();

  // 등록·수정 공통: 들어온 값을 확인해서 일정 하나로 만든다
  function apply(raw, base, by, ownerId) {
    const e = base || { id: crypto.randomBytes(6).toString('hex'), created: Date.now(), created_by: by, owner_id: ownerId || '', notes: [], occ: {} };
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
    if (raw.prio != null) e.prio = PRIOS.includes(raw.prio) ? raw.prio : '보통';
    if (!e.prio) e.prio = '보통';
    if (raw.share != null) e.share = raw.share === 'team' ? 'team' : 'me';   // 기본은 개인 일정 (나만 보기)
    if (!e.share) e.share = 'me';
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
    STATUS, REPEATS, PRIOS,
    holidays() { return Object.assign({}, holidays); },
    setHolidays(map) {
      if (!map || typeof map !== 'object') throw new Error('공휴일 목록이 올바르지 않습니다');
      const out = {};
      for (const [k, v] of Object.entries(map)) {
        if (!isDay(k)) throw new Error(`날짜 형식이 올바르지 않습니다: ${String(k).slice(0, 20)} (2026-01-01 처럼 적어 주세요)`);
        const nm = str(v, 20); if (nm) out[k] = nm;
      }
      if (Object.keys(out).length > 400) throw new Error('공휴일이 너무 많습니다');
      holidays = out; save();
      return this.holidays();
    },
    all() { return Object.values(events).sort((a, b) => (a.start || '').localeCompare(b.start || '')); },
    get(id) { return events[String(id || '')] || null; },
    // 반복 일정을 기간 안의 날짜들로 펼친다 (화면과 같은 규칙)
    occurrences(list, from, to) {
      const out = [];
      for (const ev of list) {
        const span = Math.round((D(ev.end || ev.start) - D(ev.start)) / 86400000);
        const kind = (ev.repeat && ev.repeat.kind) || 'none';
        const push = (date) => {
          const end = S(addD(D(date), span));
          const o = (ev.occ && ev.occ[date]) || null;
          out.push({ ev, date, end, status: (o && o.status) || ev.status || '예정' });
        };
        if (kind === 'none') { if ((ev.end || ev.start) >= from && ev.start <= to) push(ev.start); continue; }
        const first = D(ev.start), dom = first.getDate();
        const until = (ev.repeat && ev.repeat.until) || to;
        let i = 0, d = first;
        while (S(d) <= until && S(d) <= to && i < 600) {
          const ds = S(d);
          if (S(addD(d, span)) >= from && !(ev.occ && ev.occ[ds] && ev.occ[ds].skip)) push(ds);
          i++;
          d = kind === 'week' ? addD(first, 7 * i) : kind === 'month' ? addMK(first, i, dom) : addMK(first, 12 * i, dom);
        }
      }
      return out.sort((a, b) => a.date.localeCompare(b.date) || (a.ev.time || '99').localeCompare(b.ev.time || '99'));
    },
    depts() { return depts.slice(); },
    setDepts(list) {
      const out = [];
      for (const d of (Array.isArray(list) ? list : [])) { const v = str(d, 20); if (v && !out.includes(v)) out.push(v); }
      if (!out.length) throw new Error('부서를 하나 이상 남겨 주세요');
      depts = out.slice(0, 30); save();
      return depts.slice();
    },
    create(raw, by, ownerId) {
      if (Object.keys(events).length >= MAX_EVENTS) throw new Error('일정이 너무 많습니다');
      const e = apply(raw, null, by, ownerId);
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
