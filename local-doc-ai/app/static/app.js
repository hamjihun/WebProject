"use strict";

const $ = (sel) => document.querySelector(sel);
const state = {
  notebookId: null,
  docs: [],
  unchecked: new Set(), // 선택 해제한 문서 id (노트북별로 저장)
  busy: false,
  abort: null,
  pollTimer: null,
};

// ------------------------------------------------------------ API

async function api(path, opts = {}) {
  const res = await fetch(path, {
    ...opts,
    headers: opts.body && !(opts.body instanceof FormData) ? { "Content-Type": "application/json" } : undefined,
  });
  if (!res.ok) {
    let msg = `${res.status}`;
    try { msg = (await res.json()).detail || msg; } catch {}
    throw new Error(typeof msg === "string" ? msg : JSON.stringify(msg));
  }
  return res.json();
}

function esc(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}

function store(key, value) {
  try { localStorage.setItem(key, JSON.stringify(value)); } catch {}
}
function load(key, fallback) {
  try { const v = localStorage.getItem(key); return v ? JSON.parse(v) : fallback; } catch { return fallback; }
}

// ------------------------------------------------------------ 상태 표시

async function checkStatus() {
  const dot = $("#statusDot");
  const banner = $("#banner");
  try {
    const s = await api("/api/status");
    if (!s.ollama) {
      dot.className = "status-dot bad";
      dot.title = "AI 엔진(Ollama)이 꺼져 있습니다";
      banner.innerHTML = "AI 엔진(Ollama)에 연결할 수 없습니다. 시작 메뉴에서 <b>Ollama</b>를 실행한 뒤 잠시 기다려 주세요.";
      banner.hidden = false;
    } else if (s.missing.length) {
      dot.className = "status-dot bad";
      dot.title = "필요한 모델이 설치되지 않았습니다";
      banner.innerHTML = "필요한 AI 모델이 설치되어 있지 않습니다. 명령 프롬프트에서 다음을 실행해 주세요: " +
        s.missing.map((m) => `<code>ollama pull ${esc(m)}</code>`).join(" ");
      banner.hidden = false;
    } else {
      dot.className = "status-dot ok";
      dot.title = `준비됨 · 답변 모델 ${s.chat_model}`;
      banner.hidden = true;
    }
    return s;
  } catch {
    dot.className = "status-dot bad";
    return null;
  }
}

// ------------------------------------------------------------ 노트북

async function loadNotebooks(selectId) {
  let list = await api("/api/notebooks");
  if (!list.length) {
    await api("/api/notebooks", { method: "POST", body: JSON.stringify({ name: "내 노트북" }) });
    list = await api("/api/notebooks");
  }
  const sel = $("#nbSelect");
  sel.innerHTML = list.map((n) => `<option value="${n.id}">${esc(n.name)} (${n.doc_count})</option>`).join("");
  const want = selectId ?? load("lastNotebook", null);
  const id = list.some((n) => n.id === want) ? want : list[0].id;
  sel.value = String(id);
  await openNotebook(id);
}

async function openNotebook(id) {
  if (state.abort) state.abort.abort();
  state.notebookId = id;
  store("lastNotebook", id);
  state.unchecked = new Set(load(`unchecked:${id}`, []));
  closeSource();
  await loadDocs();
  await loadMessages();
}

$("#nbSelect").addEventListener("change", (e) => openNotebook(Number(e.target.value)));

$("#nbNew").addEventListener("click", async () => {
  const name = prompt("새 노트북 이름", "새 노트북");
  if (!name || !name.trim()) return;
  const nb = await api("/api/notebooks", { method: "POST", body: JSON.stringify({ name: name.trim() }) });
  await loadNotebooks(nb.id);
});

$("#nbRename").addEventListener("click", async () => {
  const cur = $("#nbSelect").selectedOptions[0]?.textContent.replace(/ \(\d+\)$/, "") || "";
  const name = prompt("노트북 이름 바꾸기", cur);
  if (!name || !name.trim()) return;
  await api(`/api/notebooks/${state.notebookId}`, { method: "PATCH", body: JSON.stringify({ name: name.trim() }) });
  await loadNotebooks(state.notebookId);
});

