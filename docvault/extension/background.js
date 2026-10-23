// DocVault 웹 첨부 보호 — 백그라운드 서비스 워커.
//
// 이 확장은 "지금 보는 사이트가 어디인지"만 브라우저에서 알 수 있다. 정책(끄기/
// 기록만/차단)과 "이 파일이 반출 승인된 파일인지"는 PC의 DocVault 에이전트가
// 127.0.0.1 로컬 서비스로 알려준다. 첨부 사실은 에이전트가 서버 감사 로그에
// 남긴다(기록만·차단 모드 공통).

"use strict";

// 에이전트가 여는 포트 범위(cmd/agent/upload_oracle.go 와 일치해야 함).
const PORTS = [29614, 29615, 29616, 29617, 29618, 29619];
const TTL_MS = 4000;

// 모드: 0=끄기, 1=기록만, 2=차단.
let cache = {
  at: 0,
  base: null,
  reachable: false,
  policy: { mode: 0, allowDomains: [], loggedIn: false },
};

async function fetchJSON(url, opts, timeoutMs) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), timeoutMs || 1500);
  try {
    const r = await fetch(url, Object.assign({ signal: ctrl.signal, cache: "no-store" }, opts || {}));
    if (!r.ok) return null;
    return await r.json();
  } catch (e) {
    return null;
  } finally {
    clearTimeout(t);
  }
}

async function refresh() {
  const now = Date.now();
  if (now - cache.at < TTL_MS) return cache;
  const bases = [];
  if (cache.base) bases.push(cache.base);
  for (const p of PORTS) {
    const b = "http://127.0.0.1:" + p;
    if (b !== cache.base) bases.push(b);
  }
  for (const base of bases) {
    const pol = await fetchJSON(base + "/dv-upload/policy", null, 1200);
    if (pol) {
      cache = { at: now, base: base, reachable: true, policy: normalizePolicy(pol) };
      return cache;
    }
  }
  cache = { at: now, base: cache.base, reachable: false, policy: cache.policy };
  return cache;
}

function normalizePolicy(p) {
  return {
    mode: p.mode | 0,
    allowDomains: Array.isArray(p.allowDomains) ? p.allowDomains.map((d) => String(d).toLowerCase()) : [],
    loggedIn: !!p.loggedIn,
  };
}

// checkFiles asks the agent about each file; the agent also records it. In log
// mode nothing is blocked; in block mode non-approved files on non-exception
// sites are blocked.
async function checkFiles(host, files) {
  const c = await refresh();
  const mode = c.policy.mode;
  if (mode === 0) return { allow: true };
  if (!c.reachable) {
    if (mode >= 2) return { allow: false, reason: "DocVault 에이전트에 연결할 수 없어 첨부가 제한됩니다. 잠시 후 다시 시도하세요." };
    return { allow: true }; // 기록만 모드: 로그만 못 남기고 통과
  }
  if (!c.policy.loggedIn) {
    if (mode >= 2) return { allow: false, reason: "DocVault에 로그인되어 있지 않아 웹 첨부가 제한됩니다. 작업 표시줄의 DocVault 아이콘에서 로그인하세요." };
    return { allow: true };
  }
  for (const f of files || []) {
    const r = await fetchJSON(
      c.base + "/dv-upload/check",
      { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ sha: f.sha || "", size: f.size || 0, name: f.name || "", domain: host }) },
      2500
    );
    if (!r) {
      if (mode >= 2) return { allow: false, reason: "첨부 확인에 실패했습니다. 잠시 후 다시 시도하세요." };
      continue; // 기록만: 로그 실패해도 통과
    }
    if (!r.allow) return { allow: false, reason: r.reason || "반출 승인된 파일만 웹에 첨부할 수 있습니다.", blocked: f.name || "" };
  }
  return { allow: true };
}

// Heartbeat: periodically contact the agent so it knows the extension is alive.
// If this stops (extension disabled/removed), the agent blocks the browser from
// reading drive files (감시 스위치). refresh() itself hits the agent.
chrome.alarms.create("dv-heartbeat", { periodInMinutes: 1 });
chrome.alarms.onAlarm.addListener((a) => {
  if (a.name === "dv-heartbeat") {
    cache.at = 0; // force a fresh contact
    refresh();
  }
});
refresh();

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (!msg) return;
  if (msg.type === "policy") {
    refresh().then((c) => sendResponse({ mode: c.policy.mode, allowDomains: c.policy.allowDomains }));
    return true;
  }
  if (msg.type === "gate") {
    refresh().then((c) => sendResponse({ manage: c.policy.mode >= 1, mode: c.policy.mode }));
    return true;
  }
  if (msg.type === "check") {
    checkFiles(msg.host, msg.files).then(sendResponse);
    return true;
  }
});
