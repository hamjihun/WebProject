package main

import "testing"

func TestParseConfigPaths(t *testing.T) {
	cases := []struct{ in, store, data string }{
		// written like Explorer shows them
		{`{"store_dir": "\\192.168.50.201\DocVaultStore", "data_dir": "C:\DocVault\data"}`, `\\192.168.50.201\DocVaultStore`, `C:\DocVault\data`},
		// JSON style (doubled), as older versions wrote
		{`{"store_dir": "\\\\192.168.50.201\\DocVaultStore", "data_dir": "C:\\DocVault\\data"}`, `\\192.168.50.201\DocVaultStore`, `C:\DocVault\data`},
		// Notepad BOM, Linux paths
		{"\xef\xbb\xbf" + `{"store_dir": "/srv/store", "data_dir": "/srv/data"}`, `/srv/store`, `/srv/data`},
	}
	for _, c := range cases {
		cfg := &Config{}
		if err := parseConfig([]byte(c.in), cfg); err != nil {
			t.Fatalf("%s: %v", c.in, err)
		}
		if cfg.StoreDir != c.store || cfg.DataDir != c.data {
			t.Fatalf("%s: got %q %q", c.in, cfg.StoreDir, cfg.DataDir)
		}
	}
	// the file the server writes on first start reads back the same
	want := &Config{Listen: ":8080", DataDir: `C:\DocVault\data`, StoreDir: `\\nas\share`}
	got := &Config{}
	if err := parseConfig([]byte(defaultConfigText(want)), got); err != nil || got.DataDir != want.DataDir || got.StoreDir != want.StoreDir {
		t.Fatalf("round trip %+v %v", got, err)
	}
}