$("#nbDelete").addEventListener("click", async () => {
  if (!confirm("이 노트북과 안에 있는 자료·대화를 모두 삭제할까요? 되돌릴 수 없습니다.")) return;
  await api(`/api/notebooks/${state.notebookId}`, { method: "DELETE" });
  store("lastNotebook", null);
  await loadNotebooks();
});

// ------------------------------------------------------------ 자료

function fmtSize(b) {
  if (b < 1024) return `${b}B`;
  if (b < 1024 * 1024) return `${(b / 1024).toFixed(0)}KB`;
  return `${(b / 1024 / 1024).toFixed(1)}MB`;
}

function fileIcon(name) {
  const ext = name.split(".").pop().toLowerCase();
  if (ext === "pdf") return "📕";
  if (["xlsx", "xlsm", "xls", "csv"].includes(ext)) return "📗";
  if (ext === "pptx") return "📙";
  if (["hwp", "hwpx"].includes(ext)) return "📘";
  return "📄";
}

async function loadDocs() {
  const nb = state.notebookId;
  const docs = await api(`/api/notebooks/${nb}/documents`);
  if (nb !== state.notebookId) return;
  state.docs = docs;
  renderDocs();
  clearTimeout(state.pollTimer);
  if (docs.some((d) => d.status === "processing")) state.pollTimer = setTimeout(loadDocs, 1500);
}

function renderDocs() {
  const ul = $("#docList");
  if (!state.docs.length) {
    ul.innerHTML = `<li class="muted" style="padding:8px">아직 올린 자료가 없습니다.</li>`;
  } else {
    ul.innerHTML = state.docs.map((d) => {
      let meta;
      if (d.status === "processing") {
        const pct = Math.round(d.progress * 100);
        meta = `<div class="meta">분석 중… ${pct}%</div><div class="bar"><i style="width:${pct}%"></i></div>`;
      } else if (d.status === "error") {
        meta = `<div class="meta err">${esc(d.error || "오류")}</div>`;
      } else {
        meta = `<div class="meta">${fmtSize(d.size_bytes)} · 조각 ${d.chunk_count}개</div>`;
      }
      const checked = d.status === "ready" && !state.unchecked.has(d.id);
      return `<li class="doc" data-id="${d.id}">
        <input type="checkbox" ${checked ? "checked" : ""} ${d.status !== "ready" ? "disabled" : ""} title="질문할 때 이 자료 사용">
        <div><div class="name">${fileIcon(d.filename)} ${esc(d.filename)}</div>${meta}</div>
        <button class="del" title="삭제">✕</button>
      </li>`;
    }).join("");
  }
  const ready = state.docs.filter((d) => d.status === "ready");
  $("#selectAll").checked = ready.length > 0 && ready.every((d) => !state.unchecked.has(d.id));
  const empty = $("#messages .empty");
  if (empty) empty.outerHTML = emptyState();
  const opt = $("#nbSelect").selectedOptions[0];
  if (opt) opt.textContent = opt.textContent.replace(/\(\d+\)$/, `(${state.docs.length})`);
}

$("#docList").addEventListener("change", (e) => {
  const li = e.target.closest(".doc");
  if (!li) return;
  const id = Number(li.dataset.id);
  e.target.checked ? state.unchecked.delete(id) : state.unchecked.add(id);
  store(`unchecked:${state.notebookId}`, [...state.unchecked]);
  renderDocs();
});

$("#docList").addEventListener("click", async (e) => {
  if (!e.target.classList.contains("del")) return;
  const li = e.target.closest(".doc");
  const doc = state.docs.find((d) => d.id === Number(li.dataset.id));
  if (!confirm(`'${doc.filename}' 자료를 삭제할까요?`)) return;
  await api(`/api/documents/${doc.id}`, { method: "DELETE" });
  await loadDocs();
});

