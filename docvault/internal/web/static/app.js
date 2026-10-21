"use strict";
// DocVault web UI: file browser, trash, export (반출) requests/approvals and admin pages.

const $ = (s, el = document) => el.querySelector(s);
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const fmtSize = (n) => {
  if (n == null) return "";
  const u = ["B", "KB", "MB", "GB", "TB"]; let i = 0; n = Number(n);
  while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
  return (i ? n.toFixed(1) : n) + " " + u[i];
};
const fmtTime = (t) => {
  if (!t) return "";
  const d = new Date(t * 1000), p = (x) => String(x).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`;
};
const fmtDate = (t) => fmtTime(t).slice(0, 10);
const LEVELS = { 1: "읽기", 2: "읽기/쓰기", 3: "관리(팀장·결재)" };
const STATUS = { pending: "결재 대기", post: "후결재 대기 (반출됨)", approved: "승인", rejected: "반려", cancelled: "취소", expired: "만료" };
const ACTIONS = {
  login: "로그인", login_fail: "로그인 실패", logout: "로그아웃", read: "열람", create: "새 파일", update: "수정 저장",
  mkdir: "폴더 생성", delete: "삭제(휴지통)", move: "이동/이름변경", copy: "복사", restore_trash: "휴지통 복원",
  purge: "영구 삭제", restore_version: "이전 버전 복원", export_request: "반출 신청", export_approve: "반출 승인",
  export_reject: "반출 반려", export_cancel: "반출 신청 취소", export_download: "반출 다운로드",
  guard_block: "랜섬웨어 의심 차단", maintenance: "자동 정리",
  admin_user_create: "[관리] 사용자 생성", admin_user_update: "[관리] 사용자 변경", admin_group_create: "[관리] 그룹 생성",
  admin_group_delete: "[관리] 그룹 삭제", admin_share_create: "[관리] 드라이브 생성", admin_share_update: "[관리] 드라이브 변경",
  admin_share_delete: "[관리] 드라이브 삭제", admin_share_acl: "[관리] 권한 변경", admin_setting: "[관리] 설정 변경",
  admin_session_revoke: "[관리] 접속 강제 종료", admin_audit_export: "[관리] 로그 내보내기", agent_pair: "PC 연결", block_copy: "PC 복사 차단", block_messenger: "메신저 첨부 차단", block_upload: "웹 업로드 차단", block_custom: "프로그램 차단",
};
const CLIENTS = { drive: "가상드라이브", web: "웹", agent: "PC에이전트", system: "시스템" };

let me = null;
let drives = [];

async function api(method, url, body) {
  const opt = { method, headers: { "X-DocVault": "1" } };
  if (body !== undefined) { opt.headers["Content-Type"] = "application/json"; opt.body = JSON.stringify(body); }
  const r = await fetch(url, opt);
  let data = null;
  try { data = await r.json(); } catch (_) {}
  if (r.status === 401 && url !== "/api/login") { showLogin(); throw new Error("로그인이 필요합니다"); }
  if (!r.ok) throw new Error((data && data.error) || "요청 실패 (" + r.status + ")");
  return data;
}

function toast(msg, err) {
  const t = $("#toast");
  t.textContent = msg; t.className = "toast" + (err ? " err" : "");
  clearTimeout(toast.timer); toast.timer = setTimeout(() => t.classList.add("hidden"), 3500);
}
const guard = (fn) => async (...a) => { try { await fn(...a); } catch (e) { toast(e.message, true); } };

function openModal(html, bind) {
  $("#modalBox").innerHTML = html;
  $("#modal").classList.remove("hidden");
  $("#modalBox").querySelectorAll("[data-close]").forEach((b) => b.onclick = closeModal);
  if (bind) bind($("#modalBox"));
}
function closeModal() { $("#modal").classList.add("hidden"); $("#modalBox").innerHTML = ""; }
$("#modal").addEventListener("mousedown", (e) => { if (e.target.id === "modal") closeModal(); });

// ---------- login ----------
function showLogin() {
  $("#app").classList.add("hidden");
  $("#login").classList.remove("hidden");
  if (location.hash.startsWith("#/pair/")) $("#loginError").textContent = "PC를 연결하려면 먼저 로그인하세요";
  fetch("/api/setup-available").then((r) => r.json()).then((d) => $("#setupLink").classList.toggle("hidden", !d.available)).catch(() => {});
}
$("#loginForm").addEventListener("submit", async (e) => {
  e.preventDefault();
  const f = e.target;
  $("#loginError").textContent = "";
  try {
    await api("POST", "/api/login", { username: f.username.value, password: f.password.value, kind: "web", device: navigator.userAgent.slice(0, 80) });
    f.password.value = "";
    await start();
  } catch (err) { $("#loginError").textContent = err.message; }
});
$("#logoutBtn").onclick = guard(async () => { await api("POST", "/api/logout"); location.hash = ""; showLogin(); });

async function start() {
  try { me = await api("GET", "/api/me"); } catch (_) { showLogin(); return; }
  $("#login").classList.add("hidden");
  $("#app").classList.remove("hidden");
  $("#whoName").textContent = me.displayName ? `${me.displayName} (${me.username})` : me.username;
  await loadSide();
  route();
}

async function loadSide() {
  drives = await api("GET", "/api/me/drives");
  let pending = 0;
  try { pending = (await api("GET", "/api/exports?scope=inbox")).filter((e) => e.canApprove).length; } catch (_) {}
  const canApprove = me.isAdmin || drives.some((d) => d.level >= 3);
  let h = "<h4>내 드라이브</h4>";
  for (const d of drives) {
    h += `<a href="#/files/${encodeURIComponent(d.name)}/" data-nav="files/${esc(d.name)}"><span><span class="letter">${esc(d.driveLetter ? d.driveLetter + ":" : "")}</span>${esc(d.name)}</span></a>`;
  }
  if (!drives.length) h += `<p class="muted" style="padding:0 10px">접근 가능한 드라이브가 없습니다</p>`;
  h += "<h4>반출</h4>";
  h += `<a href="#/exports" data-nav="exports">내 반출 신청</a>`;
  if (canApprove) h += `<a href="#/approvals" data-nav="approvals">반출 결재함 ${pending ? `<span class="badge">${pending}</span>` : ""}</a>`;
  if (me.isAdmin) {
    h += "<h4>관리자</h4>";
    h += `<a href="#/admin/overview" data-nav="admin/overview">현황</a>`;
    h += `<a href="#/admin/users" data-nav="admin/users">사용자</a>`;
    h += `<a href="#/admin/groups" data-nav="admin/groups">그룹(팀)</a>`;
    h += `<a href="#/admin/shares" data-nav="admin/shares">드라이브·권한</a>`;
    h += `<a href="#/admin/storage" data-nav="admin/storage">저장소 사용량</a>`;
    h += `<a href="#/admin/audit" data-nav="admin/audit">감사 로그</a>`;
    h += `<a href="#/admin/sessions" data-nav="admin/sessions">접속 PC·세션</a>`;
    h += `<a href="#/admin/backup" data-nav="admin/backup">백업·복구</a>`;
    h += `<a href="#/admin/settings" data-nav="admin/settings">설정</a>`;
  }
  h += `<h4>도움</h4><a href="/download/setup">💻 PC 프로그램 설치</a>`;
  $("#side").innerHTML = h;
}

function markNav(key) {
  document.querySelectorAll("#side a").forEach((a) => a.classList.toggle("active", key.startsWith(a.dataset.nav)));
}

// ---------- routing ----------
window.addEventListener("hashchange", () => me && route());
function route() {
  const h = decodeURIComponent(location.hash.replace(/^#\/?/, ""));
  const main = $("#main");
  if (!h) {
    if (me.isAdmin) { location.hash = "#/admin/overview"; return; }
    if (drives.length) { location.hash = "#/files/" + encodeURIComponent(drives[0].name) + "/"; return; }
    main.innerHTML = `<h2>환영합니다</h2><p class="muted">관리자에게 드라이브 권한을 요청하세요.</p>`;
    return;
  }
  markNav(h);
  const [page, ...rest] = h.split("/");
  const views = {
    files: () => viewFiles(rest[0], "/" + rest.slice(1).join("/")),
    trash: () => viewTrash(rest[0]),
    exports: viewMyExports,
    pair: () => viewPair(rest[0]),
    approvals: viewApprovals,
    admin: () => ({ overview: adminOverview, users: adminUsers, groups: adminGroups, shares: adminShares, storage: adminStorage, audit: adminAudit, sessions: adminSessions, backup: adminBackup, settings: adminSettings }[rest[0]] || (() => {}))(),
  };
  (views[page] ? guard(views[page]) : () => {})();
}

// ---------- PC pairing ----------
async function viewPair(code) {
  const main = $("#main");
  let info;
  try { info = await api("GET", `/api/agent/pair/${encodeURIComponent(code)}`); }
  catch (e) { main.innerHTML = `<div class="card pair-card"><h2>PC 연결</h2><p class="error">${esc(e.message)}</p></div>`; return; }
  main.innerHTML = `<div class="card pair-card">
    <h2>💻 PC 연결 요청</h2>
    <div class="device">${esc(info.device || "이름 없는 PC")}</div>
    <div class="muted">IP ${esc(info.ip)}</div>
    <p>이 PC에서 <b>${esc(me.displayName || me.username)}</b> 계정으로 문서 드라이브를 사용합니다.<br>
    <span class="muted">본인이 사용하는 PC가 아니면 연결하지 마세요.</span></p>
    <div class="toolbar"><button id="pairOk" class="primary">이 PC 연결</button><button id="pairNo">취소</button></div></div>`;
  $("#pairNo").onclick = () => { location.hash = ""; };
  $("#pairOk").onclick = guard(async () => {
    await api("POST", `/api/agent/pair/${encodeURIComponent(code)}/approve`);
    main.innerHTML = `<div class="card pair-card"><h2>✅ 연결되었습니다</h2>
      <p>잠시 후 PC의 <b>내 PC</b>에 문서 드라이브가 나타납니다.<br>이 창은 닫아도 됩니다.</p></div>`;
  });
}

// ---------- files ----------
const iconFor = (n) => n.isDir ? "📁" : (/\.(xlsx?|csv)$/i.test(n.name) ? "📊" : /\.(docx?|hwpx?|txt)$/i.test(n.name) ? "📄" : /\.(pptx?)$/i.test(n.name) ? "📽" : /\.pdf$/i.test(n.name) ? "📕" : /\.(dwg|dxf|step|stp|igs)$/i.test(n.name) ? "📐" : "📎");
const joinP = (a, b) => (a.endsWith("/") ? a : a + "/") + b;
const filesHash = (share, p) => "#/files/" + encodeURIComponent(share) + p.split("/").map(encodeURIComponent).join("/");

async function viewFiles(share, path) {
  path = path.replace(/\/+$/, "") || "/";
  const d = drives.find((x) => x.name === share);
  if (!d) { $("#main").innerHTML = `<p class="empty">드라이브를 찾을 수 없습니다</p>`; return; }
  const list = await api("GET", `/api/files?share=${encodeURIComponent(share)}&path=${encodeURIComponent(path)}`);
  const canWrite = d.level >= 2 && !me.writeBlocked;
  const parts = path.split("/").filter(Boolean);
  let crumbs = `<a data-go="/">${esc(share)}</a>`;
  parts.forEach((p, i) => { crumbs += `<span class="sep">›</span><a data-go="/${esc(parts.slice(0, i + 1).join("/"))}">${esc(p)}</a>`; });
  const usage = d.quotaBytes ? `<span class="usage"><div style="width:${Math.min(100, d.used / d.quotaBytes * 100)}%"></div></span> ${fmtSize(d.used)} / ${fmtSize(d.quotaBytes)}` : `사용 ${fmtSize(d.used)}`;
  let h = `<h2>${esc(d.driveLetter ? d.driveLetter + ": " : "")}${esc(share)}</h2>
    <div class="muted">${LEVELS[d.level]} 권한 · ${usage}</div>
    ${me.writeBlocked ? `<div class="warnbox">⚠ 짧은 시간에 많은 파일이 수정/삭제되어(랜섬웨어 의심) 쓰기가 차단되었습니다. 관리자에게 문의하세요.</div>` : ""}
    <div class="toolbar"><div class="crumbs grow">${crumbs}</div>
      ${canWrite ? `<button id="upBtn" class="primary">업로드</button><button id="mkBtn">새 폴더</button>` : ""}
      ${d.level >= 2 ? `<button id="trashBtn">🗑 휴지통</button>` : ""}
      <input type="file" id="upInput" multiple class="hidden"></div>`;
  if (!list.length) h += `<div class="card empty">폴더가 비어 있습니다</div>`;
  else {
    h += `<table><thead><tr><th>이름</th><th class="num hide-sm">크기</th><th class="hide-sm">수정일</th><th></th></tr></thead><tbody>`;
    for (const n of list) {
      h += `<tr data-name="${esc(n.name)}" data-dir="${n.isDir ? 1 : 0}">
        <td class="name-cell"><span class="icon">${iconFor(n)}</span>${esc(n.name)}</td>
        <td class="num hide-sm">${n.isDir ? "" : fmtSize(n.size)}</td>
        <td class="hide-sm">${fmtTime(n.modifiedAt)}</td>
        <td class="actions">
          ${n.isDir ? "" : `<button class="small" data-act="versions">버전</button> <button class="small" data-act="export">반출 신청</button>`}
          ${canWrite ? ` <button class="small" data-act="rename">이름변경</button> <button class="small danger" data-act="delete">삭제</button>` : ""}
        </td></tr>`;
    }
    h += `</tbody></table>`;
  }
  h += `<p class="muted" style="margin-top:14px">💡 PC에서는 ${d.driveLetter ? `<b>${esc(d.driveLetter)}:</b> 드라이브로` : "가상 드라이브로"} 바로 열고 저장할 수 있습니다. 저장할 때마다 이전 버전이 자동으로 보관됩니다.</p>`;
  const main = $("#main");
  main.innerHTML = h;

  main.querySelectorAll("[data-go]").forEach((a) => a.onclick = () => location.hash = filesHash(share, a.dataset.go));
  main.querySelectorAll("tr[data-name]").forEach((tr) => {
    const name = tr.dataset.name, p = joinP(path, name);
    if (tr.dataset.dir === "1") tr.querySelector(".name-cell").onclick = () => location.hash = filesHash(share, p);
    tr.querySelectorAll("[data-act]").forEach((b) => b.onclick = guard(() => fileAction(b.dataset.act, share, p, name)));
  });
  if ($("#trashBtn")) $("#trashBtn").onclick = () => location.hash = "#/trash/" + encodeURIComponent(share);
  if (canWrite) {
    $("#mkBtn").onclick = () => openModal(`<h3>새 폴더</h3><form class="form"><input name="n" placeholder="폴더 이름" required autofocus>
      <div class="buttons"><button type="button" data-close>취소</button><button class="primary">만들기</button></div></form>`, (box) => {
      box.querySelector("form").onsubmit = guard(async (e) => {
        e.preventDefault();
        await api("POST", "/api/files/mkdir", { share, path: joinP(path, e.target.n.value.trim()) });
        closeModal(); route();
      });
    });
    $("#upBtn").onclick = () => $("#upInput").click();
    $("#upInput").onchange = guard(async (e) => {
      const files = [...e.target.files]; if (!files.length) return;
      const fd = new FormData(); files.forEach((f) => fd.append("file", f, f.name));
      toast(`${files.length}개 파일 업로드 중...`);
      const r = await fetch(`/api/files/upload?share=${encodeURIComponent(share)}&path=${encodeURIComponent(path)}`, { method: "POST", body: fd, headers: { "X-DocVault": "1" } });
      const data = await r.json().catch(() => ({}));
      if (!r.ok) throw new Error(data.error || "업로드 실패");
      toast(`${data.saved.length}개 파일을 저장했습니다`);
      await loadSide(); route();
    });
  }
}

async function fileAction(act, share, p, name) {
  if (act === "delete") {
    if (!confirm(`'${name}'을(를) 휴지통으로 옮길까요?\n(휴지통에서 보관 기간 동안 복원할 수 있습니다)`)) return;
    await api("POST", "/api/files/delete", { share, path: p });
    toast("휴지통으로 옮겼습니다"); route();
  } else if (act === "rename") {
    const nn = prompt("새 이름", name);
    if (!nn || nn === name) return;
    await api("POST", "/api/files/rename", { share, path: p, newName: nn.trim() });
    route();
  } else if (act === "versions") {
    const vers = await api("GET", `/api/files/versions?share=${encodeURIComponent(share)}&path=${encodeURIComponent(p)}`);
    const d = drives.find((x) => x.name === share);
    let h = `<h3>버전 기록 – ${esc(name)}</h3><table><thead><tr><th>#</th><th>저장 시각</th><th>저장한 사람</th><th class="num">크기</th><th></th></tr></thead><tbody>`;
    vers.forEach((v, i) => {
      h += `<tr><td>${vers.length - i}</td><td>${fmtTime(v.createdAt)}${v.note ? `<br><span class="muted">${esc(v.note)}</span>` : ""}</td><td>${esc(v.createdBy)}</td><td class="num">${fmtSize(v.size)}</td>
        <td class="actions">${v.current ? `<span class="muted">현재</span>` : (d.level >= 2 && !me.writeBlocked ? `<button class="small" data-v="${v.id}">이 버전으로 복원</button>` : "")}</td></tr>`;
    });
    h += `</tbody></table><div class="form"><div class="buttons"><button data-close>닫기</button></div></div>`;
    openModal(h, (box) => box.querySelectorAll("[data-v]").forEach((b) => b.onclick = guard(async () => {
      if (!confirm("이 버전을 현재 버전으로 복원할까요? (지금 버전도 기록에 남습니다)")) return;
      await api("POST", "/api/files/versions/restore", { share, path: p, id: Number(b.dataset.v) });
      closeModal(); toast("복원했습니다"); route();
    })));
  } else if (act === "export") {
    openModal(`<h3>반출 신청</h3><p><b>${esc(name)}</b><br><span class="muted">${esc(share)}:${esc(p)}</span></p>
      <p class="muted">팀장(드라이브 관리자) 승인 후 정해진 기간 동안 다운로드할 수 있습니다. 신청 시점의 파일 버전이 반출됩니다.</p>
      <form class="form"><label>반출 사유<textarea name="reason" rows="3" required placeholder="예: A사 견적 제출용"></textarea></label>
      <label class="row"><input type="checkbox" name="post"> <span><b>후결재</b> — 지금 바로 개인문서함\\반출 폴더에 넣고, 결재는 나중에 받습니다 (반려되면 반출 폴더에서 회수)</span></label>
      <div class="buttons"><button type="button" data-close>취소</button><button class="primary">신청</button></div></form>`, (box) => {
      box.querySelector("form").onsubmit = guard(async (e) => {
        e.preventDefault();
        const post = e.target.post.checked;
        await api("POST", "/api/exports", { share, path: p, reason: e.target.reason.value, post });
        closeModal(); toast(post ? "개인문서함의 [반출] 폴더에 넣었습니다 (후결재)" : "반출 신청했습니다. 승인되면 개인문서함의 [반출] 폴더에 들어갑니다");
      });
    });
  }
}

