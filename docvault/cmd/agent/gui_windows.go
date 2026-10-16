//go:build windows

package main

// Windows user interface of the agent, written directly against the Win32 API
// (no extra runtime to install): a login window for ID and password, and an
// icon in the notification area (작업 표시줄 오른쪽 아래) whose menu shows the
// connected drives and offers reconnect, version info, logout and exit.

import (
	_ "embed"
	"errors"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"syscall"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

//go:embed docvault.ico
var iconData []byte

var (
	user32   = windows.NewLazySystemDLL("user32.dll")
	gdi32    = windows.NewLazySystemDLL("gdi32.dll")
	shell32  = windows.NewLazySystemDLL("shell32.dll")
	kernel32 = windows.NewLazySystemDLL("kernel32.dll")

	pRegisterClassExW       = user32.NewProc("RegisterClassExW")
	pCreateWindowExW        = user32.NewProc("CreateWindowExW")
	pDefWindowProcW         = user32.NewProc("DefWindowProcW")
	pGetMessageW            = user32.NewProc("GetMessageW")
	pTranslateMessage       = user32.NewProc("TranslateMessage")
	pDispatchMessageW       = user32.NewProc("DispatchMessageW")
	pIsDialogMessageW       = user32.NewProc("IsDialogMessageW")
	pPostMessageW           = user32.NewProc("PostMessageW")
	pPostQuitMessage        = user32.NewProc("PostQuitMessage")
	pShowWindow             = user32.NewProc("ShowWindow")
	pSetWindowTextW         = user32.NewProc("SetWindowTextW")
	pGetWindowTextW         = user32.NewProc("GetWindowTextW")
	pEnableWindow           = user32.NewProc("EnableWindow")
	pSendMessageW           = user32.NewProc("SendMessageW")
	pDestroyWindow          = user32.NewProc("DestroyWindow")
	pCreatePopupMenu        = user32.NewProc("CreatePopupMenu")
	pAppendMenuW            = user32.NewProc("AppendMenuW")
	pTrackPopupMenu         = user32.NewProc("TrackPopupMenu")
	pDestroyMenu            = user32.NewProc("DestroyMenu")
	pSetForegroundWindow    = user32.NewProc("SetForegroundWindow")
	pGetCursorPos           = user32.NewProc("GetCursorPos")
	pMessageBoxW            = user32.NewProc("MessageBoxW")
	pLoadImageW             = user32.NewProc("LoadImageW")
	pLoadCursorW            = user32.NewProc("LoadCursorW")
	pGetSystemMetrics       = user32.NewProc("GetSystemMetrics")
	pSetFocus               = user32.NewProc("SetFocus")
	pRegisterWindowMessageW = user32.NewProc("RegisterWindowMessageW")
	pGetDC                  = user32.NewProc("GetDC")
	pReleaseDC              = user32.NewProc("ReleaseDC")
	pGetDeviceCaps          = gdi32.NewProc("GetDeviceCaps")
	pCreateFontW            = gdi32.NewProc("CreateFontW")
	pGetStockObject         = gdi32.NewProc("GetStockObject")
	pSetBkMode              = gdi32.NewProc("SetBkMode")
	pSetTextColor           = gdi32.NewProc("SetTextColor")
	pShellNotifyIconW       = shell32.NewProc("Shell_NotifyIconW")
	pGetModuleHandleW       = kernel32.NewProc("GetModuleHandleW")
)

const (
	wmDestroy          = 0x0002
	wmClose            = 0x0010
	wmEndSession       = 0x0016
	wmSetFont          = 0x0030
	wmCommand          = 0x0111
	wmCtlColorStatic   = 0x0138
	wmLButtonUp        = 0x0202
	wmRButtonUp        = 0x0205
	wmApp              = 0x8000
	wmTray             = wmApp + 1 // notification-area icon events
	wmState            = wmApp + 2 // drives/state changed: refresh tooltip
	wmShowLogin        = wmApp + 3
	wmLoginResult      = wmApp + 4
	wmBalloon          = wmApp + 5
	wsCaption          = 0x00C00000
	wsSysMenu          = 0x00080000
	wsMinimizeBox      = 0x00020000
	wsVisible          = 0x10000000
	wsChild            = 0x40000000
	wsTabStop          = 0x00010000
	wsExClientEdge     = 0x00000200
	wsExControlParent  = 0x00010000
	esAutoHScroll      = 0x0080
	esPassword         = 0x0020
	bsDefPushButton    = 0x0001
	mfString           = 0x0000
	mfGrayed           = 0x0001
	mfSeparator        = 0x0800
	tpmRightButton     = 0x0002
	tpmReturnCmd       = 0x0100
	nimAdd             = 0
	nimModify          = 1
	nimDelete          = 2
	nifMessage         = 0x01
	nifIcon            = 0x02
	nifTip             = 0x04
	nifInfo            = 0x10
	niifInfo           = 0x01
	niifWarning        = 0x02
	mbOK               = 0x00
	mbYesNo            = 0x04
	mbIconError        = 0x10
	mbIconQuestion     = 0x20
	mbIconWarning      = 0x30
	mbIconInformation  = 0x40
	mbSetForeground    = 0x10000
	idYes              = 6
	imageIcon          = 1
	lrLoadFromFile     = 0x10
	idcArrow           = 32512
	smCxScreen         = 0
	smCyScreen         = 1
	smCxSmIcon         = 49
	logPixelsY         = 90
	swShow             = 5
	swHide             = 0
	colorWindow        = 5
	whiteBrush         = 0
	transparent        = 1
	idLogin            = 1 // IDOK: also sent when Enter is pressed in the login window
	idCancel           = 2
	cmdOpenPC          = 2001
	cmdOpenWeb         = 2002
	cmdReconnect       = 2003
	cmdAbout           = 2004
	menuLogout         = 2005
	cmdExit            = 2006
	cmdShowLogin       = 2007
	cmdOpenLogs        = 2008
	windowTitle        = "DocVault 문서 드라이브"
	singleInstanceName = `Local\DocVaultAgent`
)

type wndClassEx struct {
	Size       uint32
	Style      uint32
	WndProc    uintptr
	ClsExtra   int32
	WndExtra   int32
	Instance   uintptr
	Icon       uintptr
	Cursor     uintptr
	Background uintptr
	MenuName   *uint16
	ClassName  *uint16
	IconSm     uintptr
}

type point struct{ X, Y int32 }

type winMsg struct {
	Hwnd    uintptr
	Message uint32
	WParam  uintptr
	LParam  uintptr
	Time    uint32
	Pt      point
	Private uint32
}

type notifyIconData struct {
	CbSize           uint32
	HWnd             uintptr
	UID              uint32
	UFlags           uint32
	UCallbackMessage uint32
	HIcon            uintptr
	SzTip            [128]uint16
	DwState          uint32
	DwStateMask      uint32
	SzInfo           [256]uint16
	UVersion         uint32
	SzInfoTitle      [64]uint16
	DwInfoFlags      uint32
	GuidItem         windows.GUID
	HBalloonIcon     uintptr
}

func wstr(s string) *uint16 {
	p, _ := windows.UTF16PtrFromString(s)
	return p
}

func putW(dst []uint16, s string) {
	u, _ := windows.UTF16FromString(s)
	n := copy(dst[:len(dst)-1], u)
	dst[n] = 0
}

func ptr(p *uint16) uintptr { return uintptr(unsafe.Pointer(p)) }

// gui holds the window handles and the session state shown in the menu.
type gui struct {
	cfg                                    *Config
	ag                                     *agent
	inst                                   uintptr
	dpi                                    int
	font                                   uintptr
	big                                    uintptr
	icon                                   uintptr
	tray                                   uintptr // hidden window that owns the notification icon
	login                                  uintptr
	idBox, pwBox, srvBox, loginBtn, msgLbl uintptr
	taskbarCreated                         uint32
	trayAdded                              bool

	mu        sync.Mutex
	user      string
	drives    []Drive
	serverErr bool
	loginMsg  string
	balloon   [2]string
	warn      bool
	loggedIn  bool
	stop      chan struct{}
	refresh   chan struct{}
}

var ui *gui

func (g *gui) s(v int) int { return v * g.dpi / 96 }

func (g *gui) post(msg uint32) { pPostMessageW.Call(g.tray, uintptr(msg), 0, 0) }

func msgBox(owner uintptr, text string, flags uintptr) uintptr {
	t, c := wstr(text), wstr(windowTitle)
	r, _, _ := pMessageBoxW.Call(owner, ptr(t), ptr(c), flags|mbSetForeground)
	runtime.KeepAlive(t)
	runtime.KeepAlive(c)
	return r
}

func setText(h uintptr, s string) {
	p := wstr(s)
	pSetWindowTextW.Call(h, ptr(p))
	runtime.KeepAlive(p)
}

func getText(h uintptr) string {
	buf := make([]uint16, 512)
	pGetWindowTextW.Call(h, uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)))
	return windows.UTF16ToString(buf)
}