$("#selectAll").addEventListener("change", (e) => {
  state.unchecked = e.target.checked ? new Set() : new Set(state.docs.map((d) => d.id));
  store(`unchecked:${state.notebookId}`, [...state.unchecked]);
  renderDocs();
});

async function upload(files) {
  if (!files.length) return;
  const fd = new FormData();
  for (const f of files) fd.append("files", f);
  try {
    const results = await api(`/api/notebooks/${state.notebookId}/documents`, { method: "POST", body: fd });
    const errors = results.filter((r) => r.error);
    if (errors.length) alert(errors.map((r) => `${r.filename}: ${r.error}`).join("\n"));
  } catch (err) {
    alert(`업로드 실패: ${err.message}`);
  }
  await loadDocs();
}

$("#fileInput").addEventListener("change", (e) => { upload([...e.target.files]); e.target.value = ""; });
const dz = $("#dropZone");
dz.addEventListener("dragover", (e) => { e.preventDefault(); dz.classList.add("over"); });
dz.addEventListener("dragleave", () => dz.classList.remove("over"));
dz.addEventListener("drop", (e) => { e.preventDefault(); dz.classList.remove("over"); upload([...e.dataTransfer.files]); });

// ------------------------------------------------------------ 답변 표시 (간단한 마크다운)

