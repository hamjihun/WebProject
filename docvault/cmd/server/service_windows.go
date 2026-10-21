//go:build windows

package main

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"golang.org/x/sys/windows/svc"
	"golang.org/x/sys/windows/svc/mgr"
)

const serviceName = "DocVault"

func isService() bool {
	ok, _ := svc.IsWindowsService()
	return ok
}

type winService struct{}

func (winService) Execute(args []string, req <-chan svc.ChangeRequest, status chan<- svc.Status) (bool, uint32) {
	status <- svc.Status{State: svc.StartPending}
	s, err := newServer()
	if err != nil {
		log.Printf("시작 실패: %v", err)
		saveStartupError(startupErrorText(err))
		return true, 1
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- s.serve(ctx) }()
	status <- svc.Status{State: svc.Running, Accepts: svc.AcceptStop | svc.AcceptShutdown}
	for {
		select {
		case err := <-done:
			if err != nil {
				log.Printf("서버 오류: %v", err)
				return true, 2
			}
			return false, 0
		case c := <-req:
			switch c.Cmd {
			case svc.Interrogate:
				status <- c.CurrentStatus
			case svc.Stop, svc.Shutdown:
				status <- svc.Status{State: svc.StopPending}
				cancel()
				<-done
				return false, 0
			}
		}
	}
}

func runService() {
	logDir := filepath.Join(exeDir(), "logs")
	os.MkdirAll(logDir, 0o750)
	if f, err := os.OpenFile(filepath.Join(logDir, "server-"+time.Now().Format("200601")+".log"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o640); err == nil {
		log.SetOutput(f)
	}
	if err := svc.Run(serviceName, winService{}); err != nil {
		log.Printf("service: %v", err)
	}
}

func serviceCommand(cmd string) error {
	m, err := mgr.Connect()
	if err != nil {
		return fmt.Errorf("서비스 관리자에 연결할 수 없습니다 (관리자 권한으로 실행하세요): %w", err)
	}
	defer m.Disconnect()
	switch cmd {
	case "install":
		exe, err := os.Executable()
		if err != nil {
			return err
		}
		if s, err := m.OpenService(serviceName); err == nil {
			// Already registered (earlier install): point it at this exe and start it.
			defer s.Close()
			if c, err := s.Config(); err == nil {
				c.BinaryPathName = exe
				c.StartType = mgr.StartAutomatic
				s.UpdateConfig(c)
			}
			fmt.Println("서비스가 이미 설치되어 있어 설정을 갱신했습니다. (부팅 시 자동 시작)")
			return startAndCheck(s)
		}
		s, err := m.CreateService(serviceName, exe, mgr.Config{
			DisplayName: "DocVault 문서중앙화 서버",
			Description: "사내 문서중앙화 (가상 드라이브, 버전관리, 반출 결재, 감사 로그)",
			StartType:   mgr.StartAutomatic,
		})
		if err != nil {
			return err
		}
		defer s.Close()
		s.SetRecoveryActions([]mgr.RecoveryAction{
			{Type: mgr.ServiceRestart, Delay: 10 * time.Second},
			{Type: mgr.ServiceRestart, Delay: 30 * time.Second},
			{Type: mgr.ServiceRestart, Delay: time.Minute},
		}, 86400)
		fmt.Println("서비스를 설치했습니다. (부팅 시 자동 시작)")
		return startAndCheck(s)
	case "uninstall":
		s, err := m.OpenService(serviceName)
		if err != nil {
			return fmt.Errorf("설치되어 있지 않습니다")
		}
		defer s.Close()
		s.Control(svc.Stop)
		if err := s.Delete(); err != nil {
			return err
		}
		fmt.Println("서비스를 제거했습니다. (데이터는 그대로 남아 있습니다)")
	case "start":
		s, err := m.OpenService(serviceName)
		if err != nil {
			return err
		}
		defer s.Close()
		return startAndCheck(s)
	case "stop":
		s, err := m.OpenService(serviceName)
		if err != nil {
			return err
		}
		defer s.Close()
		_, err = s.Control(svc.Stop)
		return err
	}
	return nil
}

// startAndCheck starts the service and reports whether it is really serving,
// showing the startup error when it is not.
func startAndCheck(s *mgr.Service) error {
	if st, err := s.Query(); err == nil && st.State == svc.Running {
		if url, ok := probe(); ok {
			fmt.Println("\n✅ 서버가 이미 정상적으로 실행 중입니다: " + url)
			return nil
		}
	}
	if url, ok := probe(); ok {
		return errors.New("다른 DocVault 서버가 이미 실행 중입니다 (" + url + ").\n검은 창으로 실행한 docvault-server.exe 를 먼저 닫은 뒤 다시 실행하세요.")
	}
	os.Remove(startupErrorFile())
	fmt.Println("서비스를 시작하는 중...")
	if err := s.Start(); err != nil && !strings.Contains(err.Error(), "already running") {
		return fmt.Errorf("서비스를 시작할 수 없습니다: %w", err)
	}
	for i := 0; i < 30; i++ {
		time.Sleep(500 * time.Millisecond)
		st, err := s.Query()
		if err != nil {
			break
		}
		if st.State == svc.Stopped {
			msg := "서비스가 시작되자마자 멈췄습니다."
			if b, err := os.ReadFile(startupErrorFile()); err == nil {
				msg += "\n\n" + strings.TrimPrefix(string(b), "\xef\xbb\xbf")
			} else {
				msg += " " + filepath.Join(exeDir(), "logs") + " 의 로그를 확인하세요."
			}
			return errors.New(msg)
		}
		if st.State == svc.Running {
			if url, ok := probe(); ok {
				fmt.Println("\n✅ 서버가 정상적으로 실행 중입니다: " + url)
				return nil
			}
		}
	}
	return errors.New("서버가 응답하지 않습니다. " + filepath.Join(exeDir(), "logs") + " 의 로그와 시작오류.txt 를 확인하세요.")
}

// probe checks that the web server answers on the configured port.
func probe() (string, bool) {
	cfg, _, err := loadConfig()
	if err != nil {
		return "", false
	}
	port := cfg.Listen
	if i := strings.LastIndex(port, ":"); i >= 0 {
		port = port[i+1:]
	}
	scheme := "http"
	if cfg.TLSCert != "" {
		scheme = "https"
	}
	url := scheme + "://localhost:" + port
	c := &http.Client{Timeout: 2 * time.Second, Transport: &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true}}}
	resp, err := c.Get(url + "/api/setup-available")
	if err != nil {
		return url, false
	}
	resp.Body.Close()
	return url, true
}
