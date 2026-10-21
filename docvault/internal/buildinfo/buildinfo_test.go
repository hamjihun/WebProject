package buildinfo

import "testing"

func TestNewerThan(t *testing.T) {
	for _, c := range []struct {
		a, b string
		want bool
	}{
		{"0.7.0", "0.6.0", true}, {"0.6.0", "0.7.0", false}, {"0.7.0", "0.7.0", false},
		{"0.10.0", "0.9.9", true}, {"1.0.0", "0.99.0", true}, {"0.7.1", "", true}, {"", "0.1.0", false},
		{"0.7.0\r\n", "0.6.0", true},
	} {
		if got := NewerThan(c.a, c.b); got != c.want {
			t.Errorf("NewerThan(%q, %q) = %v", c.a, c.b, got)
		}
	}
}

func TestVersionIn(t *testing.T) {
	if v := VersionIn([]byte("MZ DVSETUPVER:\x00\x01abc DVSETUPVER:x; DVSETUPVER:0.7.0; more")); v != "0.7.0" {
		t.Fatalf("got %q", v)
	}
	if v := VersionIn([]byte("no marker")); v != "" {
		t.Fatalf("got %q", v)
	}
}