async function viewTrash(share) {
  const d = drives.find((x) => x.name === share);
  const list = await api("GET", `/api/trash?share=${encodeURIComponent(share)}`);
  let h = `<h2>🗑 휴지통 – ${esc(share)}</h2><div class="toolbar"><button id="backBtn">← 드라이브로</button></div>`;
  if (!list.length) h += `<div class="card empty">휴지통이 비어 있습니다</div>`;
  else {
    h += `<table><thead><tr><th>이름</th><th>원래 위치</th><th class="num">크기</th><th>삭제</th><th>영구 삭제 예정</th><th></th></tr></thead><tbody>`;
    for (const t of list) {
      h += `<tr><td>${t.isDir ? "📁" : "📄"} ${esc(t.name)}</td><td class="muted">${esc(t.origPath)}</td><td class="num">${fmtSize(t.size)}</td>
        <td>${fmtTime(t.deletedAt)}<br><span class="muted">${esc(t.deletedBy)}</span></td><td>${fmtDate(t.purgeAt)}</td>
        <td class="actions"><button class="small" data-r="${t.id}">복원</button>${d && d.level >= 3 ? ` <button class="small danger" data-p="${t.id}">영구삭제</button>` : ""}</td></tr>`;
    }
    h += `</tbody></table>`;
  }
  $("#main").innerHTML = h;
  $("#backBtn").onclick = () => location.hash = filesHash(share, "/");
  $("#main").querySelectorAll("[data-r]").forEach((b) => b.onclick = guard(async () => {
    const r = await api("POST", "/api/trash/restore", { share, id: Number(b.dataset.r) });
    toast("복원했습니다: " + r.path); route();
  }));
  $("#main").querySelectorAll("[data-p]").forEach((b) => b.onclick = guard(async () => {
    if (!confirm("영구 삭제하면 되살릴 수 없습니다. 계속할까요?")) return;
    await api("POST", "/api/trash/purge", { share, id: Number(b.dataset.p) });
    route();
  }));
}

