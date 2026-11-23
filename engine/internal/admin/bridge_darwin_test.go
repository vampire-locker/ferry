package admin

import (
	"bytes"
	"context"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func socketPair(t *testing.T) (*net.UnixConn, *net.UnixConn) {
	t.Helper()
	dir, err := os.MkdirTemp("/private/tmp", "ferry-socket-test-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	path := filepath.Join(dir, "socket")
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	client, err := net.DialUnix("unix", nil, &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	server, err := listener.AcceptUnix()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { client.Close(); server.Close() })
	return client, server
}

func TestPeerCredentialsAndRejectUnprivilegedBootstrap(t *testing.T) {
	client, _ := socketPair(t)
	uid, gid, err := peer(client)
	if err != nil || uid != os.Geteuid() || gid != os.Getegid() {
		t.Fatalf("%d %d %v", uid, gid, err)
	}
	if os.Geteuid() == 0 {
		t.Skip("run tests as a regular user")
	}
	if _, _, err := Connect("/not-a-socket", os.Getuid()); err == nil {
		t.Fatal("unprivileged bootstrap accepted")
	}
	if err := (Identity{UID: os.Getuid(), GID: os.Getgid()}).Drop(); err == nil {
		t.Fatal("invalid privilege drop accepted")
	}
}

func TestRelayCancellationDrainsCleanupBeforeReturning(t *testing.T) {
	client, server := socketPair(t)
	input, writer := io.Pipe()
	defer writer.Close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	returned := make(chan error, 1)
	var output bytes.Buffer
	go func() { returned <- relayConnection(ctx, client, input, &output, done) }()
	cancel()
	server.SetReadDeadline(time.Now().Add(time.Second))
	if data, err := io.ReadAll(server); err != nil || len(data) != 0 {
		t.Fatalf("half close: %s %v", data, err)
	}
	select {
	case <-returned:
		t.Fatal("returned before driver restoration")
	default:
	}
	server.Write([]byte("cleanup-finished"))
	server.Close()
	// EOF alone isn't enough: the launch wrapper must also have exited.
	select {
	case <-returned:
		t.Fatal("returned before process exit")
	default:
	}
	done <- nil
	select {
	case err := <-returned:
		if err != context.Canceled || output.String() != "cleanup-finished" {
			t.Fatalf("%v %q", err, output.String())
		}
	case <-time.After(time.Second):
		t.Fatal("relay stuck after cleanup")
	}
}

func TestShellArgumentsCannotBecomeCommands(t *testing.T) {
	for _, value := range []string{"a b", "x'$(false)`false`\"\\", "line\nnext"} {
		out, err := exec.Command("/bin/sh", "-c", "printf '%s' "+shellQuote(value)).Output()
		if err != nil || string(out) != value {
			t.Fatalf("%q %q %v", value, out, err)
		}
	}
	script := authorizationScript("/tmp/Ferry's app/engine", "/tmp/socket", "en", 501)
	if !strings.Contains(script, "--admin-uid 501") || !strings.HasSuffix(script, "with administrator privileges") {
		t.Fatal(script)
	}
}
