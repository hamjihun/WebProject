//go:build windows

package main

import (
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"unsafe"
)

const (
	esMultiline    = 0x0004
	esWantReturn   = 0x1000
	esAutoVScroll  = 0x0040
	wsVScroll      = 0x00200000
	bsAutoCheckbox = 0x0003
	bmGetCheck     = 0x00F0
	bmSetCheck     = 0x00F1
)

// exportDlg is the small "반출 신청" window opened from Explorer's menu.
var exportDlg struct {
	hwnd, reason, msg, ok, post uintptr
	client                      *client
	drive                       Drive
	path                        string
	done, posted                bool
}

func cmdExport(cfg *Config, local string) error {
	tok := loadToken()
	if tok == "" || cfg.Server == "" {
		msgBox(0, "DocVault에 로그인되어 있지 않습니다.\n작업 표시줄의 DocVault 아이콘에서 로그인하세요.", mbIconWarning)
		return nil
	}
	c := newClient(cfg, tok)
	d, p, err := exportTarget(c, local)
	switch {
	case err == errUnauthorized:
		msgBox(0, "로그인이 만료되었습니다.\n작업 표시줄의 DocVault 아이콘에서 다시 로그인하세요.", mbIconWarning)
		return nil
	case err != nil:
		msgBox(0, err.Error(), mbIconInformation)
		return nil
	}
	exportDlg.client, exportDlg.drive, exportDlg.path = c, d, p
	showExportDialog(filepath.Base(local), d.DriveLetter+": "+d.Name+"  "+strings.ReplaceAll(p, "/", `\`))
	if exportDlg.done {
		text := exportDoneText
		if exportDlg.posted {
			text = exportPostDoneText
		}
		msgBox(0, text, mbIconInformation)
	}
	return nil
}

func showExportDialog(name, where string) {
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
	runtime.KeepAlive(face)

	cursor, _, _ := pLoadCursorW.Call(0, idcArrow)
	cls := wstr("DocVaultExport")
	wc := wndClassEx{WndProc: syscall.NewCallback(exportProc), Instance: inst, Cursor: cursor, Background: colorWindow + 1, ClassName: cls}
	wc.Size = uint32(unsafe.Sizeof(wc))
	pRegisterClassExW.Call(uintptr(unsafe.Pointer(&wc)))

	sw, _, _ := pGetSystemMetrics.Call(smCxScreen)
	sh, _, _ := pGetSystemMetrics.Call(smCyScreen)
	w, h := s(440), s(362)
	title := wstr("DocVault 반출 신청")
	hwnd, _, _ := pCreateWindowExW.Call(wsExControlParent, ptr(cls), ptr(title), wsCaption|wsSysMenu,
		(sw-w)/2, (sh-h)/2, w, h, 0, 0, inst, 0)
	runtime.KeepAlive(cls)
	runtime.KeepAlive(title)
	exportDlg.hwnd = hwnd

	ctl := func(class, text string, style, exStyle uintptr, x, y, cw, ch, id int, f uintptr) uintptr {
		c, t := wstr(class), wstr(text)
		hw, _, _ := pCreateWindowExW.Call(exStyle, ptr(c), ptr(t), wsChild|wsVisible|style,
			s(x), s(y), s(cw), s(ch), hwnd, uintptr(id), inst, 0)
		runtime.KeepAlive(c)
		runtime.KeepAlive(t)
		pSendMessageW.Call(hw, wmSetFont, f, 1)
		return hw
	}
	ctl("STATIC", name, 0, 0, 20, 16, 390, 24, 0, bold)
	ctl("STATIC", where, 0, 0, 20, 42, 390, 20, 0, font)
	ctl("STATIC", "반출 사유 (결재자가 봅니다)", 0, 0, 20, 74, 390, 20, 0, font)
	exportDlg.reason = ctl("EDIT", "", wsTabStop|esMultiline|esWantReturn|esAutoVScroll|wsVScroll, wsExClientEdge, 20, 96, 384, 90, 0, font)
	exportDlg.post = ctl("BUTTON", "후결재 (지금 바로 반출 폴더에 넣고, 결재는 나중에)", wsTabStop|bsAutoCheckbox, 0, 20, 192, 390, 24, 0, font)
	exportDlg.msg = ctl("STATIC", "", 0, 0, 20, 222, 390, 20, 0, font)
	exportDlg.ok = ctl("BUTTON", "반출 신청", wsTabStop|bsDefPushButton, 0, 196, 254, 100, 34, idLogin, font)
	ctl("BUTTON", "취소", wsTabStop, 0, 304, 254, 100, 34, idCancel, font)

	pShowWindow.Call(hwnd, swShow)
	pSetForegroundWindow.Call(hwnd)
	pSetFocus.Call(exportDlg.reason)

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

func exportProc(hwnd, msg, wparam, lparam uintptr) uintptr {
	switch uint32(msg) {
	case wmCommand:
		switch wparam & 0xffff {
		case idLogin:
			reason := strings.TrimSpace(getText(exportDlg.reason))
			if reason == "" {
				setText(exportDlg.msg, "반출 사유를 입력하세요.")
				pSetFocus.Call(exportDlg.reason)
				return 0
			}
			pEnableWindow.Call(exportDlg.ok, 0)
			setText(exportDlg.msg, "신청하는 중...")
			post, _, _ := pSendMessageW.Call(exportDlg.post, bmGetCheck, 0, 0)
			if err := requestExport(exportDlg.client, exportDlg.drive, exportDlg.path, reason, post == 1); err != nil {
				setText(exportDlg.msg, "신청하지 못했습니다: "+err.Error())
				pEnableWindow.Call(exportDlg.ok, 1)
				return 0
			}
			exportDlg.done, exportDlg.posted = true, post == 1
			pDestroyWindow.Call(hwnd)
			return 0
		case idCancel:
			pDestroyWindow.Call(hwnd)
			return 0
		}
	case wmCtlColorStatic:
		pSetBkMode.Call(wparam, transparent)
		if lparam == exportDlg.msg {
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