// runApp is the Windows entry point for "run": tray icon + login window.
func runApp(cfg *Config) error {
	runtime.LockOSThread() // all windows live on this thread
	defer openLog()()

	mutexName := wstr(singleInstanceName)
	if _, err := windows.CreateMutex(nil, false, mutexName); errors.Is(err, windows.ERROR_ALREADY_EXISTS) {
		msgBox(0, "DocVault가 이미 실행 중입니다.\n작업 표시줄 오른쪽 아래의 DocVault 아이콘을 확인하세요.", mbIconInformation)
		return nil
	}
	if _, err := os.Stat(cfg.Rclone); err != nil {
		msgBox(0, "드라이브 연결 도구(rclone)를 찾을 수 없습니다.\nDocVault를 다시 설치하세요.\n\n"+cfg.Rclone, mbIconError)
		return err
	}

	g := &gui{cfg: cfg, refresh: make(chan struct{}, 1)}
	ui = g
	notifyBlocked = func(title, text string) { g.queueWarning(title, text) }
	g.ag = newAgent(cfg)
	g.inst, _, _ = pGetModuleHandleW.Call(0)
	hdc, _, _ := pGetDC.Call(0)
	dpi, _, _ := pGetDeviceCaps.Call(hdc, logPixelsY)
	pReleaseDC.Call(0, hdc)
	g.dpi = int(dpi)
	if g.dpi <= 0 {
		g.dpi = 96
	}
	face := wstr("맑은 고딕")
	f, _, _ := pCreateFontW.Call(uintptr(-g.s(15)&0xffffffff), 0, 0, 0, 400, 0, 0, 0, 1, 0, 0, 5, 0, ptr(face))
	b, _, _ := pCreateFontW.Call(uintptr(-g.s(22)&0xffffffff), 0, 0, 0, 700, 0, 0, 0, 1, 0, 0, 5, 0, ptr(face))
	runtime.KeepAlive(face)
	g.font, g.big = f, b

	iconPath := filepath.Join(stateDir(), "docvault.ico")
	os.MkdirAll(stateDir(), 0o700)
	os.WriteFile(iconPath, iconData, 0o600)
	ip := wstr(iconPath)
	sz, _, _ := pGetSystemMetrics.Call(smCxSmIcon)
	g.icon, _, _ = pLoadImageW.Call(0, ptr(ip), imageIcon, sz, sz, lrLoadFromFile)
	bigIcon, _, _ := pLoadImageW.Call(0, ptr(ip), imageIcon, 32, 32, lrLoadFromFile)
	runtime.KeepAlive(ip)

	cursor, _, _ := pLoadCursorW.Call(0, idcArrow)
	for _, c := range []struct {
		name string
		proc uintptr
	}{{"DocVaultTray", syscall.NewCallback(trayProc)}, {"DocVaultLogin", syscall.NewCallback(loginProc)}} {
		wc := wndClassEx{WndProc: c.proc, Instance: g.inst, Icon: bigIcon, IconSm: g.icon, Cursor: cursor,
			Background: colorWindow + 1, ClassName: wstr(c.name)}
		wc.Size = uint32(unsafe.Sizeof(wc))
		pRegisterClassExW.Call(uintptr(unsafe.Pointer(&wc)))
		runtime.KeepAlive(wc.ClassName)
	}
	cls, title := wstr("DocVaultTray"), wstr("DocVault")
	g.tray, _, _ = pCreateWindowExW.Call(0, ptr(cls), ptr(title), 0, 0, 0, 0, 0, 0, 0, g.inst, 0)
	runtime.KeepAlive(cls)
	runtime.KeepAlive(title)
	tc := wstr("TaskbarCreated")
	r, _, _ := pRegisterWindowMessageW.Call(ptr(tc))
	runtime.KeepAlive(tc)
	g.taskbarCreated = uint32(r)

	os.RemoveAll(cfg.CacheDir)
	log.Printf("DocVault 에이전트 %s 시작 (서버 %s)", version, cfg.Server)
	g.addTray()
	if cfg.Server != "" && loadToken() != "" {
		g.startSession()
	} else {
		g.showLogin("")
	}

	var m winMsg
	for {
		r, _, _ := pGetMessageW.Call(uintptr(unsafe.Pointer(&m)), 0, 0, 0)
		if int32(r) <= 0 {
			break
		}
		if g.login != 0 {
			if d, _, _ := pIsDialogMessageW.Call(g.login, uintptr(unsafe.Pointer(&m))); d != 0 {
				continue
			}
		}
		pTranslateMessage.Call(uintptr(unsafe.Pointer(&m)))
		pDispatchMessageW.Call(uintptr(unsafe.Pointer(&m)))
	}
	g.endSession()
	g.removeTray()
	log.Printf("종료합니다")
	return nil
}

