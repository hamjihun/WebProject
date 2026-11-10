'use strict';
// 커밋 전 문법 검사 (Windows·Linux 공통):  node monitor/tools/check.js
//  1) 수집기·경품 추첨 .js  node --check
//  2) 화면 html 의 인라인 <script> 와 common.js  (2026-09-14 템플릿 한 줄 오류로 화면 전체가 멈춘 적 있음)
//  3) 에이전트 PowerShell(agent/win/*.ps1)  Parser::ParseFile  (Windows 는 powershell.exe, Linux 는 /opt/pwsh/pwsh 가 있을 때만)
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const M = path.join(ROOT, 'monitor');
let bad = 0;
const ok = (m) => console.log('  OK  ' + m);
const ng = (m, e) => { bad++; console.log('  NG  ' + m + '\n      ' + String((e && e.message) || e).split('\n').slice(0, 4).join('\n      ')); };
const ls = (dir, re) => (fs.existsSync(dir) ? fs.readdirSync(dir).filter((f) => re.test(f)).map((f) => path.join(dir, f)) : []);
const rel = (f) => path.relative(ROOT, f);

console.log('1) JavaScript');
for (const f of [...ls(M, /\.js$/), ...ls(path.join(ROOT, 'event'), /\.js$/), ...ls(path.join(M, 'agent'), /\.js$/), ...ls(path.join(M, 'tools'), /\.js$/)]) {
  try { execFileSync(process.execPath, ['--check', f], { stdio: 'pipe' }); ok(rel(f)); } catch (e) { ng(rel(f), e.stderr ? e.stderr.toString() : e); }
}

console.log('2) 화면 (html 인라인 스크립트, common.js)');
for (const f of [...ls(path.join(M, 'public'), /\.html$/), ...ls(path.join(ROOT, 'event', 'public'), /\.html$/)]) {
  const s = fs.readFileSync(f, 'utf8');
  let n = 0;
  try { for (const m of s.matchAll(/<script>([\s\S]*?)<\/script>/g)) { n++; new Function(m[1]); } ok(`${rel(f)} (스크립트 ${n}개)`); } catch (e) { ng(rel(f), e); }
}
const cj = path.join(M, 'public', 'common.js');
if (fs.existsSync(cj)) { try { new Function(fs.readFileSync(cj, 'utf8')); ok(rel(cj)); } catch (e) { ng(rel(cj), e); } }

console.log('3) PowerShell (agent/win)');
const ps = process.platform === 'win32' ? 'powershell.exe' : (fs.existsSync('/opt/pwsh/pwsh') ? '/opt/pwsh/pwsh' : null);
const psFiles = ls(path.join(M, 'agent', 'win'), /\.ps1$/);
if (!ps) console.log('  --  PowerShell 이 없어 건너뜀 (Linux 는 /opt/pwsh/pwsh 필요)');
else {
  for (const f of psFiles) {
    const cmd = `$e=$null; [void][System.Management.Automation.Language.Parser]::ParseFile('${f.replace(/'/g, "''")}', [ref]$null, [ref]$e); if ($e.Count) { $e | ForEach-Object { $_.Message + ' (' + $_.Extent.StartLineNumber + '행)' }; exit 1 }`;
    try { execFileSync(ps, ['-NoProfile', '-NonInteractive', '-Command', cmd], { stdio: 'pipe' }); ok(rel(f)); } catch (e) { ng(rel(f), (e.stdout || '').toString() || e); }
  }
}

console.log(bad ? `\n문제 ${bad}건 — 고친 뒤 다시 실행하세요` : '\n모두 통과');
process.exit(bad ? 1 : 0);
