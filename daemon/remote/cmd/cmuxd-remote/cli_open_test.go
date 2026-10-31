package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// `cmux open` in an SSH session resolves the path on this host and asks the
// app to preview it through the workspace's SSH connection (file.open_remote).

func TestCLIOpenResolvesRelativePathsOnThisHost(t *testing.T) {
	dir := t.TempDir()
	dir, _ = filepath.EvalSymlinks(dir)
	if err := os.MkdirAll(filepath.Join(dir, "rtl"), 0o755); err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(dir, "rtl", "alu: core.sv")
	if err := os.WriteFile(file, []byte("module alu;\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Chdir(dir)
	t.Setenv("CMUX_WORKSPACE_ID", "ws-env")
	t.Setenv("CMUX_SURFACE_ID", "sf-env")

	for _, args := range [][]string{
		{"rtl/alu: core.sv"},
		{"rtl/alu: core.sv:12"},
		{"rtl/alu: core.sv:12:3"},
		{"./rtl/../rtl/alu: core.sv"},
		{file},
	} {
		sockPath, requests := startMockV2SocketWithRequestCapture(t)
		code := runCLI(append([]string{"--socket", sockPath, "open"}, args...))
		if code != 0 {
			t.Fatalf("open %v: exit %d", args, code)
		}
		select {
		case req := <-requests:
			if got := req["method"]; got != "file.open_remote" {
				t.Fatalf("open %v: method %v", args, got)
			}
			params, _ := req["params"].(map[string]any)
			want := map[string]any{"workspace_id": "ws-env", "surface_id": "sf-env", "path": file}
			if len(params) != len(want) {
				t.Fatalf("open %v: params %v, want exactly %v", args, params, want)
			}
			for key, value := range want {
				if params[key] != value {
					t.Fatalf("open %v: %s=%v, want %v", args, key, params[key], value)
				}
			}
		case <-time.After(2 * time.Second):
			t.Fatalf("open %v: no request", args)
		}
	}
}

func TestCLIOpenRejectsWhatItCannotPreview(t *testing.T) {
	dir := t.TempDir()
	t.Chdir(dir)
	t.Setenv("CMUX_WORKSPACE_ID", "ws-env")
	t.Setenv("CMUX_SURFACE_ID", "sf-env")
	cases := map[string][]string{
		"no path":      {},
		"two paths":    {"a", "b"},
		"missing file": {"nope.sv"},
		"directory":    {"."},
		"url":          {"https://example.com"},
		"unknown flag": {"--window", "w1", "a"},
	}
	if err := os.WriteFile(filepath.Join(dir, "a"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	// Larger than the app previews without a click: refused here, before any request.
	big, err := os.Create(filepath.Join(dir, "big.fsdb"))
	if err != nil {
		t.Fatal(err)
	}
	if err := big.Truncate(maxOpenFileBytes + 1); err != nil {
		t.Fatal(err)
	}
	big.Close()
	cases["too large"] = []string{"big.fsdb"}
	for name, args := range cases {
		sockPath, requests := startMockV2SocketWithRequestCapture(t)
		code := runCLI(append([]string{"--socket", sockPath, "open"}, args...))
		if code == 0 {
			t.Fatalf("%s: open %v succeeded", name, args)
		}
		select {
		case req := <-requests:
			t.Fatalf("%s: sent %v", name, req)
		case <-time.After(100 * time.Millisecond):
		}
	}
}

func TestCLIOpenNeedsTheTerminalItRunsIn(t *testing.T) {
	dir := t.TempDir()
	t.Chdir(dir)
	if err := os.WriteFile(filepath.Join(dir, "a.sv"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CMUX_WORKSPACE_ID", "")
	t.Setenv("CMUX_SURFACE_ID", "")
	sockPath, requests := startMockV2SocketWithRequestCapture(t)
	if code := runCLI([]string{"--socket", sockPath, "open", "a.sv"}); code == 0 {
		t.Fatal("open without CMUX_SURFACE_ID succeeded")
	}
	select {
	case req := <-requests:
		t.Fatalf("sent %v", req)
	case <-time.After(100 * time.Millisecond):
	}
}