// ---- notification-area icon ----

func (g *gui) nid() *notifyIconData {
	n := &notifyIconData{HWnd: g.tray, UID: 1, UCallbackMessage: wmTray, HIcon: g.icon}
	n.CbSize = uint32(unsafe.Sizeof(*n))
	return n
}

func (g *gui) addTray() {
	n := g.nid()
	n.UFlags = nifMessage | nifIcon | nifTip
	putW(n.SzTip[:], g.tooltip())
	r, _, _ := pShellNotifyIconW.Call(nimAdd, uintptr(unsafe.Pointer(n)))
	g.trayAdded = r != 0
}

func (g *gui) removeTray() {
	if g.trayAdded {
		pShellNotifyIconW.Call(nimDelete, uintptr(unsafe.Pointer(g.nid())))
		g.trayAdded = false
	}
}

func (g *gui) tooltip() string {
	g.mu.Lock()
	defer g.mu.Unlock()
	switch {
	case !g.loggedIn:
		return "DocVault – 로그인이 필요합니다"
	case g.serverErr:
		return "DocVault – 서버에 연결할 수 없습니다"
	default:
		return fmt.Sprintf("DocVault – %s\n문서 드라이브 %d개 연결됨", g.user, len(g.drives))
	}
}

func (g *gui) updateTray() {
	n := g.nid()
	n.UFlags = nifTip
	putW(n.SzTip[:], g.tooltip())
	pShellNotifyIconW.Call(nimModify, uintptr(unsafe.Pointer(n)))
}