function inline(s) {
  return s
    .replace(/\*\*(.+?)\*\*/g, "<b>$1</b>")
    .replace(/`([^`]+)`/g, "<code>$1</code>")
    .replace(/\[(\d+(?:\s*[,，]\s*\d+)*)\]/g, (_, nums) =>
      nums.split(/[,，]/).map((n) => `<button class="cite" data-n="${n.trim()}">${n.trim()}</button>`).join(""));
}

function renderMarkdown(text) {
  const lines = esc(text).split("\n");
  const out = [];
  let list = null;
  let para = [];
  let table = [];
  const flushPara = () => { if (para.length) { out.push(`<p>${para.map(inline).join("<br>")}</p>`); para = []; } };
  const flushList = () => { if (list) { out.push(`<${list.tag}>${list.items.map((i) => `<li>${inline(i)}</li>`).join("")}</${list.tag}>`); list = null; } };
  const flushTable = () => {
    if (!table.length) return;
    const rows = table.filter((r) => !/^\|?\s*:?-{2,}/.test(r)).map((r) => r.replace(/^\||\|$/g, "").split("|").map((c) => c.trim()));
    out.push("<table>" + rows.map((r, i) => `<tr>${r.map((c) => i === 0 ? `<th>${inline(c)}</th>` : `<td>${inline(c)}</td>`).join("")}</tr>`).join("") + "</table>");
    table = [];
  };
  for (const raw of lines) {
    const line = raw.trimEnd();
    let m;
    if (/^\s*\|.*\|\s*$/.test(line)) { flushPara(); flushList(); table.push(line.trim()); continue; }
    flushTable();
    if (!line.trim()) { flushPara(); flushList(); continue; }
    if ((m = line.match(/^(#{1,4})\s+(.*)$/))) { flushPara(); flushList(); out.push(`<h4>${inline(m[2])}</h4>`); continue; }
    if ((m = line.match(/^\s*[-*•]\s+(.*)$/)) || (m = line.match(/^\s*\d+[.)]\s+(.*)$/))) {
      flushPara();
      const tag = /^\s*\d/.test(line) ? "ol" : "ul";
      if (!list || list.tag !== tag) { flushList(); list = { tag, items: [] }; }
      list.items.push(m[1]);
      continue;
    }
    flushList();
    para.push(line);
  }
  flushPara(); flushList(); flushTable();
  return out.join("");
}

// ------------------------------------------------------------ 대화

function emptyState() {
  const ready = state.docs.filter((d) => d.status === "ready").length;
  const tips = ready
    ? ["이 자료들의 핵심 내용을 요약해줘", "주요 수치나 금액을 표로 정리해줘", "담당자와 일정이 적힌 부분을 찾아줘"]
    : [];
  return `<div class="empty">
    <h3>올린 자료만 근거로 답합니다</h3>
    <div>${ready ? "아래 예시처럼 질문해 보세요." : "왼쪽에서 PDF, 엑셀, PPT 파일을 먼저 올려주세요."}</div>
    <div class="suggest">${tips.map((t) => `<button>${esc(t)}</button>`).join("")}</div>
  </div>`;
}

async function loadMessages() {
  const nb = state.notebookId;
  const msgs = await api(`/api/notebooks/${nb}/messages`);
  if (nb !== state.notebookId) return;
  const box = $("#messages");
  box.innerHTML = "";
  if (!msgs.length) { box.innerHTML = emptyState(); return; }
  for (const m of msgs) {
    if (m.role === "user") addUser(m.content);
    else addAssistant(m.content, m.sources);
  }
  box.scrollTop = box.scrollHeight;
}

function addUser(text) {
  const box = $("#messages");
  box.querySelector(".empty")?.remove();
  const el = document.createElement("div");
  el.className = "msg user";
  el.textContent = text;
  box.appendChild(el);
}

function addAssistant(text, sources) {
  const el = document.createElement("div");
  el.className = "msg assistant";
  el._sources = sources || [];
  $("#messages").appendChild(el);
  paintAssistant(el, text, false);
  return el;
}

function paintAssistant(el, text, typing) {
  const chips = (el._sources || []).map((s) =>
    `<button class="src-chip" data-n="${s.n}" title="${esc(s.filename)} · ${esc(s.location)}">${s.n}. ${esc(s.filename)} · ${esc(s.location)}</button>`).join("");
  el.innerHTML = `<div class="${typing ? "typing" : ""}">${renderMarkdown(text)}</div>` +
    (chips && !typing ? `<div class="src-list">${chips}</div>` : "");
  // 실제 출처가 없는 번호는 버튼이 아닌 글자로 둔다
  const known = new Set((el._sources || []).map((x) => String(x.n)));
  el.querySelectorAll(".cite").forEach((b) => { if (!known.has(b.dataset.n)) b.replaceWith(`[${b.dataset.n}]`); });
}

$("#messages").addEventListener("click", (e) => {
  const tip = e.target.closest(".suggest button");
  if (tip) { $("#question").value = tip.textContent; ask(); return; }
  const btn = e.target.closest(".cite, .src-chip");
  if (!btn) return;
  const msg = btn.closest(".msg");
  const src = (msg._sources || []).find((s) => String(s.n) === btn.dataset.n);
  if (src) showSource(src);
});

function showSource(s) {
  $("#svTitle").textContent = `출처 ${s.n}`;
  $("#svMeta").textContent = `${s.filename} · ${s.location} · 관련도 ${s.score}`;
  $("#svText").textContent = s.text;
  $("#svOpen").href = `/api/documents/${s.document_id}/file`;
  $("#sourceView").hidden = false;
}
function closeSource() { $("#sourceView").hidden = true; }
$("#svClose").addEventListener("click", closeSource);

async function ask() {
  const q = $("#question").value.trim();
  if (!q || state.busy) return;
  const docIds = state.docs.filter((d) => d.status === "ready" && !state.unchecked.has(d.id)).map((d) => d.id);
  if (!docIds.length) {
    alert(state.docs.length ? "질문에 사용할 자료를 하나 이상 선택해 주세요." : "먼저 자료를 올려주세요.");
    return;
  }
  $("#question").value = "";
  autosize();
  addUser(q);
  const el = addAssistant("", []);
  paintAssistant(el, "관련 자료를 찾는 중…", true);
  const box = $("#messages");
  box.scrollTop = box.scrollHeight;

  setBusy(true);
  const ctrl = new AbortController();
  state.abort = ctrl;
  let text = "";
  let gotToken = false;
  try {
    const res = await fetch(`/api/notebooks/${state.notebookId}/ask`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ question: q, document_ids: docIds }),
      signal: ctrl.signal,
    });
    if (!res.ok) throw new Error((await res.json()).detail || res.status);
    const reader = res.body.getReader();
    const dec = new TextDecoder();
    let buf = "";
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      buf += dec.decode(value, { stream: true });
      let nl;
      while ((nl = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, nl); buf = buf.slice(nl + 1);
        if (!line.trim()) continue;
        const ev = JSON.parse(line);
        if (ev.type === "sources") {
          el._sources = ev.sources;
          paintAssistant(el, ev.sources.length ? `자료 ${ev.sources.length}곳을 찾았습니다. 답변을 작성하는 중…` : "", true);
        } else if (ev.type === "token") {
          if (!gotToken) { gotToken = true; text = ""; }
          text += ev.text;
          paintAssistant(el, text, true);
        } else if (ev.type === "error") {
          el.classList.add("error");
          text += (text ? "\n\n" : "") + "⚠ " + ev.message;
        }
        const nearBottom = box.scrollHeight - box.scrollTop - box.clientHeight < 120;
        if (nearBottom) box.scrollTop = box.scrollHeight;
      }
    }
  } catch (err) {
    if (err.name === "AbortError") text += (text ? "\n\n" : "") + "(중지됨)";
    else { el.classList.add("error"); text += (text ? "\n\n" : "") + "⚠ " + err.message; }
  } finally {
    paintAssistant(el, text, false);
    setBusy(false);
    state.abort = null;
  }
}

function setBusy(b) {
  state.busy = b;
  $("#sendBtn").hidden = b;
  $("#stopBtn").hidden = !b;
}

$("#askForm").addEventListener("submit", (e) => { e.preventDefault(); ask(); });
$("#stopBtn").addEventListener("click", () => state.abort?.abort());
const qEl = $("#question");
function autosize() { qEl.style.height = "auto"; qEl.style.height = Math.min(qEl.scrollHeight, 180) + "px"; }
qEl.addEventListener("input", autosize);
qEl.addEventListener("keydown", (e) => {
  if (e.key === "Enter" && !e.shiftKey && !e.isComposing) { e.preventDefault(); ask(); }
});

$("#clearChat").addEventListener("click", async () => {
  if (!confirm("이 노트북의 대화 기록을 모두 지울까요?")) return;
  await api(`/api/notebooks/${state.notebookId}/messages`, { method: "DELETE" });
  await loadMessages();
});

// ------------------------------------------------------------ 설정

$("#openSettings").addEventListener("click", async () => {
  const [s, st] = await Promise.all([api("/api/settings"), checkStatus()]);
  const models = (st?.models || []).filter((m) => !/embed|bge|e5|minilm/i.test(m));
  if (!models.includes(s.chat_model)) models.unshift(s.chat_model);
  $("#chatModel").innerHTML = models.map((m) => `<option ${m === s.chat_model ? "selected" : ""}>${esc(m)}</option>`).join("");
  const f = $("#settingsForm");
  for (const k of ["top_k", "num_ctx", "min_score"]) f.elements[k].value = s[k];
  $("#settings").showModal();
});

$("#settings").addEventListener("close", async () => {
  if ($("#settings").returnValue !== "save") return;
  const f = $("#settingsForm");
  try {
    await api("/api/settings", {
      method: "PUT",
      body: JSON.stringify({
        chat_model: f.elements.chat_model.value,
        top_k: Number(f.elements.top_k.value),
        num_ctx: Number(f.elements.num_ctx.value),
        min_score: Number(f.elements.min_score.value),
      }),
    });
    checkStatus();
  } catch (err) {
    alert(`설정 저장 실패: ${err.message}`);
  }
});

// ------------------------------------------------------------ 시작

checkStatus();
setInterval(checkStatus, 15000);
loadNotebooks().catch((err) => alert(`불러오기 실패: ${err.message}`));
