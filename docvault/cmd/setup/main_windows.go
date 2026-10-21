//go:build windows

// docvault-setup.exe installs everything an employee PC needs in one step:
// WinFsp (virtual drive component), rclone, the DocVault agent, its server
// address and automatic start at Windows logon. When downloaded from the
// server's web page, the server address is already inside the file.
//
//	docvault-setup.exe              install or update
//	docvault-setup.exe /uninstall   remove
package main

import (
	"archive/zip"
	"bufio"
	"bytes"
	"embed"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
)

//go:embed payload
var payload embed.FS

const (
	appName     = "DocVault"
	trailerMark = "DVCFG1\x00\x00"
	uninstKey   = `SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\DocVault`
)

func installDir() string {
	pf := os.Getenv("ProgramFiles")
	if pf == "" {
		pf = `C:\Program Files`
	}
	return filepath.Join(pf, appName)
}

func startupLink() string {
	return filepath.Join(os.Getenv("ProgramData"), `Microsoft\Windows\Start Menu\Programs\StartUp`, appName+".lnk")
}

func logoutLink() string {
	return filepath.Join(os.Getenv("ProgramData"), `Microsoft\Windows\Start Menu\Programs`, "DocVault 로그아웃.lnk")
}

func startMenuLink() string {
	return filepath.Join(os.Getenv("ProgramData"), `Microsoft\Windows\Start Menu\Programs`, "DocVault 문서 드라이브.lnk")
}

func main() {
	uninstall := len(os.Args) > 1 && strings.Contains(strings.ToLower(os.Args[1]), "uninstall")
	if !windows.GetCurrentProcessToken().IsElevated() {
		if err := relaunchElevated(); err != nil {
			fmt.Println("관리자 권한이 필요합니다:", err)
			pause()
		}
		return
	}
	var err error
	if uninstall {
		err = doUninstall()
	} else {
		err = doInstall()
	}
	if err != nil {
		fmt.Println()
		fmt.Println("❌ 오류:", err)
		pause()
		os.Exit(1)
	}
}

func pause() {
	fmt.Println("\n엔터를 누르면 창이 닫힙니다.")
	bufio.NewReader(os.Stdin).ReadString('\n')
}

func relaunchElevated() error {
	exe, _ := os.Executable()
	verb, _ := syscall.UTF16PtrFromString("runas")
	file, _ := syscall.UTF16PtrFromString(exe)
	args, _ := syscall.UTF16PtrFromString(strings.Join(os.Args[1:], " "))
	return windows.ShellExecute(0, verb, file, args, nil, windows.SW_NORMAL)
}

func step(n int, msg string) { fmt.Printf("[%d/5] %s\n", n, msg) }

// serverFromTrailer reads the server address the web server appended to
// this file when it was downloaded.
func serverFromTrailer() string {
	exe, err := os.Executable()
	if err != nil {
		return ""
	}
	f, err := os.Open(exe)
	if err != nil {
		return ""
	}
	defer f.Close()
	st, _ := f.Stat()
	if st.Size() < 12 {
		return ""
	}
	tail := make([]byte, 12)
	f.ReadAt(tail, st.Size()-12)
	if string(tail[4:]) != trailerMark {
		return ""
	}
	n := int64(binary.LittleEndian.Uint32(tail[:4]))
	if n <= 0 || n > 4096 || n > st.Size()-12 {
		return ""
	}
	buf := make([]byte, n)
	f.ReadAt(buf, st.Size()-12-n)
	var cfg struct{ Server string }
	json.Unmarshal(buf, &cfg)
	return strings.TrimRight(cfg.Server, "/")
}

func existingServer() string {
	b, err := os.ReadFile(filepath.Join(installDir(), "agent.json"))
	if err != nil {
		return ""
	}
	var cfg struct{ Server string }
	json.Unmarshal(b, &cfg)
	return cfg.Server
}