func (g *gui) showBalloon(title, text string, warn bool) {
	n := g.nid()
	n.UFlags = nifInfo
	putW(n.SzInfoTitle[:], title)
	putW(n.SzInfo[:], text)
	n.DwInfoFlags = niifInfo
	if warn {
		n.DwInfoFlags = niifWarning
	}
	pShellNotifyIconW.Call(nimModify, uintptr(unsafe.Pointer(n)))
}

func (g *gui) queueBalloon(title, text string) {
	g.mu.Lock()
	g.balloon = [2]string{title, text}
	g.warn = false
	g.mu.Unlock()
	g.post(wmBalloon)
}

func (g *gui) queueWarning(title, text string) {
	g.mu.Lock()
	g.balloon = [2]string{title, text}
	g.warn = true
	g.mu.Unlock()
	g.post(wmBalloon)
}

func (g *gui) showMenu() {
	g.mu.Lock()
	loggedIn, user, drives, serverErr := g.loggedIn, g.user, append([]Drive(nil), g.drives...), g.serverErr
	g.mu.Unlock()

	menu, _, _ := pCreatePopupMenu.Call()
	add := func(flags uintptr, id int, text string) {
		p := wstr(text)
		pAppendMenuW.Call(menu, flags, uintptr(id), ptr(p))
		runtime.KeepAlive(p)
	}
	sep := func() { pAppendMenuW.Call(menu, mfSeparator, 0, 0) }
	if loggedIn {
		add(mfString|mfGrayed, 1, "DocVault – "+user)
		sep()
		if serverErr {
			add(mfString|mfGrayed, 2, "⚠ 서버에 연결할 수 없습니다 (자동 재시도 중)")
		}
		if len(drives) == 0 && !serverErr {
			add(mfString|mfGrayed, 3, "사용할 수 있는 드라이브가 없습니다")
		}
		for i, d := range drives {
			add(mfString|mfGrayed, 100+i, fmt.Sprintf("%s:  %s   (%s)", d.DriveLetter, d.Name, levelName(d.Level)))
		}
		sep()
		add(mfString, cmdOpenPC, "내 PC 열기")
		add(mfString, cmdOpenWeb, "웹 문서함 열기 (버전·휴지통·반출)")
		add(mfString, cmdReconnect, "지금 다시 연결")
		sep()
		add(mfString, cmdAbout, "버전 정보")
		add(mfString, cmdOpenLogs, "로그 폴더 열기")
		add(mfString, menuLogout, "로그아웃")
	} else {
		add(mfString|mfGrayed, 1, "DocVault – 로그인이 필요합니다")
		sep()
		add(mfString, cmdShowLogin, "로그인...")
		add(mfString, cmdAbout, "버전 정보")
	}
	add(mfString, cmdExit, "종료")

	var pt point
	pGetCursorPos.Call(uintptr(unsafe.Pointer(&pt)))
	pSetForegroundWindow.Call(g.tray)
	cmd, _, _ := pTrackPopupMenu.Call(menu, tpmRightButton|tpmReturnCmd, uintptr(pt.X), uintptr(pt.Y), 0, g.tray, 0)
	pPostMessageW.Call(g.tray, 0, 0, 0)
	pDestroyMenu.Call(menu)
	g.onCommand(int(cmd))
}

