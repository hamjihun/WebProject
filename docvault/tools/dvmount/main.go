// docvault-mount is rclone trimmed to what DocVault needs (WebDAV + mount on
// Windows via WinFsp), with one addition in ./cmount: files on the DocVault
// drives cannot be read by programs on a block list (e.g. KakaoTalk.exe or
// Explorer copying to the desktop). Based on rclone v1.68.2 (MIT licence,
// see RCLONE-LICENSE.txt).
package main

import (
	_ "docvault-mount/cmount"
	_ "github.com/rclone/rclone/backend/local" // needed by the VFS write cache
	_ "github.com/rclone/rclone/backend/webdav"
	"github.com/rclone/rclone/cmd"
	_ "github.com/rclone/rclone/cmd/version"
)

func main() { cmd.Main() }
