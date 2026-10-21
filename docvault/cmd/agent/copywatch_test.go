package main

import "testing"

func TestSkipLocal(t *testing.T) {
	for p, want := range map[string]bool{
		`C:\Users\kim\Desktop\견적.xlsx`:              false,
		`D:\자료\견적.xlsx`:                             false,
		`E:\견적.xlsx`:                                false,
		`C:\Users\kim\Desktop\windows\견적.xlsx`:      false,
		`C:\Windows\Temp\a.xlsx`:                    true,
		`C:\Program Files (x86)\x\a.dll`:            true,
		`C:\ProgramData\x\a.dat`:                    true,
		`C:\$Recycle.Bin\S-1\a.xlsx`:                true,
		`C:\Users\kim\AppData\Local\Temp\a.xlsx`:    true,
		`C:\Users\kim\Desktop\~$견적.xlsx`:            true,
		`C:\Users\kim\Downloads\견적.xlsx.crdownload`: true,
		`C:\Users\kim\Desktop\견적.xlsx - 바로 가기.lnk`:  true,
	} {
		if got := skipLocal(p); got != want {
			t.Errorf("skipLocal(%q) = %v, want %v", p, got, want)
		}
	}
}