func (g *gui) onCommand(cmd int) {
	switch cmd {
	case cmdOpenPC:
		exec.Command("explorer.exe", "shell:MyComputerFolder").Start()
	case cmdOpenWeb:
		openBrowser(g.cfg.Server)
	case cmdOpenLogs:
		exec.Command("explorer.exe", filepath.Join(stateDir(), "logs")).Start()
	case cmdReconnect:
		select {
		case g.refresh <- struct{}{}:
		default:
		}
		g.showBalloon("DocVault", "서버에 다시 연결하는 중입니다.", false)
	case cmdAbout:
		g.mu.Lock()
		var lines []string
		for _, d := range g.drives {
			lines = append(lines, fmt.Sprintf("   %s:  %s", d.DriveLetter, d.Name))
		}
		user := g.user
		if !g.loggedIn {
			user = "(로그인 안 됨)"
		}
		g.mu.Unlock()
		if len(lines) == 0 {
			lines = []string{"   (없음)"}
		}
		msgBox(g.tray, fmt.Sprintf("DocVault 문서 드라이브\n\n프로그램 버전:  %s\n서버:  %s\n사용자:  %s\n\n연결된 드라이브:\n%s\n\n로그 폴더:  %s",
			version, g.cfg.Server, user, strings.Join(lines, "\n"), filepath.Join(stateDir(), "logs")), mbIconInformation)
	case cmdShowLogin:
		g.showLogin("")
	case menuLogout:
		if msgBox(g.tray, "로그아웃하면 이 PC의 문서 드라이브 연결이 해제됩니다.\n열려 있는 문서는 먼저 저장하고 닫으세요.\n\n로그아웃할까요?", mbYesNo|mbIconQuestion) != idYes {
			return
		}
		tok := g.ag.client.token
		go func() {
			newClient(g.cfg, tok).call("POST", "/api/logout", map[string]string{}, nil)
			g.endSession()
			os.Remove(tokenPath())
			log.Printf("로그아웃")
			g.mu.Lock()
			g.loginMsg = "로그아웃했습니다."
			g.mu.Unlock()
			g.post(wmShowLogin)
		}()
	case cmdExit:
		g.mu.Lock()
		connected := g.loggedIn && len(g.drives) > 0
		g.mu.Unlock()
		if connected && msgBox(g.tray, "종료하면 이 PC의 문서 드라이브 연결이 해제됩니다.\n(다음에 Windows를 켜면 자동으로 다시 연결됩니다)\n\n종료할까요?", mbYesNo|mbIconQuestion) != idYes {
			return
		}
		if g.login != 0 {
			pDestroyWindow.Call(g.login)
			g.login = 0
		}
		pPostQuitMessage.Call(0)
	}
}