// ---------- exports ----------
function exportRow(e, mode) {
  let act = "";
  if (mode === "mine") {
    if (e.canDownload) act = `<button class="small primary" data-dl="${e.id}">다운로드 (${e.downloadCount}/${e.maxDownloads})</button>`;
    if (e.status === "pending") act += ` <button class="small" data-cancel="${e.id}">취소</button>`;
  } else if (e.canApprove) {
    act = `<button class="small primary" data-ok="${e.id}">승인</button> <button class="small danger" data-no="${e.id}">반려</button>`;
  }
  return `<tr><td>${fmtTime(e.createdAt)}</td>${mode === "inbox" ? `<td>${esc(e.requester)}</td>` : ""}
    <td><b>${esc(e.fileName)}</b><br><span class="muted">${esc(e.shareName)}:${esc(e.filePath)} · ${fmtSize(e.size)}</span></td>
    <td>${esc(e.reason)}</td>
    <td><span class="st ${e.status}">${STATUS[e.status] || e.status}</span>${e.approver ? `<br><span class="muted">${esc(e.approver)}</span>` : ""}${e.decisionNote ? `<br><span class="muted">${esc(e.decisionNote)}</span>` : ""}
    ${e.status === "approved" || e.status === "post" ? `<br><span class="muted">~${fmtDate(e.expiresAt)}</span>` : ""}</td>
    <td class="actions">${act}</td></tr>`;
}

async function viewMyExports() {
  const list = await api("GET", "/api/exports?scope=mine");
  let h = `<h2>내 반출 신청</h2><p class="muted">파일 목록의 [반출 신청] 또는 탐색기에서 파일 오른쪽 클릭 → [DocVault 반출 신청]을 하면 팀장에게 결재가 올라갑니다. 승인되면 <b>개인문서함의 [반출] 폴더</b>에 파일이 들어가고, 그 폴더의 파일은 바탕화면·USB 등 PC로 복사할 수 있습니다. 여기서 다운로드할 수도 있습니다.</p>`;
  h += list.length ? `<table><thead><tr><th>신청일</th><th>파일</th><th>사유</th><th>상태</th><th></th></tr></thead><tbody>${list.map((e) => exportRow(e, "mine")).join("")}</tbody></table>` : `<div class="card empty">반출 신청 내역이 없습니다</div>`;
  $("#main").innerHTML = h;
  $("#main").querySelectorAll("[data-dl]").forEach((b) => b.onclick = () => { location.href = `/api/exports/${b.dataset.dl}/download`; setTimeout(route, 1500); });
  $("#main").querySelectorAll("[data-cancel]").forEach((b) => b.onclick = guard(async () => { await api("POST", `/api/exports/${b.dataset.cancel}/cancel`); route(); }));
}

