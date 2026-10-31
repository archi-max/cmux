package main

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// lineSuffix matches the `:line` or `:line:column` an editor or compiler
// prints after a path.
var lineSuffix = regexp.MustCompile(`:[0-9]+(:[0-9]+)?$`)

// maxOpenFileBytes matches the app's cap on what `cmux open` downloads
// without a click (RemoteTerminalFilePreviewCoordinator).
const maxOpenFileBytes = 32 << 20

// runOpenRelay handles "cmux open <path>[:line]" in an SSH session. The path
// is resolved here, on the SSH host, and sent as an absolute host path; the
// app previews it through this workspace's own SSH connection
// (file.open_remote), so it never names a file on the Mac. The preview has
// no line positioning yet, so a `:line` suffix is accepted and dropped, as
// the macOS `cmux open` does.
func runOpenRelay(socketPath string, args []string, jsonOutput bool, refreshAddr func() string) int {
	if len(args) != 1 || strings.HasPrefix(args[0], "-") {
		fmt.Fprintln(os.Stderr, "Usage: cmux open <path>[:line]")
		return 2
	}
	path, err := resolveOpenPath(args[0])
	if err != nil {
		fmt.Fprintf(os.Stderr, "cmux open: %v\n", err)
		return 1
	}
	params := map[string]any{"path": path}
	applyWorkspaceEnvFallback(params)
	applySurfaceEnvFallback(params)
	if params["workspace_id"] == nil || params["surface_id"] == nil {
		fmt.Fprintln(os.Stderr, "cmux open: run it in a cmux terminal (CMUX_WORKSPACE_ID and CMUX_SURFACE_ID are not set)")
		return 1
	}
	resp, err := socketRoundTripV2(socketPath, "file.open_remote", params, refreshAddr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "cmux: %v\n", err)
		return 1
	}
	if jsonOutput {
		fmt.Println(resp)
	} else {
		fmt.Println(defaultRelayOutput(resp))
	}
	return 0
}

// resolveOpenPath returns the absolute, cleaned path of an existing regular
// file, trying the argument as written before dropping a `:line` suffix (a
// file name may itself end in `:12`).
func resolveOpenPath(raw string) (string, error) {
	if strings.Contains(raw, "://") {
		return "", fmt.Errorf("%s is not a file path", raw)
	}
	candidates := []string{raw}
	if stripped := lineSuffix.ReplaceAllString(raw, ""); stripped != raw && stripped != "" {
		candidates = append(candidates, stripped)
	}
	for _, candidate := range candidates {
		abs, err := filepath.Abs(candidate)
		if err != nil {
			continue
		}
		info, err := os.Stat(abs)
		if err != nil {
			continue
		}
		if info.IsDir() {
			return "", fmt.Errorf("%s is a directory", abs)
		}
		if !info.Mode().IsRegular() {
			return "", fmt.Errorf("%s is not a regular file", abs)
		}
		if info.Size() > maxOpenFileBytes {
			return "", fmt.Errorf("%s is larger than %d MB; open it from the Files panel instead", abs, maxOpenFileBytes>>20)
		}
		return abs, nil
	}
	return "", fmt.Errorf("no such file: %s", raw)
}