func doInstall() error {
	fmt.Println("==============================================")
	fmt.Println("  DocVault 문서 드라이브 설치")
	fmt.Println("==============================================")
	server := serverFromTrailer()
	if server == "" {
		server = existingServer()
	}
	if server == "" {
		fmt.Print("문서중앙화 서버 주소 (예: http://192.168.50.10:8080): ")
		s, _ := bufio.NewReader(os.Stdin).ReadString('\n')
		s = strings.TrimSpace(s)
		if s == "" {
			return errors.New("서버 주소가 필요합니다")
		}
		if !strings.HasPrefix(s, "http") {
			s = "http://" + s
		}
		server = strings.TrimRight(s, "/")
	}
	fmt.Println("서버:", server)
	fmt.Println()

	step(1, "실행 중인 DocVault 종료")
	stopRunning()

	step(2, "가상 드라이브 구성요소(WinFsp) 확인")
	installedByUs := previouslyInstalledWinFsp()
	if winfspInstalled() {
		fmt.Println("      이미 설치되어 있습니다.")
	} else if err := installWinFsp(); err != nil {
		return err
	} else {
		installedByUs = true
	}

	step(3, "프로그램 복사: "+installDir())
	dir := installDir()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	if err := copyPayload("payload/docvault-agent.exe", filepath.Join(dir, "docvault-agent.exe")); err != nil {
		return err
	}
	if err := extractRclone(filepath.Join(dir, "rclone.exe")); err != nil {
		return err
	}
	cfg, _ := json.MarshalIndent(map[string]string{"server": server}, "", "  ")
	if err := os.WriteFile(filepath.Join(dir, "agent.json"), cfg, 0o644); err != nil {
		return err
	}
	if exe, err := os.Executable(); err == nil {
		copyFile(exe, filepath.Join(dir, "docvault-setup.exe")) // used by 앱 제거
	}

	step(4, "Windows 시작 시 자동 실행 등록")
	agent := filepath.Join(dir, "docvault-agent.exe")
	if err := makeShortcut(startupLink(), agent, ""); err != nil {
		return fmt.Errorf("시작프로그램 등록 실패: %w", err)
	}
	makeShortcut(startMenuLink(), agent, "")
	os.Remove(logoutLink()) // replaced by the menu of the notification-area icon
	registerUninstall(dir, installedByUs)
	setBrowserPolicies(server)
	addExportMenu(agent)

	step(5, "DocVault 시작")
	// Started through Explorer so it runs as the signed-in user (not as
	// administrator); drives mounted by an elevated process are invisible.
	exec.Command("explorer.exe", agent).Start()

	fmt.Println()
	fmt.Println("✅ 설치가 끝났습니다.")
	fmt.Println("   잠시 후 DocVault 로그인 창이 뜨면 아이디와 비밀번호를 입력하세요.")
	fmt.Println("   그다음부터는 Windows를 켤 때마다 드라이브가 자동으로 연결됩니다.")
	fmt.Println("   작업 표시줄 오른쪽 아래 DocVault 아이콘에서 상태 확인, 로그아웃을 할 수 있습니다.")
	time.Sleep(8 * time.Second)
	return nil
}

func stopRunning() {
	hidden := func(name string, args ...string) {
		c := exec.Command(name, args...)
		c.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
		c.Run()
	}
	hidden("taskkill", "/F", "/IM", "docvault-agent.exe")
	// only the rclone copies DocVault started, not other uses of rclone
	hidden("powershell", "-NoProfile", "-Command",
		`Get-Process rclone -ErrorAction SilentlyContinue | Where-Object { $_.Path -like '`+installDir()+`\*' } | Stop-Process -Force`)
	time.Sleep(time.Second)
}

func winfspInstalled() bool {
	for _, view := range []uint32{registry.WOW64_32KEY, registry.WOW64_64KEY} {
		if k, err := registry.OpenKey(registry.LOCAL_MACHINE, `SOFTWARE\WinFsp`, registry.QUERY_VALUE|view); err == nil {
			dir, _, err := k.GetStringValue("InstallDir")
			k.Close()
			if err == nil && dir != "" {
				if _, err := os.Stat(filepath.Join(dir, "bin", "winfsp-x64.dll")); err == nil {
					return true
				}
			}
		}
	}
	return false
}