async function viewApprovals() {
  const list = await api("GET", "/api/exports?scope=inbox");
  let h = `<h2>반출 결재함</h2>`;
  h += list.length ? `<table><thead><tr><th>신청일</th><th>신청자</th><th>파일</th><th>사유</th><th>상태</th><th></th></tr></thead><tbody>${list.map((e) => exportRow(e, "inbox")).join("")}</tbody></table>` : `<div class="card empty">결재할 반출 신청이 없습니다</div>`;
  $("#main").innerHTML = h;
  const decide = (id, approve) => guard(async () => {
    const note = prompt(approve ? "승인 의견 (선택)" : "반려 사유", "");
    if (note === null) return;
    await api("POST", `/api/exports/${id}/decide`, { approve, note });
    toast(approve ? "승인했습니다" : "반려했습니다"); await loadSide(); route();
  });
  $("#main").querySelectorAll("[data-ok]").forEach((b) => b.onclick = decide(b.dataset.ok, true));
  $("#main").querySelectorAll("[data-no]").forEach((b) => b.onclick = decide(b.dataset.no, false));
}

// ---------- admin ----------
async function adminUsers() {
  const [users, groups] = await Promise.all([api("GET", "/api/admin/users"), api("GET", "/api/admin/groups")]);
  let h = `<h2>사용자</h2><div class="toolbar"><button id="newUser" class="primary">+ 사용자 추가</button></div>
    <table><thead><tr><th>아이디</th><th>이름</th><th>그룹</th><th>상태</th><th></th></tr></thead><tbody>`;
  for (const u of users) {
    const st = [u.isAdmin ? "관리자" : "", u.dlpFree ? "free권한" : "", u.disabled ? "사용중지" : "", u.writeBlocked ? "⚠쓰기차단" : "", u.allowCopy ? "PC복사허용" : ""].filter(Boolean).join(", ");
    h += `<tr><td>${esc(u.username)}</td><td>${esc(u.displayName)}</td><td>${esc((u.groups || []).join(", "))}</td><td>${esc(st)}</td>
      <td class="actions"><button class="small" data-edit="${u.id}">수정</button></td></tr>`;
  }
  h += `</tbody></table>`;
  $("#main").innerHTML = h;
  const groupChecks = (sel) => `<div class="checks">${groups.map((g) => `<label><input type="checkbox" name="g" value="${g.id}" ${sel.includes(g.id) ? "checked" : ""}>${esc(g.name)}</label>`).join("") || `<span class="muted">그룹이 없습니다</span>`}</div>`;
  const checked = (f) => [...f.querySelectorAll("input[name=g]:checked")].map((x) => Number(x.value));
  $("#newUser").onclick = () => openModal(`<h3>사용자 추가</h3><form class="form">
    <label>아이디<input name="username" required></label><label>이름<input name="displayName"></label>
    <label>초기 비밀번호 (8자 이상)<input name="password" type="password" required minlength="8"></label>
    <label>그룹(팀)</label>${groupChecks([])}
    <label class="row"><input type="checkbox" name="isAdmin"> 관리자</label>
    <div class="buttons"><button type="button" data-close>취소</button><button class="primary">추가</button></div></form>`, (box) => {
    box.querySelector("form").onsubmit = guard(async (e) => {
      e.preventDefault(); const f = e.target;
      await api("POST", "/api/admin/users", { username: f.username.value, displayName: f.displayName.value, password: f.password.value, isAdmin: f.isAdmin.checked, groupIds: checked(f) });
      closeModal(); toast("추가했습니다"); route();
    });
  });
  $("#main").querySelectorAll("[data-edit]").forEach((b) => b.onclick = () => {
    const u = users.find((x) => x.id === Number(b.dataset.edit));
    openModal(`<h3>사용자 수정 – ${esc(u.username)}</h3><form class="form">
      <label>이름<input name="displayName" value="${esc(u.displayName)}"></label>
      <label>비밀번호 재설정 (변경 시에만 입력)<input name="password" type="password" minlength="8"></label>
      <label>그룹(팀)</label>${groupChecks(u.groupIds || [])}
      <label class="row"><input type="checkbox" name="isAdmin" ${u.isAdmin ? "checked" : ""}> 관리자</label>
      <label class="row"><input type="checkbox" name="disabled" ${u.disabled ? "checked" : ""}> 사용 중지 (퇴사 등 – 즉시 모든 접속 차단)</label>
      <label class="row"><input type="checkbox" name="writeBlocked" ${u.writeBlocked ? "checked" : ""}> 쓰기 차단 (랜섬웨어 의심 시 자동 설정됨)</label>
      <label class="row"><input type="checkbox" name="allowCopy" ${u.allowCopy ? "checked" : ""}> PC로 복사 허용 (PC 복사·저장 차단 예외)</label>
      <label class="row"><input type="checkbox" name="dlpFree" ${u.dlpFree ? "checked" : ""}> <b>모든 차단 면제 (free권한)</b> — 복사·저장·카톡·압축 등 모든 유출 차단에서 제외(관리자와 동일)</label>
      <div class="buttons"><button type="button" data-close>취소</button><button class="primary">저장</button></div></form>`, (box) => {
      box.querySelector("form").onsubmit = guard(async (e) => {
        e.preventDefault(); const f = e.target;
        const body = { displayName: f.displayName.value, isAdmin: f.isAdmin.checked, disabled: f.disabled.checked, writeBlocked: f.writeBlocked.checked, allowCopy: f.allowCopy.checked, dlpFree: f.dlpFree.checked, groupIds: checked(f) };
        if (f.password.value) body.password = f.password.value;
        await api("POST", `/api/admin/users/${u.id}`, body);
        closeModal(); toast("저장했습니다"); route();
      });
    });
  });
}

async function adminGroups() {
  const groups = await api("GET", "/api/admin/groups");
  let h = `<h2>그룹(팀)</h2><p class="muted">권한은 그룹 단위로 주는 것을 권장합니다. 입사·이동·퇴사 시 사용자의 그룹만 바꾸면 됩니다.</p>
    <form id="gForm" class="toolbar"><input name="name" placeholder="새 그룹 이름 (예: 일산영업팀)" required><button class="primary">추가</button></form>
    <table><thead><tr><th>그룹</th><th class="num">인원</th><th></th></tr></thead><tbody>
    ${groups.map((g) => `<tr><td>${esc(g.name)}</td><td class="num">${g.members}</td><td class="actions"><button class="small danger" data-del="${g.id}">삭제</button></td></tr>`).join("")}
    </tbody></table>`;
  $("#main").innerHTML = h;
  $("#gForm").onsubmit = guard(async (e) => { e.preventDefault(); await api("POST", "/api/admin/groups", { name: e.target.name.value }); route(); });
  $("#main").querySelectorAll("[data-del]").forEach((b) => b.onclick = guard(async () => {
    if (!confirm("그룹을 삭제할까요? 이 그룹에 준 드라이브 권한도 함께 사라집니다.")) return;
    await api("POST", `/api/admin/groups/${b.dataset.del}/delete`); route();
  }));
}

