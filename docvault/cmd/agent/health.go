package main

// Health checks. A drive whose server does not answer makes every program
// that touches it wait (Explorer, and with it the taskbar, looks frozen).
// So the agent checks the server every few seconds and disconnects the drives
// as soon as it is down, telling the user; it connects them again when the
// server is back. A drive program that stops answering is restarted.

import (
	"net/http"
	"os"
	"time"
)

const (
	healthEvery   = 3 * time.Second
	healthTimeout = 2 * time.Second
	downAfter     = 2 // failed checks in a row (about 6 s)
	driveTimeout  = 10 * time.Second
)

var probeClient = &http.Client{Timeout: healthTimeout}

// serverReachable answers quickly whether the server responds at all.
func (a *agent) serverReachable() bool {
	resp, err := probeClient.Get(a.cfg.Server + "/api/setup-available")
	if err != nil {
		return false
	}
	resp.Body.Close()
	return resp.StatusCode < 500
}

func (a *agent) mountedLetters() []string {
	a.mu.Lock()
	defer a.mu.Unlock()
	var l []string
	for k := range a.mounts {
		l = append(l, k)
	}
	return l
}

// driveAnswers reports whether the drive program answers for the drive's
// root within driveTimeout. A probe still hanging from last time counts as
// no answer (and is not started again).
func (a *agent) driveAnswers(letter string, pending map[string]chan struct{}) bool {
	ch := pending[letter]
	if ch == nil {
		ch = make(chan struct{})
		pending[letter] = ch
		go func() {
			os.Stat(mountTarget(letter) + string(os.PathSeparator))
			close(ch)
		}()
	}
	select {
	case <-ch:
		delete(pending, letter)
		return true
	case <-time.After(driveTimeout):
		return false
	}
}

// restartDrive stops a drive program that no longer answers; the next sync
// connects the drive again.
func (a *agent) restartDrive(letter string) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if m := a.mounts[letter]; m != nil {
		m.cmd.Process.Kill()
		a.stop(letter)
	}
}

// health runs until stop is closed. offline/online are called when the
// server goes down (drives already disconnected) and comes back; stuck when
// a drive was restarted.
func (a *agent) health(stop <-chan struct{}, offline, online func(), stuck func(letter string)) {
	fails, down, tick := 0, false, 0
	pending := map[string]chan struct{}{}
	stuckCount := map[string]int{}
	t := time.NewTicker(healthEvery)
	defer t.Stop()
	for {
		select {
		case <-stop:
			return
		case <-t.C:
		}
		tick++
		if a.serverReachable() {
			fails = 0
			if down {
				down = false
				a.offline.Store(false)
				online()
			}
		} else {
			fails++
		}
		if !down && fails >= downAfter && len(a.mountedLetters()) > 0 {
			down = true
			a.offline.Store(true)
			a.stopAll()
			offline()
			continue
		}
		if down || tick%5 != 0 { // drives checked every 15 s
			continue
		}
		for _, l := range a.mountedLetters() {
			if a.driveAnswers(l, pending) {
				stuckCount[l] = 0
				continue
			}
			if stuckCount[l]++; stuckCount[l] >= 2 {
				stuckCount[l] = 0
				a.restartDrive(l)
				stuck(l)
			}
		}
	}
}