func installWinFsp() error {
	msi := filepath.Join(os.TempDir(), "docvault-winfsp.msi")
	if err := copyPayload("payload/winfsp.msi", msi); err != nil {
		return err
	}
	defer os.Remove(msi)
	fmt.Println("      설치 중... (1분 정도 걸립니다)")
	cmd := exec.Command("msiexec", "/i", msi, "/qn", "/norestart")
	err := cmd.Run()
	var ee *exec.ExitError
	if errors.As(err, &ee) && ee.ExitCode() == 3010 { // installed, restart recommended
		fmt.Println("      설치되었습니다. (나중에 PC를 다시 시작하면 좋습니다)")
		return nil
	}
	if err != nil {
		return fmt.Errorf("WinFsp 설치 실패: %w", err)
	}
	fmt.Println("      설치되었습니다.")
	return nil
}

func copyPayload(name, dst string) error {
	src, err := payload.Open(name)
	if err != nil {
		return fmt.Errorf("설치 파일에 %s 이(가) 없습니다 (설치 파일을 다시 만들어야 합니다)", filepath.Base(name))
	}
	defer src.Close()
	return writeFile(dst, src)
}

func writeFile(dst string, r io.Reader) error {
	tmp := dst + ".new"
	f, err := os.Create(tmp)
	if err != nil {
		return err
	}
	if _, err := io.Copy(f, r); err != nil {
		f.Close()
		os.Remove(tmp)
		return err
	}
	f.Close()
	os.Remove(dst)
	return os.Rename(tmp, dst)
}

func copyFile(src, dst string) error {
	if strings.EqualFold(src, dst) {
		return nil
	}
	f, err := os.Open(src)
	if err != nil {
		return err
	}
	defer f.Close()
	return writeFile(dst, f)
}

func extractRclone(dst string) error {
	data, err := payload.ReadFile("payload/rclone.zip")
	if err != nil {
		return errors.New("설치 파일에 rclone.zip 이(가) 없습니다 (설치 파일을 다시 만들어야 합니다)")
	}
	zr, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		return err
	}
	for _, f := range zr.File {
		if strings.EqualFold(filepath.Base(f.Name), "rclone.exe") {
			rc, err := f.Open()
			if err != nil {
				return err
			}
			defer rc.Close()
			return writeFile(dst, rc)
		}
	}
	return errors.New("rclone.zip 안에 rclone.exe가 없습니다")
}

func makeShortcut(link, target, args string) error {
	os.MkdirAll(filepath.Dir(link), 0o755)
	ps := fmt.Sprintf(`$s=(New-Object -ComObject WScript.Shell).CreateShortcut('%s'); $s.TargetPath='%s'; $s.Arguments='%s'; $s.WorkingDirectory='%s'; $s.Description='DocVault 문서 드라이브'; $s.Save()`,
		strings.ReplaceAll(link, "'", "''"), strings.ReplaceAll(target, "'", "''"), args, strings.ReplaceAll(filepath.Dir(target), "'", "''"))
	c := exec.Command("powershell", "-NoProfile", "-Command", ps)
	c.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	out, err := c.CombinedOutput()
	if err != nil {
		return fmt.Errorf("%v %s", err, out)
	}
	return nil
}

// registerUninstall lists DocVault in Windows "앱 및 기능" so it can be removed there.
func registerUninstall(dir string, installedWinFsp bool) {
	k, _, err := registry.CreateKey(registry.LOCAL_MACHINE, uninstKey, registry.SET_VALUE|registry.WOW64_64KEY)
	if err != nil {
		return
	}
	defer k.Close()
	k.SetStringValue("DisplayName", "DocVault 문서 드라이브")
	k.SetStringValue("Publisher", "사내 문서중앙화")
	k.SetStringValue("InstallLocation", dir)
	k.SetStringValue("DisplayIcon", filepath.Join(dir, "docvault-agent.exe"))
	k.SetStringValue("UninstallString", `"`+filepath.Join(dir, "docvault-setup.exe")+`" /uninstall`)
	k.SetDWordValue("NoModify", 1)
	k.SetDWordValue("NoRepair", 1)
	// Remember whether WinFsp came with DocVault: only then is it removed
	// together with DocVault (another program may rely on a WinFsp it brought).
	var flag uint32
	if installedWinFsp {
		flag = 1
	}
	k.SetDWordValue("InstalledWinFsp", flag)
}