async function adminShares() {
  const [shares, users, groups] = await Promise.all([api("GET", "/api/admin/shares"), api("GET", "/api/admin/users"), api("GET", "/api/admin/groups")]);
  let h = `<h2>드라이브·권한</h2><p class="muted">드라이브 하나가 PC의 드라이브 문자 하나(예: O:)로 연결됩니다. 권한이 있는 사람의 PC에만 나타납니다.</p>
    <div class="toolbar"><button id="newDept" class="primary">+ 부서 문서함 추가</button><button id="newShare">드라이브만 추가</button></div>
    <p class="muted" style="margin-top:-6px">[부서 문서함 추가]는 팀·드라이브·권한을 한 번에 만듭니다. 그다음 <a href="#/admin/users" data-nav="admin/users">사용자</a>에서 직원을 그 팀에 넣으면 끝입니다.</p>
    <table><thead><tr><th>문자</th><th>이름</th><th>종류</th><th>용량</th><th></th></tr></thead><tbody>`;
  for (const s of shares) {
    h += `<tr><td>${esc(s.driveLetter ? s.driveLetter + ":" : "-")}</td><td>${esc(s.name)}</td><td>${s.personal ? "개인문서함 (사용자별 개인 공간)" : "팀 드라이브"}</td>
      <td>${s.personal ? (s.quotaBytes ? "1인당 " + fmtSize(s.quotaBytes) : "제한 없음") : fmtSize(s.used) + (s.quotaBytes ? " / " + fmtSize(s.quotaBytes) : "")}</td>
      <td class="actions"><button class="small" data-acl="${s.id}">권한</button> <button class="small" data-edit="${s.id}">수정</button> <button class="small danger" data-del="${s.id}">삭제</button></td></tr>`;
  }
  h += `</tbody></table>`;
  $("#main").innerHTML = h;
  const usedLetters = new Set(shares.map((x) => (x.driveLetter || "").toUpperCase()).filter(Boolean));
  // Assign from the end of the alphabet first — Z, Y, X … — since low letters
  // (C~F) are usually taken by the system disk, USB and optical drives on
  // employees' PCs. The chosen letter is stored on the server, so every PC
  // mounts the same drive at the same letter.
  const nextLetter = [..."ZYXWVUTSRQPONMLKJIH"].find((l) => !usedLetters.has(l)) || "";
  $("#newDept").onclick = () => openModal(`<h3>부서 문서함 추가</h3>
    <p class="muted">부서(팀)와 그 부서의 공유 드라이브를 한 번에 만들고, 그 팀에 읽기·쓰기 권한을 줍니다.</p>
    <form class="form">
    <label>부서 이름<input name="dept" required placeholder="예: 영업팀"></label>
    <label>드라이브 표시 이름 <span class="muted">(비우면 부서 이름 사용)</span><input name="name" placeholder="예: 영업"></label>
    <div class="row"><label style="flex:1">드라이브 문자<input name="letter" maxlength="1" value="${nextLetter}" style="width:80px"></label>
    <label style="flex:1">용량 제한 (GB, 0=무제한)<input name="quota" type="number" min="0" value="0"></label></div>
    <p id="deptMsg" class="muted"></p>
    <div class="buttons"><button type="button" data-close>취소</button><button class="primary">만들기</button></div></form>`, (box) => {
    box.querySelector("form").onsubmit = guard(async (e) => {
      e.preventDefault(); const f = e.target;
      const dept = f.dept.value.trim();
      const name = (f.name.value.trim() || dept);
      f.querySelector("button.primary").disabled = true;
      $("#deptMsg").textContent = "만드는 중...";
      try {
        const g = await api("POST", "/api/admin/groups", { name: dept });
        const sh = await api("POST", "/api/admin/shares", { name, driveLetter: f.letter.value, quotaGB: Number(f.quota.value), personal: false });
        await api("POST", `/api/admin/shares/${sh.id}/acl`, [{ principalType: "group", principalId: g.id, level: 2 }]);
        closeModal(); await loadSide(); toast(`'${dept}' 부서 문서함을 만들었습니다. 이제 사용자를 이 팀에 넣으세요`);
        location.hash = "#/admin/users";
      } catch (err) {
        $("#deptMsg").textContent = "실패: " + err.message + " (이미 같은 이름/문자가 있을 수 있습니다)";
        f.querySelector("button.primary").disabled = false;
      }
    });
  });
  $("#newShare").onclick = () => openModal(`<h3>드라이브 추가</h3><form class="form">
    <label>이름 (PC에 표시되는 이름)<input name="name" required placeholder="예: 일산영업"></label>
    <label>드라이브 문자<input name="letter" maxlength="1" value="${nextLetter}" style="width:80px"></label>
    <label>용량 제한 (GB, 0=제한 없음)<input name="quota" type="number" min="0" value="0"></label>
    <label class="row"><input type="checkbox" name="personal"> 개인문서함 (사용자마다 자기 공간만 보임)</label>
    <div class="buttons"><button type="button" data-close>취소</button><button class="primary">추가</button></div></form>`, (box) => {
    box.querySelector("form").onsubmit = guard(async (e) => {
      e.preventDefault(); const f = e.target;
      await api("POST", "/api/admin/shares", { name: f.name.value.trim(), driveLetter: f.letter.value, quotaGB: Number(f.quota.value), personal: f.personal.checked });
      closeModal(); await loadSide(); route();
    });
  });
  $("#main").querySelectorAll("[data-edit]").forEach((b) => b.onclick = () => {
    const s = shares.find((x) => x.id === Number(b.dataset.edit));
    openModal(`<h3>드라이브 수정 – ${esc(s.name)}</h3><form class="form">
      <label>드라이브 문자<input name="letter" maxlength="1" value="${esc(s.driveLetter)}" style="width:80px"></label>
      <label>용량 제한 (GB, 0=제한 없음)<input name="quota" type="number" min="0" value="${Math.round(s.quotaBytes / 2 ** 30)}"></label>
      <div class="buttons"><button type="button" data-close>취소</button><button class="primary">저장</button></div></form>`, (box) => {
      box.querySelector("form").onsubmit = guard(async (e) => {
        e.preventDefault();
        await api("POST", `/api/admin/shares/${s.id}`, { driveLetter: e.target.letter.value, quotaGB: Number(e.target.quota.value) });
        closeModal(); await loadSide(); route();
      });
    });
  });
  $("#main").querySelectorAll("[data-del]").forEach((b) => b.onclick = guard(async () => {
    if (!confirm("드라이브를 삭제할까요? (빈 드라이브만 삭제됩니다)")) return;
    await api("POST", `/api/admin/shares/${b.dataset.del}/delete`); await loadSide(); route();
  }));
  $("#main").querySelectorAll("[data-acl]").forEach((b) => b.onclick = guard(async () => {
    const s = shares.find((x) => x.id === Number(b.dataset.acl));
    let acl = await api("GET", `/api/admin/shares/${s.id}/acl`);
    const opts = (type, sel) => (type === "group" ? groups.map((g) => [g.id, g.name]) : users.map((u) => [u.id, u.displayName ? `${u.displayName}(${u.username})` : u.username]))
      .map(([id, n]) => `<option value="${id}" ${id === sel ? "selected" : ""}>${esc(n)}</option>`).join("");
    const render = (box) => {
      box.querySelector("#aclRows").innerHTML = acl.map((e, i) => `<div class="row">
        <select data-i="${i}" data-f="principalType"><option value="group" ${e.principalType === "group" ? "selected" : ""}>그룹</option><option value="user" ${e.principalType === "user" ? "selected" : ""}>사용자</option></select>
        <select data-i="${i}" data-f="principalId">${opts(e.principalType, e.principalId)}</select>
        <select data-i="${i}" data-f="level">${[1, 2, 3].map((l) => `<option value="${l}" ${l === e.level ? "selected" : ""}>${LEVELS[l]}</option>`).join("")}</select>
        <button type="button" class="small danger" data-rm="${i}">✕</button></div>`).join("") || `<p class="muted">권한이 없습니다 (관리자만 접근 가능)</p>`;
      box.querySelectorAll("select").forEach((sel) => sel.onchange = () => {
        const e = acl[sel.dataset.i]; const f = sel.dataset.f;
        e[f] = f === "principalType" ? sel.value : Number(sel.value);
        if (f === "principalType") { e.principalId = (sel.value === "group" ? groups[0]?.id : users[0]?.id) || 0; render(box); }
      });
      box.querySelectorAll("[data-rm]").forEach((x) => x.onclick = () => { acl.splice(Number(x.dataset.rm), 1); render(box); });
    };
    openModal(`<h3>권한 – ${esc(s.name)}</h3>
      <p class="muted">${s.personal ? "개인문서함은 모든 사용자가 자기 공간을 씁니다. 여기서는 반출 결재자(관리)만 지정하세요." : "읽기: 열기만 / 읽기·쓰기: 저장·삭제 / 관리: 반출 결재·휴지통 영구삭제"}</p>
      <div class="form"><div id="aclRows"></div>
      <div class="row"><button type="button" id="addAcl">+ 권한 추가</button></div>
      <div class="buttons"><button type="button" data-close>취소</button><button type="button" class="primary" id="saveAcl">저장</button></div></div>`, (box) => {
      render(box);
      box.querySelector("#addAcl").onclick = () => {
        acl.push(groups.length ? { principalType: "group", principalId: groups[0].id, level: 2 } : { principalType: "user", principalId: users[0].id, level: 2 });
        render(box);
      };
      box.querySelector("#saveAcl").onclick = guard(async () => {
        await api("POST", `/api/admin/shares/${s.id}/acl`, acl.map((e) => ({ principalType: e.principalType, principalId: e.principalId, level: e.level })));
        closeModal(); toast("권한을 저장했습니다. PC 에이전트가 1분 안에 반영합니다");
      });
    });
  }));
}

