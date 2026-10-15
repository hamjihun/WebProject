//go:build !windows

package main

import "errors"

func isService() bool { return false }

func runService() {}

func serviceCommand(string) error {
	return errors.New("서비스 등록은 Windows 전용입니다. Linux는 systemd를 사용하세요 (README 참고)")
}
