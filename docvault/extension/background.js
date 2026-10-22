// DocVault 웹 첨부 보호 — 백그라운드 서비스 워커.
//
// 이 확장은 "지금 보는 사이트가 어디인지"만 브라우저에서 알 수 있다. "이 파일이
// 반출 승인된 파일인지"는 PC의 DocVault 에이전트가 127.0.0.1 로컬 서비스로
// 알려준다. 백그라운드가 그 로컬 서비스를 찾아 정책/허용여부를 받아 온다.

"use strict";

// 에이전트가 여는 포트 범위(cmd/agent/upload_oracle.go 와 일치해야 함).
const PORTS = [29614, 29615, 29616, 29617, 29618, 29619];
const TTL_MS = 4000;

// 마지막으로 확인한 정책. enabled/allowDomains 는 로컬 서비스를 못 찾아도
// 직전 값을 유지한다(잠깐 끊겼을 때 안전하게 차단 유지).
let cache = {
  at: 0,
  base: null,
  reachable: false,
  policy: { enabled: false, allowDomains: [], loggedIn: false },
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
  // 못 찾음: 시간만 갱신하고 직전 정책을 유지한다.
  cache = { at: now, base: cache.base, reachable: false, policy: cache.policy };
  return cache;
}

function normalizePolicy(p) {
  return {
    enabled: !!p.enabled,
    allowDomains: Array.isArray(p.allowDomains) ? p.allowDomains.map((d) => String(d).toLowerCase()) : [],
    loggedIn: !!p.loggedIn,
  };
}

function hostExcepted(host, domains) {
  host = (host || "").toLowerCase();
  return (domains || []).some((d) => d && (host === d || host.endsWith("." + d)));
}

async function checkFiles(host, files) {
  const c = await refresh();
  const pol = c.policy;
  if (!pol.enabled) return { allow: true };
  if (hostExcepted(host, pol.allowDomains)) return { allow: true };
  if (!c.reachable) {
    // 차단이 켜져 있었는데 에이전트에 연결이 안 됨 → 안전하게 차단.
    return { allow: false, reason: "DocVault 에이전트에 연결할 수 없어 첨부가 제한됩니다. 잠시 후 다시 시도하세요." };
  }
  if (!pol.loggedIn) {
    return { allow: false, reason: "DocVault에 로그인되어 있지 않아 웹 첨부가 제한됩니다. 작업 표시줄의 DocVault 아이콘에서 로그인하세요." };
  }
  for (const f of files || []) {
    const r = await fetchJSON(
      c.base + "/dv-upload/check",
      { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ sha: f.sha || "", size: f.size || 0 }) },
      2500
    );
    if (!r) return { allow: false, reason: "첨부 확인에 실패했습니다. 잠시 후 다시 시도하세요." };
    if (!r.allow) return { allow: false, reason: r.reason || "반출 승인된 파일만 웹에 첨부할 수 있습니다.", blocked: f.name || "" };
  }
  return { allow: true };
}

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (!msg) return;
  if (msg.type === "policy") {
    refresh().then((c) => sendResponse({ enabled: c.policy.enabled, allowDomains: c.policy.allowDomains }));
    return true; // async
  }
  if (msg.type === "gate") {
    // 이 사이트에서 파일을 검사해야 하는가? (꺼짐/예외 사이트면 아니오)
    refresh().then((c) => {
      const pol = c.policy;
      const manage = pol.enabled && !hostExcepted(msg.host, pol.allowDomains);
      sendResponse({ manage: manage });
    });
    return true; // async
  }
  if (msg.type === "check") {
    checkFiles(msg.host, msg.files).then(sendResponse);
    return true; // async
  }
});
