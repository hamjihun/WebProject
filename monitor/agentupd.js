// 에이전트 버전 관리 — IMS 서버가 Windows 에이전트 설치 파일을 버전별로 보관하고, "배포 버전"을 정하면
// 에이전트가 다음 전송 응답에서 그 버전을 받아 스스로 재설치한다 (구버전을 고르면 되돌리기).
// data/agent-versions/index.json = { versions:[{ver,sha256,size,added,note,file}], target:{ver,n,at,by,prev}, pins:{호스트:{ver,n}} }
//   pins[host].ver: 특정 버전에 고정, 'none' = 이 서버는 업데이트 안 함. n = 배포할 때마다 늘어나는 번호(같은 시도를 되풀이하지 않게)
// 새 설치 파일은 수집기가 시작할 때 dist/IMS-Monitoring-Agent-Setup.exe 를 보고 (버전은 agent/win/installer.nsi) 자동으로 목록에 넣는다.
// dist/old/*.exe 에 둔 예전 설치 파일도 (exe 안의 버전으로) 넣는다. 화면에서 지운 것은 removed 에 기억해 다시 넣지 않는다.
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const MIN_SELF_UPDATE = '1.9.0';             // 이 버전부터 스스로 업데이트 가능 (그 전 버전은 한 번은 직접 설치)
function cmpVer(a, b) {
  const pa = String(a || '').split('.').map((x) => parseInt(x, 10) || 0), pb = String(b || '').split('.').map((x) => parseInt(x, 10) || 0);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) { const d = (pa[i] || 0) - (pb[i] || 0); if (d) return d; }
  return 0;
}
const okVer = (v) => /^\d{1,3}(\.\d{1,4}){1,3}$/.test(String(v || ''));
// 설치 파일(.exe) 안의 버전 정보(ProductVersion)를 읽는다 — NSIS 의 VIAddVersionKey ProductVersion
function exeVer(buf) {
  for (const off of [0, 1]) { const m = /ProductVersion\u0000+(\d+(?:\.\d+){1,3})/.exec(buf.slice(off).toString('utf16le')); if (m) return m[1]; }
  return '';
}

