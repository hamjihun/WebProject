//go:build !windows

package main

import (
	"bufio"
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
)

func cmdVersions(cfg *Config, local string) error {
	tok := loadToken()
	if tok == "" {
		return errors.New("로그인되어 있지 않습니다")
	}
	c := newClient(cfg, tok)
	d, p, err := driveTarget(c, local)
	if err != nil {
		return err
	}
	list, err := fetchVersions(c, d, p)
	if err != nil {
		return err
	}
	if len(list) == 0 {
		fmt.Println("이전 버전이 없습니다.")
		return nil
	}
	for i, v := range list {
		fmt.Printf("  [%d] %s\n", i+1, verLabel(v))
	}
	sel := prompt(bufio.NewReader(os.Stdin), "되돌릴 번호 (취소: Enter): ")
	if strings.TrimSpace(sel) == "" {
		return nil
	}
	i, err := strconv.Atoi(strings.TrimSpace(sel))
	if err != nil || i < 1 || i > len(list) {
		return errors.New("잘못된 번호")
	}
	if err := restoreVersionReq(c, d, p, list[i-1].ID); err != nil {
		return err
	}
	fmt.Println("선택한 버전으로 되돌렸습니다.")
	return nil
}
