package main

import "testing"

// The 감시 스위치: when web attachment protection is on, uncovered browsers are
// always blocked; covered browsers are blocked only while the extension is not
// reporting (dead-man switch).
func TestDeadmanBrowserBlocks(t *testing.T) {
	a := &agent{up: newUploadState()}

	// Protection off → block nothing.
	a.up.set(webUploadOff, nil, nil, nil)
	if len(a.browserBlocks()) != 0 {
		t.Fatalf("off: expected no blocks, got %v", a.browserBlocks())
	}

	// Protection on, extension not reporting → covered AND uncovered blocked.
	a.up.set(webUploadLog, nil, nil, nil)
	if a.up.extAlive() {
		t.Fatal("extension should not be alive without a heartbeat")
	}
	m := a.browserBlocks()
	for _, b := range coveredBrowsers {
		if m[b] != "upload" {
			t.Fatalf("ext dead: covered browser %s should be blocked", b)
		}
	}
	for _, b := range uncoveredBrowsers {
		if m[b] != "upload" {
			t.Fatalf("ext dead: uncovered browser %s should be blocked", b)
		}
	}

	// Extension heartbeats → alive → covered browsers allowed, uncovered still blocked.
	a.up.seen()
	if !a.up.extAlive() {
		t.Fatal("extension should be alive right after a heartbeat")
	}
	m = a.browserBlocks()
	for _, b := range coveredBrowsers {
		if _, ok := m[b]; ok {
			t.Fatalf("ext alive: covered browser %s should NOT be blocked", b)
		}
	}
	for _, b := range uncoveredBrowsers {
		if m[b] != "upload" {
			t.Fatalf("ext alive: uncovered browser %s should still be blocked", b)
		}
	}
}
