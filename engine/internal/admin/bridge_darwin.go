// Package admin provides a transient, user-authorized USB bootstrap on macOS.
// No daemon, credentials, or privileged files are installed.
package admin

/*
#include <unistd.h>
#include <sys/socket.h>
static int ferry_peer(int fd, unsigned int *uid, unsigned int *gid) {
    return getpeereid(fd, uid, gid);
}
*/
import "C"

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

var ErrAuthorization = errors.New("administrator authorization did not complete")

func peer(conn *net.UnixConn) (int, int, error) {
	raw, err := conn.SyscallConn()
	if err != nil {
		return 0, 0, err
	}
	var uid, gid C.uint
	var status C.int
	if err = raw.Control(func(fd uintptr) { status = C.ferry_peer(C.int(fd), &uid, &gid) }); err != nil {
		return 0, 0, err
	}
	if status != 0 {
		return 0, 0, errors.New("cannot verify local peer")
	}
	return int(uid), int(gid), nil
}

func shellQuote(value string) string { return "'" + strings.ReplaceAll(value, "'", "'\\''") + "'" }

func authorizationScript(executable, socket, language string, uid int) string {
	// Two distinct parsers: first quote each shell argument, then quote the
	// complete command as an AppleScript string. Only fixed flags and quoted
	// argument values are passed to the privileged command.
	command := "/usr/bin/env " + shellQuote("FERRY_LANGUAGE="+language) + " " + shellQuote(executable) +
		" --serve --usb-capture --admin-socket " + shellQuote(socket) + " --admin-uid " + strconv.Itoa(uid)
	quoted := strings.NewReplacer("\\", "\\\\", "\"", "\\\"", "\n", "\\n", "\r", "\\r").Replace(command)
	return "do shell script \"" + quoted + "\" with administrator privileges"
}

// Relay runs without privileges. Only the engine copy launched by the system
// dialog is privileged, and it must drop privileges before serving file work.
// EOF on its authenticated socket means engine cleanup has completed.
func Relay(ctx context.Context, executable, language string) error {
	if os.Geteuid() == 0 {
		return errors.New("authorization relay must run as the desktop user")
	}
	dir, err := os.MkdirTemp("/private/tmp", "ferry-auth-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(dir)
	path := filepath.Join(dir, "engine.sock")
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		return err
	}
	defer listener.Close()
	if err = os.Chmod(path, 0600); err != nil {
		return err
	}
	command := exec.Command("/usr/bin/osascript", "-e", authorizationScript(executable, path, language, os.Getuid()))
	// Keep authorization diagnostics off the NDJSON channel. Never collect passwords.
	command.Stdout, command.Stderr = io.Discard, io.Discard
	if err = command.Start(); err != nil {
		return fmt.Errorf("%w: %v", ErrAuthorization, err)
	}
	done := make(chan error, 1)
	go func() { done <- command.Wait() }()
	var conn *net.UnixConn
	deadline := time.Now().Add(2 * time.Minute)
	for conn == nil {
		select {
		case <-ctx.Done():
			_ = command.Process.Kill()
			<-done
			return ctx.Err()
		case <-done:
			return ErrAuthorization
		default:
		}
		if time.Now().After(deadline) {
			_ = command.Process.Kill()
			<-done
			return ErrAuthorization
		}
		_ = listener.SetDeadline(time.Now().Add(100 * time.Millisecond))
		candidate, acceptErr := listener.AcceptUnix()
		if acceptErr != nil {
			if timeout, ok := acceptErr.(net.Error); ok && timeout.Timeout() {
				continue
			}
			_ = command.Process.Kill()
			<-done
			return acceptErr
		}
		uid, _, peerErr := peer(candidate)
		if peerErr != nil || uid != 0 {
			candidate.Close()
			continue
		}
		conn = candidate
	}
	listener.Close()
	defer conn.Close()
	return relayConnection(ctx, conn, os.Stdin, os.Stdout, done)
}

func relayConnection(ctx context.Context, conn *net.UnixConn, input io.ReadCloser, output io.Writer, done <-chan error) error {
	finished := make(chan struct{})
	defer close(finished)
	go func() {
		_, _ = io.Copy(conn, input)
		// A half-close cancels the remote scanner but leaves output open until
		// CloseSession/ReleaseInterface/AttachKernelDriver have all completed.
		_ = conn.CloseWrite()
	}()
	go func() {
		select {
		case <-ctx.Done():
			_ = conn.CloseWrite()
			_ = input.Close()
		case <-finished:
		}
	}()
	_, copyErr := io.Copy(output, conn)
	_ = input.Close()
	if copyErr != nil {
		_ = conn.CloseWrite()
	}
	// osascript waits for the engine to exit. Do not start a replacement engine
	// while its predecessor is still restoring the USB driver.
	processErr := <-done
	if ctx.Err() != nil {
		return ctx.Err()
	}
	if copyErr != nil {
		return copyErr
	}
	return processErr
}

type Identity struct{ UID, GID int }

// Connect authenticates the invoking user with kernel credentials, not a path,
// PID, or a claimed JSON identity. It must run before USB initialization.
func Connect(path string, expectedUID int) (*os.File, Identity, error) {
	if os.Geteuid() != 0 || expectedUID <= 0 {
		return nil, Identity{}, errors.New("invalid privileged bootstrap")
	}
	conn, err := net.DialTimeout("unix", path, 5*time.Second)
	if err != nil {
		return nil, Identity{}, err
	}
	defer conn.Close()
	unix := conn.(*net.UnixConn)
	uid, gid, err := peer(unix)
	if err != nil || uid != expectedUID || gid < 0 {
		return nil, Identity{}, errors.New("unauthenticated bootstrap peer")
	}
	file, err := unix.File()
	return file, Identity{UID: uid, GID: gid}, err
}

// Drop permanently removes root and its supplementary groups. All paths,
// temporary previews, downloads, and commits are then handled as this user.
func (identity Identity) Drop() error {
	if identity.UID <= 0 || os.Geteuid() != 0 {
		return errors.New("invalid privilege drop")
	}
	account, err := user.LookupId(strconv.Itoa(identity.UID))
	if err != nil {
		return err
	}
	groupIDs, err := account.GroupIds()
	if err != nil {
		return err
	}
	groups := make([]int, 0, len(groupIDs))
	for _, value := range groupIDs {
		gid, err := strconv.Atoi(value)
		if err != nil {
			return err
		}
		groups = append(groups, gid)
	}
	if err = syscall.Setgroups(groups); err != nil {
		return err
	}
	if err = syscall.Setgid(identity.GID); err != nil {
		return err
	}
	if err = syscall.Setuid(identity.UID); err != nil {
		return err
	}
	if os.Getuid() != identity.UID || os.Geteuid() != identity.UID || os.Getgid() != identity.GID {
		return errors.New("privilege drop did not take effect")
	}
	return nil
}