function create({ dir, distExe, nsiFile, log = console.log }) {
  const IDX = path.join(dir, 'index.json');
  let db = { versions: [], target: null, pins: {}, removed: [] };
  try { const v = JSON.parse(fs.readFileSync(IDX, 'utf8')); if (v && Array.isArray(v.versions)) db = { versions: v.versions, target: v.target || null, pins: v.pins || {}, removed: Array.isArray(v.removed) ? v.removed : [] }; }
  catch (e) { if (e.code !== 'ENOENT') log('에이전트 버전 목록 읽기 실패: ' + e.message); }
  function save() {
    try { fs.mkdirSync(dir, { recursive: true }); fs.writeFileSync(IDX + '.tmp', JSON.stringify(db, null, 1)); fs.renameSync(IDX + '.tmp', IDX); }
    catch (e) { log('에이전트 버전 목록 저장 실패: ' + e.message); }
  }
  const find = (ver) => db.versions.find((x) => x.ver === ver);

  function add(ver, buf, note, by) {
    if (!ver && Buffer.isBuffer(buf)) ver = exeVer(buf);           // 비우면 파일 안의 버전 사용
    if (!okVer(ver)) throw new Error('버전은 1.9.0 처럼 숫자와 점으로 적어 주세요');
    if (!Buffer.isBuffer(buf) || buf.length < 50000 || buf.slice(0, 2).toString() !== 'MZ') throw new Error('설치 파일(.exe)이 아닙니다');
    const sha256 = crypto.createHash('sha256').update(buf).digest('hex');
    const same = db.versions.find((x) => x.sha256 === sha256);
    if (same) return { ...same, existed: true };
    if (find(ver)) throw new Error(`${ver} 버전이 이미 있습니다 (내용이 다름). 먼저 지우거나 다른 버전 번호를 쓰세요`);
    const file = `IMS-Monitoring-Agent-Setup-${ver}.exe`;
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, file), buf);
    const v = { ver, sha256, size: buf.length, added: Date.now(), note: String(note || '').slice(0, 200), by: String(by || '').slice(0, 40), file };
    db.versions.push(v); db.versions.sort((a, b) => cmpVer(b.ver, a.ver)); save();
    log(`[에이전트] 버전 등록: ${ver} (${Math.round(buf.length / 1024)}KB)`);
    return v;
  }
  // 수집기 시작 때: 배포 폴더의 설치 파일을 목록에 넣는다
  function scanDist() {
    try {
      if (!fs.existsSync(distExe) || !fs.existsSync(nsiFile)) return;
      const m = /!define\s+VERSION\s+"([^"]+)"/.exec(fs.readFileSync(nsiFile, 'utf8'));
      if (!m || !okVer(m[1])) return;
      const buf = fs.readFileSync(distExe);
      const sha = crypto.createHash('sha256').update(buf).digest('hex');
      if (db.versions.some((x) => x.sha256 === sha)) return;
      let ver = m[1]; if (find(ver)) ver = `${ver}.${db.versions.filter((x) => x.ver.startsWith(m[1] + '.')).length + 1}`;   // 같은 번호인데 내용이 다르면 1.9.0.1 처럼
      add(ver, buf, '배포 폴더(dist)에서 자동 등록', '수집기');
    } catch (e) { log('[에이전트] 배포 폴더 설치 파일 등록 실패: ' + e.message); }
    try {                                                     // 예전 버전 (dist/old)
      const od = path.join(path.dirname(distExe), 'old');
      for (const f of fs.existsSync(od) ? fs.readdirSync(od).filter((x) => /\.exe$/i.test(x)) : []) {
        const buf = fs.readFileSync(path.join(od, f)), sha = crypto.createHash('sha256').update(buf).digest('hex');
        if (db.versions.some((x) => x.sha256 === sha) || db.removed.includes(sha)) continue;
        const ver = exeVer(buf); if (!okVer(ver) || find(ver)) continue;
        add(ver, buf, '예전 버전 (dist/old)', '수집기');
      }
    } catch (e) { log('[에이전트] 예전 설치 파일 등록 실패: ' + e.message); }
  }
  function remove(ver) {
    const v = find(ver); if (!v) return false;
    if (db.target && db.target.ver === ver) throw new Error('지금 배포 중인 버전은 지울 수 없습니다');
    if (Object.values(db.pins).some((p) => p.ver === ver)) throw new Error('이 버전에 고정한 서버가 있어 지울 수 없습니다');
    try { fs.unlinkSync(path.join(dir, v.file)); } catch (e) {}
    db.versions = db.versions.filter((x) => x !== v); if (!db.removed.includes(v.sha256)) db.removed.push(v.sha256); save();
    return true;
  }
  function setTarget(ver, by) {             // ver = '' 이면 배포 멈춤
    if (ver && !find(ver)) throw new Error('없는 버전입니다');
    const prev = db.target && db.target.ver;
    db.target = ver ? { ver, n: ((db.target && db.target.n) || 0) + 1, at: Date.now(), by: String(by || '').slice(0, 40), prev: prev && prev !== ver ? prev : (db.target && db.target.prev) || '' } : null;
    save(); return db.target;
  }
  function setPin(host, ver) {               // '' = 전체 배포 버전 따름, 'none' = 업데이트 안 함, 그 밖 = 그 버전 고정
    if (!ver) delete db.pins[host];
    else { if (ver !== 'none' && !find(ver)) throw new Error('없는 버전입니다'); db.pins[host] = { ver, n: ((db.pins[host] && db.pins[host].n) || 0) + 1, at: Date.now() }; }
    save(); return db.pins[host] || null;
  }
  // 이 서버가 받아야 할 버전 (없으면 null)
  function wantFor(host) {
    const p = db.pins[host];
    if (p) return p.ver === 'none' ? null : { ver: p.ver, n: 'p' + p.n };
    return db.target ? { ver: db.target.ver, n: 't' + db.target.n } : null;
  }
  const canSelf = (agent) => !!(agent && Array.isArray(agent.caps) && agent.caps.includes('update'));
  // /api/metrics 응답에 실어 보낼 업데이트 지시
  function orderFor(host, agent) {
    if (!agent || !canSelf(agent)) return null;
    const w = wantFor(host); if (!w || w.ver === agent.version) return null;
    const v = find(w.ver); if (!v) return null;
    const cur = find(agent.version);
    return { ver: v.ver, sha: v.sha256, size: v.size, n: w.n, prev: cur ? { ver: cur.ver, sha: cur.sha256 } : null };
  }
  // 화면용 상태
  function stateFor(host, agent, isWin, online) {
    const w = wantFor(host), p = db.pins[host], r = agent && agent.update;
    const base = { pin: p ? p.ver : '', want: w ? w.ver : '', result: r || null };
    if (!isWin) return { ...base, state: 'na', text: '지원 안 함 (Windows 에이전트만)' };
    if (!agent || !agent.version) return { ...base, state: 'old', text: '버전 모름' };
    if (p && p.ver === 'none') return { ...base, state: 'skip', text: '업데이트 안 함 (이 서버 제외)' };
    if (!w) return { ...base, state: 'idle', text: '배포 버전 없음' };
    if (w.ver === agent.version) return { ...base, state: 'ok', text: r && r.state === 'ok' && r.to === w.ver ? '최신 (업데이트 완료)' : '최신' };
    if (!canSelf(agent)) return { ...base, state: 'manual', text: `직접 설치 필요 (${MIN_SELF_UPDATE} 이상부터 자동)` };
    if (r && r.to === w.ver && r.state === 'running') return { ...base, state: 'run', text: '설치 중' };
    if (r && r.to === w.ver && r.state === 'rolledback') return { ...base, state: 'bad', text: `실패 → ${r.from} 로 자동 되돌림 (오른쪽 결과 참고, '다시 시도' 로 재시도)` };
    if (r && r.to === w.ver && r.state === 'failed') return { ...base, state: 'bad', text: `실패 (오른쪽 결과 참고, '다시 시도' 로 재시도)` };
    return { ...base, state: 'wait', text: online ? (cmpVer(w.ver, agent.version) < 0 ? '되돌리기 대기 (다음 전송 때 시작)' : '업데이트 대기 (다음 전송 때 시작)') : '대기 (서버 오프라인)' };
  }
  function filePath(ver) { const v = find(ver); return v ? path.join(dir, v.file) : null; }
  function info() { return { versions: db.versions.map(({ file, ...v }) => v), target: db.target, pins: db.pins, min_self: MIN_SELF_UPDATE }; }
  scanDist();
  return { add, remove, setTarget, setPin, orderFor, stateFor, filePath, info, find, scanDist };
}

module.exports = { create, cmpVer, exeVer };
