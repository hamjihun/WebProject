//go:build !windows

package main

import (
	"bufio"
	"errors"
	"fmt"
	"os"
)

func cmdExport(cfg *Config, local string) error {
	tok := loadToken()
	if tok == "" {
		return errors.New("로그인되어 있지 않습니다")
	}
	c := newClient(cfg, tok)
	d, p, err := exportTarget(c, local)
	if err != nil {
		return err
	}
	reason := prompt(bufio.NewReader(os.Stdin), "반출 사유: ")
	if reason == "" {
		return errors.New("반출 사유를 입력하세요")
	}
	if err := requestExport(c, d, p, reason); err != nil {
		return err
	}
	fmt.Println(exportDoneText)
	return nil
}