// ---- session ----

// startSession connects the drives and keeps them in sync in the background.
func (g *gui) startSession() {
	g.endSession()
	g.ag.client = newClient(g.cfg, loadToken())
	stop := make(chan struct{})
	g.mu.Lock()
	g.stop, g.loggedIn, g.serverErr = stop, true, false
	g.mu.Unlock()
	g.updateTray()
	go g.loop(stop)
}

// endSession disconnects every drive and stops syncing.
func (g *gui) endSession() {
	g.mu.Lock()
	stop := g.stop
	g.stop, g.loggedIn, g.drives = nil, false, nil
	g.mu.Unlock()
	if stop != nil {
		close(stop)
	}
	g.ag.stopAll()
	os.RemoveAll(g.cfg.CacheDir)
}

func (g *gui) loop(stop chan struct{}) {
	var me struct{ Username, DisplayName string }
	if err := g.ag.client.call("GET", "/api/me", nil, &me); err == nil {
		name := me.Username
		if me.DisplayName != "" {
			name = me.DisplayName + " (" + me.Username + ")"
		}
		g.mu.Lock()
		g.user = name
		g.mu.Unlock()
	}
	announced := false
	for {
		select {
		case <-stop:
			return
		default:
		}
		drives, err := g.ag.heartbeat()
		if errors.Is(err, errUnauthorized) {
			log.Printf("%v → 드라이브 연결 해제", err)
			g.endSession()
			os.Remove(tokenPath())
			g.mu.Lock()
			g.loginMsg = "로그인이 만료되었거나 관리자가 연결을 해제했습니다.\n다시 로그인하세요."
			g.mu.Unlock()
			g.post(wmShowLogin)
			return
		}
		g.mu.Lock()
		g.serverErr = err != nil
		if err == nil {
			g.drives = drives
		}
		g.mu.Unlock()
		if err != nil {
			log.Printf("서버 연결 실패: %v", err)
		}
		g.post(wmState)
		if err == nil && !announced {
			announced = true
			var names []string
			for _, d := range drives {
				names = append(names, d.DriveLetter+": "+d.Name)
			}
			if len(names) > 0 {
				g.queueBalloon("문서 드라이브를 연결했습니다", strings.Join(names, ", "))
			} else {
				g.queueBalloon("로그인했습니다", "사용 권한이 있는 드라이브가 없습니다. 관리자에게 문의하세요.")
			}
		}
		select {
		case <-stop:
			return
		case <-g.refresh:
		case <-time.After(time.Minute):
		}
	}
}

// ---- login window ----

func lastUserPath() string { return filepath.Join(stateDir(), "last-user.txt") }