async function adminAudit() {
  const q = new URLSearchParams(location.hash.split("?")[1] || "");
  const shares = await api("GET", "/api/admin/shares");
  const params = new URLSearchParams({ from: q.get("from") || "", to: q.get("to") || "", user: q.get("user") || "", action: q.get("action") || "", share: q.get("share") || "", q: q.get("q") || "", limit: 100, offset: q.get("offset") || 0 });
  const data = await api("GET", "/api/admin/audit?" + params);
  let h = `<h2>감사 로그</h2>
    <form id="aForm" class="toolbar">
      <input type="date" name="from" value="${esc(q.get("from") || "")}"> ~ <input type="date" name="to" value="${esc(q.get("to") || "")}">
      <input name="user" placeholder="사용자" value="${esc(q.get("user") || "")}" style="width:110px">
      <select name="action"><option value="">모든 작업</option>${Object.entries(ACTIONS).map(([k, v]) => `<option value="${k}" ${q.get("action") === k ? "selected" : ""}>${v}</option>`).join("")}</select>
      <select name="share"><option value="">모든 드라이브</option>${shares.map((s) => `<option ${q.get("share") === s.name ? "selected" : ""}>${esc(s.name)}</option>`).join("")}</select>
      <input name="q" placeholder="파일명/내용 검색" value="${esc(q.get("q") || "")}">
      <button class="primary">조회</button><button type="button" id="csvBtn">엑셀(CSV) 저장</button>
    </form><p class="muted">총 ${data.total.toLocaleString()}건</p>
    <table><thead><tr><th>시간</th><th>사용자</th><th>작업</th><th>드라이브</th><th>파일</th><th class="hide-sm">상세</th><th class="hide-sm">IP · 경로</th></tr></thead><tbody>
    ${data.items.map((e) => `<tr><td style="white-space:nowrap">${fmtTime(e.ts)}</td><td class="nw">${esc(e.user)}</td><td class="nw">${esc(ACTIONS[e.action] || e.action)}</td>
      <td class="nw">${esc(e.share)}</td><td>${esc(e.path)}</td><td class="hide-sm">${esc(e.detail)}</td><td class="hide-sm muted">${esc(e.ip)} · ${esc(CLIENTS[e.client] || e.client)}</td></tr>`).join("")}
    </tbody></table><div class="toolbar">
    ${Number(params.get("offset")) > 0 ? `<button id="prevBtn">← 이전</button>` : ""}
    ${Number(params.get("offset")) + 100 < data.total ? `<button id="nextBtn">다음 →</button>` : ""}</div>`;
  $("#main").innerHTML = h;
  const go = (offset) => {
    const f = $("#aForm"); const p = new URLSearchParams();
    for (const k of ["from", "to", "user", "action", "share", "q"]) if (f[k].value) p.set(k, f[k].value);
    if (offset) p.set("offset", offset);
    location.hash = "#/admin/audit?" + p;
  };
  $("#aForm").onsubmit = (e) => { e.preventDefault(); go(0); };
  if ($("#prevBtn")) $("#prevBtn").onclick = () => go(Math.max(0, Number(params.get("offset")) - 100));
  if ($("#nextBtn")) $("#nextBtn").onclick = () => go(Number(params.get("offset")) + 100);
  $("#csvBtn").onclick = () => { params.delete("offset"); location.href = "/api/admin/audit.csv?" + params; };
}

async function adminSessions() {
  const list = await api("GET", "/api/admin/sessions");
  const latest = (await api("GET", "/api/setup-info").catch(() => ({}))).version || "";
  const older = (v) => { const a = v.split(".").map(Number), b = latest.split(".").map(Number); for (let i = 0; i < 3; i++) if ((a[i] || 0) !== (b[i] || 0)) return (a[i] || 0) < (b[i] || 0); return false; };
  const now = Date.now() / 1000;
  let h = `<h2>접속 PC·세션</h2><p class="muted">PC 에이전트는 1분마다 상태를 보고합니다. 5분 넘게 보고가 없으면 꺼졌거나 연결이 끊긴 PC입니다.${latest ? ` 서버의 PC 프로그램: <b>v${esc(latest)}</b> — 0.7.0 이상인 PC는 자동으로 업데이트됩니다 (PC를 쓰지 않을 때 적용).` : ""}</p>
    <table><thead><tr><th>사용자</th><th>종류</th><th>PC / 브라우저</th><th>IP</th><th>연결된 드라이브</th><th>마지막 접속</th><th></th></tr></thead><tbody>
    ${list.map((s) => `<tr><td>${esc(s.user)}</td><td>${s.kind === "agent" ? "PC 에이전트" : "웹"}</td><td>${esc(s.device)}${s.agentVer ? ` <span class="muted">v${esc(s.agentVer)}</span>${latest && older(s.agentVer) ? ` <span class="st pending">업데이트 대기</span>` : ""}` : ""}</td>
      <td>${esc(s.ip)}</td><td>${esc(s.mounted)}</td>
      <td>${fmtTime(s.lastSeen)} ${s.kind === "agent" && now - s.lastSeen > 300 ? `<span class="st rejected">응답 없음</span>` : ""}</td>
      <td class="actions"><button class="small danger" data-rv="${s.id}">강제 종료</button></td></tr>`).join("")}</tbody></table>`;
  $("#main").innerHTML = h;
  $("#main").querySelectorAll("[data-rv]").forEach((b) => b.onclick = guard(async () => {
    if (!confirm("이 접속을 끊을까요? PC 에이전트라면 드라이브 연결이 해제됩니다.")) return;
    await api("POST", `/api/admin/sessions/${b.dataset.rv}/revoke`); route();
  }));
}

const SETTING_LABELS = {
  retention_days: ["휴지통 보관 기간 (일)", "삭제한 파일은 이 기간 동안 휴지통에서 복원할 수 있고, 지나면 영구 삭제됩니다"],
  version_keep_days: ["이전 버전 보관 기간 (일)", "이 기간이 지난 이전 버전은 정리됩니다"],
  version_keep_count: ["최소 보관 버전 수", "기간이 지나도 파일마다 최근 버전을 이만큼은 남깁니다"],
  export_valid_days: ["반출 다운로드 가능 기간 (일)", "승인 후 이 기간 안에만 다운로드할 수 있습니다"],
  export_max_downloads: ["반출 최대 다운로드 횟수", ""],
  session_web_hours: ["웹 로그인 유지 시간 (시간)", ""],
  session_agent_days: ["PC 에이전트 로그인 유지 (일)", "사용하는 동안에는 자동 연장됩니다"],
  guard_threshold: ["랜섬웨어 의심 기준 (건수, 0=사용 안 함)", "아래 시간 안에 기존 파일을 이만큼 수정(덮어쓰기·이름변경)하면 그 계정의 쓰기를 자동 차단합니다. 삭제는 2건을 1건으로 계산합니다 (폴더 통째 삭제 오탐 방지)"],
  guard_window_sec: ["랜섬웨어 감지 시간 (초)", ""],
  audit_keep_days: ["감사 로그 보관 기간 (일, 0=영구)", "이 기간이 지난 로그는 자동 삭제됩니다. 오래 보관할수록 DB가 커집니다"],
};

