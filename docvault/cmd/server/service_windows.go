//go:build windows

package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"path/filepath"
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
			s.Close()
			return fmt.Errorf("이미 설치되어 있습니다")
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
		if err := s.Start(); err != nil {
			return err
		}
		fmt.Println("서비스를 설치하고 시작했습니다. (부팅 시 자동 시작)")
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
		return s.Start()
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
