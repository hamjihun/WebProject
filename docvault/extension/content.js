// DocVault 웹 첨부 보호 — 콘텐츠 스크립트.
//
// 사용자가 파일을 첨부하려는 순간(파일 선택창/드래그)을 가로채 백그라운드에
// 허용 여부를 묻는다. 반출 승인된 파일이거나 예외 사이트면 통과시키고,
// 아니면 선택을 취소하고 안내를 띄운다.

(function () {
  "use strict";

  if (window.__docvaultUploadGuard) return;
  window.__docvaultUploadGuard = true;

  var HASH_LIMIT = 64 * 1024 * 1024; // 이보다 큰 파일은 해시 생략(크기로 대조)
  var passNext = new WeakSet(); // 우리가 다시 보낸 change 이벤트는 그대로 통과
  // mode: 0=끄기, 1=기록만, 2=차단
  var policy = { mode: 0, allowDomains: [] };

  function refreshPolicy() {
    try {
      chrome.runtime.sendMessage({ type: "policy" }, function (resp) {
        if (!chrome.runtime.lastError && resp) policy = resp;
      });
    } catch (e) {}
  }
  refreshPolicy();
  setInterval(refreshPolicy, 10000);

  function hostExcepted() {
    var h = location.hostname.toLowerCase();
    return (policy.allowDomains || []).some(function (d) {
      return d && (h === d || h.endsWith("." + d));
    });
  }

  function toHex(buf) {
    var b = new Uint8Array(buf);
    var s = "";
    for (var i = 0; i < b.length; i++) s += b[i].toString(16).padStart(2, "0");
    return s;
  }

  async function fingerprint(file) {
    var info = { name: file.name, size: file.size, sha: "" };
    if (file.size > 0 && file.size <= HASH_LIMIT) {
      try {
        info.sha = toHex(await crypto.subtle.digest("SHA-256", await file.arrayBuffer()));
      } catch (e) {}
    }
    return info;
  }

  function sendOnce(msg) {
    return new Promise(function (resolve) {
      try {
        chrome.runtime.sendMessage(msg, function (resp) {
          if (chrome.runtime.lastError || !resp) resolve(null);
          else resolve(resp);
        });
      } catch (e) {
        resolve(null);
      }
    });
  }

  // send retries once: the MV3 service worker may be asleep and the first
  // message can fail while it wakes, which should not falsely block an upload.
  async function send(msg) {
    var r = await sendOnce(msg);
    if (r) return r;
    await new Promise(function (f) { setTimeout(f, 200); });
    return sendOnce(msg);
  }

  // ---- 파일 선택창(input[type=file]) ----
  // 파일 선택은 일단 붙잡고 백그라운드에 물어본다. 백그라운드가 정책의 실제
  // 주인(에이전트)이므로, 콘텐츠 스크립트의 캐시가 아직 안 올라왔어도 정확하다.
  document.addEventListener(
    "change",
    function (e) {
      var inp = e.target;
      if (!(inp instanceof HTMLInputElement) || inp.type !== "file") return;
      if (passNext.has(inp)) {
        passNext.delete(inp);
        return; // 우리가 승인 후 다시 보낸 이벤트
      }
      if (!inp.files || inp.files.length === 0) return;
      e.stopImmediatePropagation();
      e.preventDefault();
      decide(inp, Array.prototype.slice.call(inp.files));
    },
    true
  );

  function release(inp) {
    passNext.add(inp);
    try {
      inp.dispatchEvent(new Event("change", { bubbles: true }));
    } catch (e) {
      passNext.delete(inp);
    }
  }

  // blockMode reports whether this site would block (차단 모드 & 예외 아님).
  // Used as a fail-closed fallback when the background can't be reached.
  function blockMode() {
    return policy.mode === 2 && !hostExcepted();
  }

  function block(inp, reason, name) {
    try {
      inp.value = "";
    } catch (e) {}
    showBlock(reason, name);
  }

  async function decide(inp, files) {
    // 1) 이 사이트가 관리 대상인지(기록만/차단) 먼저 확인. 꺼짐이면 그냥 통과.
    var gate = await send({ type: "gate", host: location.hostname });
    if (!gate) {
      // 백그라운드 응답 없음 → 차단 모드면 안전하게 차단, 그 외엔 통과.
      if (blockMode()) block(inp, "첨부 확인 중이라 잠시 제한됩니다. 잠시 후 다시 시도하세요.");
      else release(inp);
      return;
    }
    if (!gate.manage) {
      release(inp);
      return;
    }
    // 2) 파일 지문을 만들어 허용 여부를 묻는다(에이전트가 기록도 남긴다).
    var fps = await Promise.all(files.map(fingerprint));
    var resp = await send({ type: "check", host: location.hostname, files: fps });
    if (!resp) {
      if (blockMode()) block(inp, "첨부 확인에 실패해 제한되었습니다. 잠시 후 다시 시도하세요.");
      else release(inp);
      return;
    }
    if (resp.allow === false) {
      block(inp, resp.reason, resp.blocked);
      return;
    }
    release(inp);
  }

  // ---- 드래그&드롭 업로드 ----
  // 드롭은 해시를 미리 계산할 수 없다(동기 처리 필요). 차단 모드(예외 아님)에선
  // 막고 첨부 버튼 사용을 안내한다. 기록만 모드에선 통과시키되 기록은 남긴다.
  document.addEventListener(
    "drop",
    function (e) {
      if (policy.mode === 0) return;
      var dt = e.dataTransfer;
      if (!dt) return;
      var types = Array.prototype.slice.call(dt.types || []);
      if (types.indexOf("Files") < 0) return;
      var files = Array.prototype.slice.call(dt.files || []);
      if (blockMode()) {
        e.preventDefault();
        e.stopImmediatePropagation();
        showBlock("드래그&드롭 업로드는 제한됩니다. 첨부(파일 선택) 버튼으로 올려 주세요. 반출 승인된 파일만 첨부됩니다.", "");
      }
      // 기록(차단이든 허용이든): 에이전트가 감사 로그에 남긴다.
      if (files.length) logDrop(files);
    },
    true
  );

  // logDrop reports dropped files to the agent for the audit log (fire and
  // forget). The check call records them as a side effect.
  async function logDrop(files) {
    var fps = await Promise.all(files.map(fingerprint));
    send({ type: "check", host: location.hostname, files: fps });
  }

  // ---- 안내 표시 ----
  var toast = null;
  var toastTimer = null;
  function showBlock(reason, name) {
    var text = reason || "반출 승인된 파일만 웹에 첨부할 수 있습니다.";
    if (name) text = "‘" + name + "’ 은(는) 첨부할 수 없습니다.\n" + text;
    try {
      if (!toast) {
        toast = document.createElement("div");
        toast.setAttribute("data-docvault", "1");
        var s = toast.style;
        s.position = "fixed";
        s.zIndex = "2147483647";
        s.top = "18px";
        s.left = "50%";
        s.transform = "translateX(-50%)";
        s.maxWidth = "440px";
        s.background = "#1f2430";
        s.color = "#fff";
        s.font = "14px/1.5 '맑은 고딕','Malgun Gothic',sans-serif";
        s.padding = "14px 18px";
        s.borderRadius = "10px";
        s.boxShadow = "0 8px 30px rgba(0,0,0,.35)";
        s.whiteSpace = "pre-wrap";
        s.borderLeft = "4px solid #ff5b5b";
        s.pointerEvents = "none";
      }
      toast.textContent = "🔒 DocVault\n" + text;
      if (!toast.parentNode) (document.body || document.documentElement).appendChild(toast);
      clearTimeout(toastTimer);
      toastTimer = setTimeout(function () {
        if (toast && toast.parentNode) toast.parentNode.removeChild(toast);
      }, 6000);
    } catch (e) {}
  }
})();