func previouslyInstalledWinFsp() bool {
	k, err := registry.OpenKey(registry.LOCAL_MACHINE, uninstKey, registry.QUERY_VALUE|registry.WOW64_64KEY)
	if err != nil {
		return false
	}
	defer k.Close()
	v, _, err := k.GetIntegerValue("InstalledWinFsp")
	return err == nil && v == 1
}

func doUninstall() error {
	fmt.Println("==============================================")
	fmt.Println("  DocVault 문서 드라이브 제거")
	fmt.Println("==============================================")
	dir := installDir()
	removeWinFsp := previouslyInstalledWinFsp()

	fmt.Println("[1/4] 드라이브 연결 해제, 로그아웃")
	// Sign this PC out on the server (best effort) before the program goes away.
	logout := exec.Command(filepath.Join(dir, "docvault-agent.exe"), "logout")
	logout.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	logout.Run()
	stopRunning()

	fmt.Println("[2/4] 프로그램, 바로가기, 자동 실행 삭제")
	os.Remove(startupLink())
	os.Remove(startMenuLink())
	os.Remove(logoutLink())
	for _, f := range []string{"docvault-agent.exe", "rclone.exe", "agent.json"} {
		os.Remove(filepath.Join(dir, f))
	}
	removeUserData()
	removeBrowserPolicies()
	removeExportMenu()

	fmt.Println("[3/4] 가상 드라이브 구성요소(WinFsp) 제거")
	restart := false
	if removeWinFsp {
		var err error
		if restart, err = uninstallWinFsp(); err != nil {
			fmt.Println("      WinFsp 제거 실패:", err, "(앱 및 기능에서 직접 제거하세요)")
		}
	} else {
		fmt.Println("      DocVault 설치 전부터 있던 WinFsp라서 남겨 둡니다.")
	}

	fmt.Println("[4/4] 마무리")
	registry.DeleteKey(registry.LOCAL_MACHINE, uninstKey)
	// This program itself lives in dir: remove the folder after it exits.
	// CmdLine is passed as-is: cmd.exe does not understand Go's \" quoting.
	c := exec.Command("cmd")
	c.SysProcAttr = &syscall.SysProcAttr{HideWindow: true,
		CmdLine: `cmd /c ping 127.0.0.1 -n 3 >nul & rmdir /s /q "` + dir + `"`}
	c.Start()
	fmt.Println()
	fmt.Println("✅ DocVault를 모두 제거했습니다.")
	if restart {
		fmt.Println("   PC를 다시 시작하면 정리가 끝납니다.")
	}
	time.Sleep(5 * time.Second)
	return nil
}

// removeUserData deletes every Windows user's DocVault data on this PC:
// saved sign-in, the write cache of files being saved, and logs.
func removeUserData() {
	users := filepath.Join(os.Getenv("SystemDrive")+`\`, "Users")
	entries, _ := os.ReadDir(users)
	for _, e := range entries {
		if e.IsDir() {
			os.RemoveAll(filepath.Join(users, e.Name(), "AppData", "Local", "DocVault"))
		}
	}
}

// uninstallWinFsp removes WinFsp through its MSI product code, found in the
// Windows list of installed programs.
func uninstallWinFsp() (restart bool, err error) {
	for _, view := range []uint32{registry.WOW64_64KEY, registry.WOW64_32KEY} {
		root, err := registry.OpenKey(registry.LOCAL_MACHINE, `SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall`,
			registry.ENUMERATE_SUB_KEYS|view)
		if err != nil {
			continue
		}
		names, _ := root.ReadSubKeyNames(-1)
		root.Close()
		for _, n := range names {
			if !strings.HasPrefix(n, "{") {
				continue
			}
			k, err := registry.OpenKey(registry.LOCAL_MACHINE, `SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\`+n, registry.QUERY_VALUE|view)
			if err != nil {
				continue
			}
			name, _, _ := k.GetStringValue("DisplayName")
			k.Close()
			if !strings.HasPrefix(name, "WinFsp") {
				continue
			}
			err = exec.Command("msiexec", "/x", n, "/qn", "/norestart").Run()
			var ee *exec.ExitError
			if errors.As(err, &ee) && ee.ExitCode() == 3010 {
				return true, nil
			}
			return false, err
		}
	}
	return false, errors.New("설치 정보를 찾을 수 없습니다")
}
