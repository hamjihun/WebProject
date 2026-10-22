package vault

import "strings"

// Web attachment control (웹 첨부관리). The browser extension blocks file
// uploads on the web unless the current site is an exception (그룹웨어·은행 등)
// or the file is one the user has had approved for export (반출). The server
// supplies the policy and the set of allowed file fingerprints; the PC agent
// caches them and answers the extension over localhost.

// HashSize fingerprints a file by content hash and byte size.
type HashSize struct {
	SHA  string `json:"sha"`
	Size int64  `json:"size"`
}

// WebUploadEnabled reports whether web-attachment control is on.
func (v *Vault) WebUploadEnabled() bool { return v.Setting("block_web_upload") != 0 }

// WebUploadAllowDomains is the list of exception sites (host names). Uploads on
// these sites are always allowed. Entries are stored one per line (commas also
// accepted); any scheme, path, "www." and leading dots are stripped.
func (v *Vault) WebUploadAllowDomains() []string {
	raw := v.StringSetting("web_upload_allow_domains")
	raw = strings.ReplaceAll(raw, ",", "\n")
	seen := map[string]bool{}
	out := []string{}
	for _, line := range strings.Split(raw, "\n") {
		h := normalizeHost(line)
		if h != "" && !seen[h] {
			seen[h] = true
			out = append(out, h)
		}
	}
	return out
}

// normalizeHost reduces a user-entered line to a bare lower-case host name.
func normalizeHost(s string) string {
	s = strings.TrimSpace(strings.ToLower(s))
	if s == "" {
		return ""
	}
	if i := strings.Index(s, "://"); i >= 0 {
		s = s[i+3:]
	}
	if i := strings.IndexAny(s, "/?#"); i >= 0 {
		s = s[:i]
	}
	if i := strings.IndexByte(s, '@'); i >= 0 {
		s = s[i+1:]
	}
	if i := strings.IndexByte(s, ':'); i >= 0 { // strip :port
		s = s[:i]
	}
	s = strings.TrimPrefix(s, "www.")
	s = strings.Trim(s, ".")
	return s
}

// UploadAllowedHashes returns the content fingerprints a user may attach on the
// web: files they have had approved (or taken by 후결재) for export. The agent
// caches these; the extension checks each picked file against them.
func (v *Vault) UploadAllowedHashes(u *User) []HashSize {
	if u == nil {
		return nil
	}
	rows, err := v.DB.Query(`SELECT DISTINCT ver.blob_sha, ver.size
		FROM exports e JOIN versions ver ON ver.id=e.version_id
		WHERE e.requester_id=? AND e.status IN ('approved','post') AND ver.blob_sha<>'' AND ver.size>0
		LIMIT 20000`, u.ID)
	if err != nil {
		return nil
	}
	defer rows.Close()
	out := []HashSize{}
	for rows.Next() {
		var h HashSize
		if rows.Scan(&h.SHA, &h.Size) == nil {
			out = append(out, h)
		}
	}
	return out
}