const BLOCK_LABELS = {
  block_copy_out: ["PC로 복사 차단", "탐색기로 PC(바탕화면·USB 등)에 복사된 문서함 파일을 바로 삭제합니다. 명령창(cmd·PowerShell·robocopy·xcopy)은 읽기 차단. 압축 프로그램(반디집·알집·7-Zip·WinRAR)은 압축 풀기·열기는 되지만, 문서함 파일을 압축해 PC로 내보내면 그 압축파일을 삭제합니다. 사용자별 예외는 [사용자 → 수정 → PC로 복사 허용]"],
  block_messenger: ["메신저 첨부 차단", "카카오톡, 텔레그램, 라인, 왓츠앱, 디스코드에 문서함 파일을 첨부하지 못하게 합니다"],
  block_download_local: ["웹 다운로드 PC 저장 차단", "크롬·엣지·웨일에서 받은 파일은 개인문서함에 저장됩니다. [다른 이름으로 저장]으로 바탕화면 등 PC를 고르면 \"PC에 저장할 수 없습니다\" 알림과 함께 삭제됩니다. 받은 파일을 바로 여는 것은 됩니다"],
  allow_post_export: ["후결재 반출 허용", "반출 신청 때 [후결재]를 고르면 바로 개인문서함\\반출 폴더에 넣고 결재는 나중에 받습니다. 결재자가 반려하면 반출 폴더에서 회수됩니다 (이미 밖으로 복사한 것은 감사 로그로 확인)"],
  block_browser_upload: ["웹브라우저 업로드 차단", "크롬·엣지·웨일·파이어폭스가 문서함 파일을 읽지 못하게 합니다 (웹메일 첨부, 웹 업로드 차단). 문서함의 PDF를 브라우저로 여는 것도 막힙니다"],
};

async function adminStorage() {
  const d = await api("GET", "/api/admin/storage");
  const bar = (used, quota) => { const pct = quota > 0 ? Math.min(100, Math.round(used / quota * 100)) : 0; return quota > 0 ? `<div class="usage"><div style="width:${pct}%"></div></div> ${pct}%` : `<span class="muted">제한 없음</span>`; };
  let h = `<h2>저장소 사용량</h2><p class="muted">드라이브(문서함)별 현재 문서와 휴지통 사용량입니다. 저장소 디스크(NAS) 남은 공간: <b>${d.storeFreeGB ? d.storeFreeGB.toFixed(0) + " GB" : "-"}</b></p>
    <div class="tiles"><div class="tile"><div class="tile-v">${fmtSize(d.currentBytes)}</div><div class="tile-l">현재 문서 전체</div></div>
      <div class="tile"><div class="tile-v">${fmtSize(d.trashBytes)}</div><div class="tile-l">휴지통 전체</div></div></div>
    <table><thead><tr><th>문자</th><th>드라이브</th><th>종류</th><th class="num">파일 수</th><th class="num">사용량</th><th>용량 제한</th><th class="num">휴지통</th></tr></thead><tbody>
    ${d.drives.map((x) => `<tr><td>${esc(x.letter ? x.letter + ":" : "-")}</td><td>${esc(x.name)}</td><td>${x.personal ? "개인문서함" : "팀"}</td>
      <td class="num">${x.files.toLocaleString()}</td><td class="num">${fmtSize(x.bytes)}</td>
      <td>${bar(x.bytes, x.quotaBytes)}</td><td class="num">${x.trashFiles ? x.trashFiles.toLocaleString() + "개 / " + fmtSize(x.trashBytes) : "-"}</td></tr>`).join("")}
    </tbody></table>
    <p class="muted" style="margin-top:10px">같은 파일은 한 번만 저장(중복 제거)되므로, 각 드라이브 합계보다 실제 NAS 사용량이 적을 수 있습니다.</p>`;
  $("#main").innerHTML = h;
}

async function adminOverview() {
  const d = await api("GET", "/api/admin/overview");
  const st = d.stats;
  const tile = (label, value, sub, cls) => `<div class="tile ${cls || ""}"><div class="tile-v">${value}</div><div class="tile-l">${esc(label)}</div>${sub ? `<div class="tile-s">${sub}</div>` : ""}</div>`;
  const bk = d.backupConfigured
    ? (d.backup ? `<span class="ok">${fmtTime(Date.parse(d.backup.finishedAt) / 1000)}</span>` : `<span class="warn">아직 없음</span>`)
    : `<span class="muted">미설정</span>`;
  let h = `<h2>현황</h2><p class="muted">사내 문서중앙화 상태를 한눈에 봅니다.</p>`;
  // First-run getting-started guide (only admin + the personal drive exist).
  if (st.users <= 1 && st.shares <= 1) {
    h += `<div class="card ov" style="max-width:760px;margin-bottom:16px;border-color:var(--accent)">
      <h3 style="color:var(--accent)">시작하기</h3>
      <ol class="muted" style="line-height:2;margin:0 0 4px 1.1em">
        <li><a href="#/admin/shares" data-nav="admin/shares">드라이브·권한</a>에서 <b>[+ 부서 문서함 추가]</b> — 팀·드라이브·권한을 한 번에 만듭니다 (예: 영업팀 → 영업 O:)</li>
        <li><a href="#/admin/users" data-nav="admin/users">사용자</a>에서 직원 계정 만들고 그 팀에 넣기 (권한은 팀만 바꾸면 됩니다)</li>
        <li>직원 PC에서 <a href="/download/setup">PC 프로그램 설치</a> → 로그인하면 드라이브가 보입니다</li>
        <li><a href="#/admin/backup" data-nav="admin/backup">백업·복구</a>에서 USB 백업 준비 (재해 대비)</li>
      </ol>
    </div>`;
  }
  h += `
    <div class="tiles">
      ${tile("사용 중인 계정", st.users)}
      ${tile("팀(그룹)", st.groups)}
      ${tile("드라이브", st.shares)}
      ${tile("지금 접속한 PC", st.connectedPCs, "최근 5분")}
      ${tile("반출 결재 대기", st.pendingExports, "", st.pendingExports ? "attn" : "")}
      ${tile("쓰기 차단 계정", st.writeBlocked, "랜섬웨어 의심", st.writeBlocked ? "danger" : "")}
      ${tile("휴지통", st.trashItems, "복원 가능")}
      ${tile("문서 사용량", fmtSize(st.storeBytes), "현재 버전")}
      ${tile("저장소(NAS)", d.storeOK ? "정상" : "오류", d.storeOK ? "연결됨" : "접근 불가", d.storeOK ? "" : "danger")}
    </div>
    <div class="cards2">
      <div class="card ov"><h3>백업</h3><div class="ov-row"><span class="muted">마지막 백업</span>${bk}</div>
        <a class="btnlink" href="#/admin/backup" data-nav="admin/backup">백업·복구 열기</a></div>
      <div class="card ov"><h3>PC 프로그램</h3><div class="ov-row"><span class="muted">서버가 배포하는 버전</span><b>v${esc(d.setupVersion || "-")}</b></div>
        <a class="btnlink" href="#/admin/sessions" data-nav="admin/sessions">접속 PC 보기</a></div>
    </div>`;
  if (st.pendingExports) h = h.replace("</p>", `</p><div class="warnbox">반출 결재가 <b>${st.pendingExports}건</b> 대기 중입니다. <a href="#/approvals" data-nav="approvals">결재함 열기</a></div>`);
  $("#main").innerHTML = h;
}

