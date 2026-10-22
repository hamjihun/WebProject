// Package web embeds the browser UI.
package web

import (
	"embed"
	"io/fs"
	"net/http"
)

//go:embed static
var static embed.FS

// ExtensionCRX is the signed browser-extension package the server hosts for
// force-install. Served by the API with the Chrome CRX MIME type.
func ExtensionCRX() []byte {
	b, _ := static.ReadFile("static/ext/docvault.crx")
	return b
}

func Handler() http.Handler {
	sub, _ := fs.Sub(static, "static")
	fsrv := http.FileServer(http.FS(sub))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("X-Frame-Options", "DENY")
		w.Header().Set("Content-Security-Policy", "default-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:")
		w.Header().Set("Cache-Control", "no-cache")
		fsrv.ServeHTTP(w, r)
	})
}