func (g *gui) ctl(class, text string, style, exStyle uintptr, x, y, w, h, id int, font uintptr) uintptr {
	c, t := wstr(class), wstr(text)
	hwnd, _, _ := pCreateWindowExW.Call(exStyle, ptr(c), ptr(t), wsChild|wsVisible|style,
		uintptr(g.s(x)), uintptr(g.s(y)), uintptr(g.s(w)), uintptr(g.s(h)), g.login, uintptr(id), g.inst, 0)
	runtime.KeepAlive(c)
	runtime.KeepAlive(t)
	pSendMessageW.Call(hwnd, wmSetFont, font, 1)
	return hwnd
}

func (g *gui) showLogin(message string) {
	if message == "" {
		g.mu.Lock()
		message, g.loginMsg = g.loginMsg, ""
		g.mu.Unlock()
	}
	if g.login != 0 {
		setText(g.msgLbl, message)
		pShowWindow.Call(g.login, swShow)
		pSetForegroundWindow.Call(g.login)
		return
	}
	askServer := g.cfg.Server == ""
	width, height := 380, 340
	if askServer {
		height += 60
	}
	sw, _, _ := pGetSystemMetrics.Call(smCxScreen)
	sh, _, _ := pGetSystemMetrics.Call(smCyScreen)
	w, h := g.s(width), g.s(height)
	cls, title := wstr("DocVaultLogin"), wstr(windowTitle)
	g.login, _, _ = pCreateWindowExW.Call(wsExControlParent, ptr(cls), ptr(title), wsCaption|wsSysMenu|wsMinimizeBox,
		(sw-uintptr(w))/2, (sh-uintptr(h))/2, uintptr(w), uintptr(h), 0, 0, g.inst, 0)
	runtime.KeepAlive(cls)
	runtime.KeepAlive(title)

	y := 18
	g.ctl("STATIC", "DocVault", 0, 0, 24, y, 320, 32, 0, g.big)
	y += 34
	g.ctl("STATIC", "문서 드라이브를 사용하려면 회사 계정으로 로그인하세요.", 0, 0, 24, y, 330, 20, 0, g.font)
	y += 34
	if askServer {
		g.ctl("STATIC", "서버 주소 (예: 192.168.50.10:8080)", 0, 0, 24, y, 320, 20, 0, g.font)
		g.srvBox = g.ctl("EDIT", "", wsTabStop|esAutoHScroll, wsExClientEdge, 24, y+20, 316, 28, 0, g.font)
		y += 60
	}
	g.ctl("STATIC", "아이디", 0, 0, 24, y, 320, 20, 0, g.font)
	last, _ := os.ReadFile(lastUserPath())
	g.idBox = g.ctl("EDIT", strings.TrimSpace(string(last)), wsTabStop|esAutoHScroll, wsExClientEdge, 24, y+20, 316, 28, 0, g.font)
	y += 58
	g.ctl("STATIC", "비밀번호", 0, 0, 24, y, 320, 20, 0, g.font)
	g.pwBox = g.ctl("EDIT", "", wsTabStop|esAutoHScroll|esPassword, wsExClientEdge, 24, y+20, 316, 28, 0, g.font)
	y += 64
	g.loginBtn = g.ctl("BUTTON", "로그인", wsTabStop|bsDefPushButton, 0, 24, y, 316, 34, idLogin, g.font)
	y += 42
	g.msgLbl = g.ctl("STATIC", message, 0, 0, 24, y, 316, 40, 0, g.font)

	pShowWindow.Call(g.login, swShow)
	pSetForegroundWindow.Call(g.login)
	switch {
	case askServer:
		pSetFocus.Call(g.srvBox)
	case len(strings.TrimSpace(string(last))) > 0:
		pSetFocus.Call(g.pwBox)
	default:
		pSetFocus.Call(g.idBox)
	}
}