async function adminBackup() {
  const b = await api("GET", "/api/admin/backup");
  const fmtT = (t) => t && !t.startsWith("0001") ? fmtTime(Date.parse(t) / 1000) : "없음";
  const last = b.last;
  const kind = last ? (last.blobsCopied === last.blobsTotal ? "전체 백업(처음)" : "증분(바뀐 것만)") : "-";
  let h = `<h2>백업 · 복구 (재해 대비)</h2>
    <p class="muted">서버·NAS가 모두 고장나거나 랜섬웨어에 감염돼도 복구할 수 있도록, USB/외장 디스크에 <b>수동으로</b> 백업합니다. 백업이 끝나면 USB를 <b>뽑아서 따로 보관</b>하세요.</p>
    <div class="card" style="padding:18px;max-width:780px">
      <h3 style="margin-top:0">지금 백업</h3>
      <p class="muted">서버에 USB/외장 디스크를 꽂은 뒤, 그 드라이브 문자를 적고 [백업 시작]을 누르세요. 처음은 전체 복사라 오래 걸리고, 이후에는 <b>바뀐 파일만</b> 복사해 금방 끝납니다.</p>
      <div class="form"><label>백업 위치 (USB/외장 디스크)<input id="bkDir" placeholder="예: E:\\" value="${esc(b.dir || "")}"></label>
      <div class="buttons"><button id="bkNow" class="primary">백업 시작</button></div>
      <p id="bkMsg" class="muted"></p></div>
    </div>`;
  if (last) {
    h += `<div class="card" style="padding:18px;max-width:780px;margin-top:14px">
      <h3 style="margin-top:0">마지막 백업</h3>
      <table style="width:100%"><tbody>
      <tr><td class="muted" style="width:170px">시각</td><td>${fmtT(last.finishedAt)}</td></tr>
      <tr><td class="muted">방식</td><td><b>${kind}</b></td></tr>
      <tr><td class="muted">백업된 파일(전체)</td><td>${last.blobsTotal.toLocaleString()}개 · ${fmtSize(last.bytesTotal)}</td></tr>
      <tr><td class="muted">이번에 새로 복사</td><td>${last.blobsCopied.toLocaleString()}개 · ${fmtSize(last.bytesCopied)} · ${last.durationSec}초</td></tr>
      <tr><td class="muted">백업 디스크 남은 용량</td><td>${last.targetFreeGB ? last.targetFreeGB.toFixed(0) + " GB" : "-"}</td></tr>
      <tr><td class="muted">DB 스냅샷</td><td>${esc(last.dbSnapshot || "-")}</td></tr>
      </tbody></table></div>`;
  }
  h += `<div class="card" style="padding:18px;max-width:780px;margin-top:14px">
    <h3 style="margin-top:0">복구 방법 (서버·NAS를 모두 잃었을 때)</h3>
    <ol class="muted" style="line-height:1.9">
      <li>새(또는 복구된) 서버에 DocVault를 설치합니다.</li>
      <li>백업 USB/디스크를 서버에 꽂습니다.</li>
      <li>서버 폴더에서 명령창을 열고 실행: <code>docvault-server.exe restore E:\</code> (E: 는 백업 디스크)</li>
      <li>YES 를 입력하면 파일·계정·권한·버전이 모두 복구됩니다.</li>
      <li>서비스를 시작하면 직원들이 그대로 사용합니다.</li>
    </ol>
    <p class="muted">특정 시점 복구: <code>restore E:\ docvault-20260101-020000.db</code> (백업 디스크에 최근 14개 스냅샷 보관)</p>
  </div>`;
  $("#main").innerHTML = h;
  $("#bkNow").onclick = guard(async () => {
    const dir = $("#bkDir").value.trim();
    if (!dir) { $("#bkMsg").textContent = "백업 위치를 입력하세요 (예: E:\\)"; return; }
    $("#bkNow").disabled = true;
    $("#bkMsg").textContent = "백업 중입니다... (처음이거나 많이 바뀌었으면 오래 걸릴 수 있습니다. 창을 닫지 마세요)";
    try {
      const r = await api("POST", "/api/admin/backup", { dir });
      const k = r.blobsCopied === r.blobsTotal ? "전체 백업" : "증분 백업";
      $("#bkMsg").textContent = `완료(${k}): 새로 복사 ${r.blobsCopied.toLocaleString()}개 (${fmtSize(r.bytesCopied)}), 전체 ${r.blobsTotal.toLocaleString()}개. ${r.durationSec}초.`;
      setTimeout(() => route(), 1500);
    } catch (e) {
      $("#bkMsg").textContent = "백업 실패: " + e.message;
      $("#bkNow").disabled = false;
    }
  });
}

async function adminSettings() {
  const s = await api("GET", "/api/admin/settings");
  let h = `<h2>설정</h2><form id="sForm" class="form card" style="padding:18px;max-width:620px">`;
  h += `<h3 style="margin:0">유출 차단 (PC 프로그램)</h3><p class="muted" style="margin:0">일반 사용자에게만 적용됩니다. 관리자 계정은 모두 허용됩니다.</p>`;
  for (const [k, [label, help]] of Object.entries(BLOCK_LABELS)) {
    h += `<label class="row" style="align-items:flex-start"><input type="checkbox" name="${k}" ${s[k] ? "checked" : ""}><span><b>${esc(label)}</b><br><span class="muted">${esc(help)}</span></span></label>`;
  }
  h += `<label>추가로 차단할 프로그램 (쉼표로 구분)<input name="block_extra_processes" value="${esc(s.block_extra_processes || "")}" placeholder="예: slack.exe, teams.exe"><span class="muted">작업 관리자의 [세부 정보] 탭에 보이는 실행 파일 이름</span></label>`;
  h += `<h3 style="margin:10px 0 0">보관·보안</h3>`;
  for (const [k, [label, help]] of Object.entries(SETTING_LABELS)) {
    h += `<label>${esc(label)}<input type="number" min="0" name="${k}" value="${s[k]}">${help ? `<span class="muted">${esc(help)}</span>` : ""}</label>`;
  }
  h += `<div class="buttons"><button type="button" id="ckBtn">저장소 점검</button><button type="button" id="mtBtn">지금 정리 실행</button><button class="primary">저장</button></div></form><div id="ckOut" style="max-width:820px"></div>`;
  $("#main").innerHTML = h;
  $("#sForm").onsubmit = guard(async (e) => {
    e.preventDefault();
    const body = {}; for (const k of Object.keys(SETTING_LABELS)) body[k] = Number(e.target[k].value);
    for (const k of Object.keys(BLOCK_LABELS)) body[k] = e.target[k].checked ? 1 : 0;
    body.block_extra_processes = e.target.block_extra_processes.value;
    await api("POST", "/api/admin/settings", body); toast("저장했습니다");
  });
  $("#ckBtn").onclick = guard(async () => {
    $("#ckOut").innerHTML = `<p class="muted">점검 중...</p>`;
    const r = await api("GET", "/api/admin/store-check");
    if (!r.missing.length) { $("#ckOut").innerHTML = `<div class="card" style="padding:14px">✅ 파일 ${r.checked}개 모두 저장소(NAS)에 내용이 있습니다.</div>`; return; }
    $("#ckOut").innerHTML = `<h3>저장소에 내용이 없는 파일 ${r.missing.length}개 (전체 ${r.checked}개 중)</h3>
      <p class="muted">이 파일들은 목록에는 보이지만 열 수 없고, 탐색기에서 오른쪽 클릭·미리보기 때 느려질 수 있습니다. 보통 저장소 폴더(store_dir)를 바꾸기 전에 저장한 파일입니다.
      예전 저장소 폴더가 남아 있으면 그 안의 <b>blobs</b> 폴더 내용을 지금 저장소의 blobs 폴더에 복사(덮어쓰지 않기)하면 되살아납니다. 아니면 이전 버전으로 복원하거나 삭제하세요.</p>
      <table><thead><tr><th>드라이브</th><th>사용자(개인문서함)</th><th>경로</th><th>크기</th><th>이전 버전</th></tr></thead><tbody>
      ${r.missing.map((m) => `<tr><td>${esc(m.share)}</td><td>${esc(m.owner || "")}</td><td>${esc(m.path)}</td><td>${fmtSize(m.size)}</td><td>${m.restorableVersion ? "복원 가능" : "없음"}</td></tr>`).join("")}</tbody></table>`;
  });
  $("#mtBtn").onclick = guard(async () => {
    const r = await api("POST", "/api/admin/maintain");
    toast(`휴지통 영구삭제 ${r.PurgedItems}건, 이전 버전 정리 ${r.PrunedVersions}건, 반출 만료 ${r.ExpiredExports}건`);
  });
}

start();
