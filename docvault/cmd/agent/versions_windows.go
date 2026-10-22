//go:build windows

package main

import (
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"unsafe"
)

// Listbox styles/messages (not defined elsewhere in the package).
const (
	lbsNotify               = 0x0001
	lbsHasStrings           = 0x0040
	lbsNoIntegralHt         = 0x0100
	lbAddString             = 0x0180
	lbGetCurSel             = 0x0188
	lbSetCurSel             = 0x0186
	lbnDblClk               = 2
	idVerList       uintptr = 101
)

// versDlg is the "이전 버전" window opened from Explorer's right-click menu.
var versDlg struct {
	hwnd, list, msg, ok uintptr
	client              *client
	drive               Drive
	path                string
	versions            []verInfo
}

func cmdVersions(cfg *Config, local string) error {
	tok := loadToken()
	if tok == "" || cfg.Server == "" {
		msgBox(0, "DocVault에 로그인되어 있지 않습니다.\n작업 표시줄의 DocVault 아이콘에서 로그인하세요.", mbIconWarning)
		return nil
	}
	c := newClient(cfg, tok)
	d, p, err := driveTarget(c, local)
	switch {
	case err == errUnauthorized:
		msgBox(0, "로그인이 만료되었습니다.\n작업 표시줄의 DocVault 아이콘에서 다시 로그인하세요.", mbIconWarning)
		return nil
	case err != nil:
		msgBox(0, err.Error(), mbIconInformation)
		return nil
	}
	list, err := fetchVersions(c, d, p)
	if err != nil {
		msgBox(0, "이전 버전을 불러오지 못했습니다: "+err.Error(), mbIconWarning)
		return nil
	}
	versDlg.client, versDlg.drive, versDlg.path, versDlg.versions = c, d, p, list
	showVersionsDialog(filepath.Base(local), d.DriveLetter+": "+d.Name+"  "+strings.ReplaceAll(p, "/", `\`))
	return nil
}

func showVersionsDialog(name, where string) {
	runtime.LockOSThread()
	inst, _, _ := pGetModuleHandleW.Call(0)
	hdc, _, _ := pGetDC.Call(0)
	dpi, _, _ := pGetDeviceCaps.Call(hdc, logPixelsY)
	pReleaseDC.Call(0, hdc)
	if dpi == 0 {
		dpi = 96
	}
	s := func(v int) uintptr { return uintptr(v * int(dpi) / 96) }
	face := wstr("맑은 고딕")
	font, _, _ := pCreateFontW.Call(uintptr(-int(s(15))&0xffffffff), 0, 0, 0, 400, 0, 0, 0, 1, 0, 0, 5, 0, ptr(face))
	bold, _, _ := pCreateFontW.Call(uintptr(-int(s(18))&0xffffffff), 0, 0, 0, 700, 0, 0, 0, 1, 0, 0, 5, 0, ptr(face))
	mono, _, _ := pCreateFontW.Call(uintptr(-int(s(14))&0xffffffff), 0, 0, 0, 400, 0, 0, 0, 1, 0, 0, 5, 0, ptr(wstr("Consolas")))
	runtime.KeepAlive(face)

	cursor, _, _ := pLoadCursorW.Call(0, idcArrow)
	cls := wstr("DocVaultVersions")
	wc := wndClassEx{WndProc: syscall.NewCallback(versProc), Instance: inst, Cursor: cursor, Background: colorWindow + 1, ClassName: cls}
	wc.Size = uint32(unsafe.Sizeof(wc))
	pRegisterClassExW.Call(uintptr(unsafe.Pointer(&wc)))

	sw, _, _ := pGetSystemMetrics.Call(smCxScreen)
	sh, _, _ := pGetSystemMetrics.Call(smCyScreen)
	w, h := s(600), s(452)
	title := wstr("DocVault 이전 버전")
	hwnd, _, _ := pCreateWindowExW.Call(wsExControlParent, ptr(cls), ptr(title), wsCaption|wsSysMenu,
		(sw-w)/2, (sh-h)/2, w, h, 0, 0, inst, 0)
	runtime.KeepAlive(cls)
	runtime.KeepAlive(title)
	versDlg.hwnd = hwnd

	ctl := func(class, text string, style, exStyle uintptr, x, y, cw, ch int, id uintptr, f uintptr) uintptr {
		c, t := wstr(class), wstr(text)
		hw, _, _ := pCreateWindowExW.Call(exStyle, ptr(c), ptr(t), wsChild|wsVisible|style,
			s(x), s(y), s(cw), s(ch), hwnd, id, inst, 0)
		runtime.KeepAlive(c)
		runtime.KeepAlive(t)
		pSendMessageW.Call(hw, wmSetFont, f, 1)
		return hw
	}
	ctl("STATIC", name, 0, 0, 20, 16, 550, 24, 0, bold)
	ctl("STATIC", where, 0, 0, 20, 42, 550, 20, 0, font)
	ctl("STATIC", "되돌릴 버전을 고른 뒤 [이 버전으로 되돌리기]를 누르세요. (되돌려도 기존 내용은 사라지지 않습니다)", 0, 0, 20, 66, 550, 20, 0, font)
	versDlg.list = ctl("LISTBOX", "", wsTabStop|lbsNotify|lbsHasStrings|lbsNoIntegralHt|wsVScroll, wsExClientEdge,
		20, 92, 558, 248, idVerList, mono)
	versDlg.msg = ctl("STATIC", "", 0, 0, 20, 350, 558, 20, 0, font)
	versDlg.ok = ctl("BUTTON", "이 버전으로 되돌리기", wsTabStop|bsDefPushButton, 0, 250, 378, 180, 34, idLogin, font)
	ctl("BUTTON", "닫기", wsTabStop, 0, 440, 378, 120, 34, idCancel, font)

	for _, v := range versDlg.versions {
		t := wstr(verLabel(v))
		pSendMessageW.Call(versDlg.list, lbAddString, 0, ptr(t))
		runtime.KeepAlive(t)
	}
	// Pre-select the newest older version (index 1); fall back to current.
	sel := 0
	if len(versDlg.versions) > 1 {
		sel = 1
	}
	pSendMessageW.Call(versDlg.list, lbSetCurSel, uintptr(sel), 0)
	if len(versDlg.versions) <= 1 {
		setText(versDlg.msg, "이전 버전이 없습니다. (현재 버전뿐입니다)")
		pEnableWindow.Call(versDlg.ok, 0)
	}

	pShowWindow.Call(hwnd, swShow)
	pSetForegroundWindow.Call(hwnd)
	pSetFocus.Call(versDlg.list)

	var m winMsg
	for {
		r, _, _ := pGetMessageW.Call(uintptr(unsafe.Pointer(&m)), 0, 0, 0)
		if int32(r) <= 0 {
			break
		}
		if d, _, _ := pIsDialogMessageW.Call(hwnd, uintptr(unsafe.Pointer(&m))); d != 0 {
			continue
		}
		pTranslateMessage.Call(uintptr(unsafe.Pointer(&m)))
		pDispatchMessageW.Call(uintptr(unsafe.Pointer(&m)))
	}
}

func doRestore() {
	i, _, _ := pSendMessageW.Call(versDlg.list, lbGetCurSel, 0, 0)
	idx := int(int32(i))
	if idx < 0 || idx >= len(versDlg.versions) {
		setText(versDlg.msg, "되돌릴 버전을 선택하세요.")
		return
	}
	v := versDlg.versions[idx]
	if v.Current {
		setText(versDlg.msg, "현재 버전입니다. 이전 버전을 선택하세요.")
		return
	}
	if msgBox(versDlg.hwnd, "선택한 버전으로 되돌립니다:\n\n"+verLabel(v)+"\n\n되돌려도 지금 내용은 버전 기록에 그대로 남습니다.\n진행할까요?", mbYesNo|mbIconQuestion) != idYes {
		return
	}
	pEnableWindow.Call(versDlg.ok, 0)
	setText(versDlg.msg, "되돌리는 중...")
	if err := restoreVersionReq(versDlg.client, versDlg.drive, versDlg.path, v.ID); err != nil {
		setText(versDlg.msg, "되돌리지 못했습니다: "+err.Error())
		pEnableWindow.Call(versDlg.ok, 1)
		return
	}
	pDestroyWindow.Call(versDlg.hwnd)
	msgBox(0, "선택한 버전으로 되돌렸습니다.\n\n열려 있던 문서는 닫았다가 다시 열면 바뀐 내용이 보입니다.", mbIconInformation)
}

func versProc(hwnd, msg, wparam, lparam uintptr) uintptr {
	switch uint32(msg) {
	case wmCommand:
		switch wparam & 0xffff {
		case idLogin:
			doRestore()
			return 0
		case idCancel:
			pDestroyWindow.Call(hwnd)
			return 0
		case idVerList:
			if (wparam>>16)&0xffff == lbnDblClk {
				doRestore()
			}
			return 0
		}
	case wmCtlColorStatic:
		pSetBkMode.Call(wparam, transparent)
		if lparam == versDlg.msg {
			pSetTextColor.Call(wparam, 0x2F2FC6)
		}
		brush, _, _ := pGetStockObject.Call(whiteBrush)
		return brush
	case wmClose:
		pDestroyWindow.Call(hwnd)
		return 0
	case wmDestroy:
		pPostQuitMessage.Call(0)
		return 0
	}
	r, _, _ := pDefWindowProcW.Call(hwnd, msg, wparam, lparam)
	return r
}