func (g *gui) doLogin() {
	id, pw := strings.TrimSpace(getText(g.idBox)), getText(g.pwBox)
	if g.srvBox != 0 {
		srv := strings.TrimSpace(getText(g.srvBox))
		if srv == "" {
			setText(g.msgLbl, "서버 주소를 입력하세요.")
			pSetFocus.Call(g.srvBox)
			return
		}
		if !strings.HasPrefix(srv, "http://") && !strings.HasPrefix(srv, "https://") {
			srv = "http://" + srv
		}
		g.cfg.Server = strings.TrimRight(srv, "/")
	}
	if id == "" || pw == "" {
		setText(g.msgLbl, "아이디와 비밀번호를 입력하세요.")
		return
	}
	setText(g.msgLbl, "로그인 중...")
	pEnableWindow.Call(g.loginBtn, 0)
	go func() {
		err := passwordLogin(g.cfg, id, pw)
		g.mu.Lock()
		if err != nil {
			g.loginMsg = err.Error()
			if strings.Contains(err.Error(), "dial") || strings.Contains(err.Error(), "connect") || strings.Contains(err.Error(), "timeout") {
				g.loginMsg = "서버에 연결할 수 없습니다.\n네트워크와 서버 상태를 확인하세요."
			}
		} else {
			g.loginMsg = ""
			os.WriteFile(lastUserPath(), []byte(id), 0o600)
			if g.srvBox != 0 {
				saveConfig(g.cfg)
			}
		}
		g.mu.Unlock()
		ok := uintptr(0)
		if err == nil {
			ok = 1
		}
		pPostMessageW.Call(g.tray, wmLoginResult, ok, 0)
	}()
}

func (g *gui) onLoginResult(ok bool) {
	g.mu.Lock()
	msg := g.loginMsg
	g.loginMsg = ""
	g.mu.Unlock()
	if !ok {
		if g.login != 0 {
			pEnableWindow.Call(g.loginBtn, 1)
			setText(g.msgLbl, msg)
			setText(g.pwBox, "")
			pSetFocus.Call(g.pwBox)
		}
		return
	}
	if g.login != 0 {
		pDestroyWindow.Call(g.login)
		g.login = 0
	}
	g.showBalloon("DocVault", "로그인했습니다. 문서 드라이브를 연결하는 중입니다...", false)
	g.startSession()
}

// ---- window procedures ----

func trayProc(hwnd, msg, wparam, lparam uintptr) uintptr {
	g := ui
	switch uint32(msg) {
	case wmTray:
		if l := uint32(lparam); l == wmLButtonUp || l == wmRButtonUp {
			g.showMenu()
		}
		return 0
	case wmState:
		g.updateTray()
		return 0
	case wmShowLogin:
		g.updateTray()
		g.showLogin("")
		return 0
	case wmLoginResult:
		g.onLoginResult(wparam == 1)
		return 0
	case wmBalloon:
		g.mu.Lock()
		b, warn := g.balloon, g.warn
		g.mu.Unlock()
		g.showBalloon(b[0], b[1], warn)
		return 0
	case wmEndSession:
		if wparam != 0 { // Windows is signing out or shutting down
			g.endSession()
		}
		return 0
	}
	if g != nil && g.taskbarCreated != 0 && uint32(msg) == g.taskbarCreated {
		g.addTray() // Explorer restarted: put the icon back
		return 0
	}
	r, _, _ := pDefWindowProcW.Call(hwnd, msg, wparam, lparam)
	return r
}

func loginProc(hwnd, msg, wparam, lparam uintptr) uintptr {
	g := ui
	switch uint32(msg) {
	case wmCommand:
		switch wparam & 0xffff {
		case idLogin:
			g.doLogin()
			return 0
		case idCancel:
			pSendMessageW.Call(hwnd, wmClose, 0, 0)
			return 0
		}
	case wmCtlColorStatic:
		pSetBkMode.Call(wparam, transparent)
		if lparam == g.msgLbl {
			pSetTextColor.Call(wparam, 0x2F2FC6) // red (BGR)
		}
		brush, _, _ := pGetStockObject.Call(whiteBrush)
		return brush
	case wmClose:
		// Closing the login window without signing in ends the program.
		pDestroyWindow.Call(hwnd)
		g.login = 0
		g.mu.Lock()
		loggedIn := g.loggedIn
		g.mu.Unlock()
		if !loggedIn {
			pPostQuitMessage.Call(0)
		}
		return 0
	case wmDestroy:
		return 0
	}
	r, _, _ := pDefWindowProcW.Call(hwnd, msg, wparam, lparam)
	return r
}
