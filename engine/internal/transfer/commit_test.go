package transfer

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

func TestCommitExclusive(t *testing.T) {
	testCommitExclusive(t, t.TempDir())
}

func testCommitExclusive(t *testing.T, directory string) {
	t.Helper()
	root, err := os.OpenRoot(directory)
	if err != nil {
		t.Fatal(err)
	}
	defer root.Close()
	if err := checkCommitSupport(root); err != nil {
		t.Fatal(err)
	}
	if entries, err := os.ReadDir(directory); err != nil || len(entries) != 0 {
		t.Fatalf("preflight left entries: %v (%v)", entries, err)
	}
	if err := root.Mkdir("照片", 0700); err != nil {
		t.Fatal(err)
	}
	if err := root.WriteFile("source.part", []byte("complete"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := commitFile(root, "source.part", "照片/旅行.jpg"); err != nil {
		t.Fatal(err)
	}
	if _, err := root.Lstat("source.part"); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("committed source still exists: %v", err)
	}
	if data, err := root.ReadFile("照片/旅行.jpg"); err != nil || string(data) != "complete" {
		t.Fatalf("committed data=%q error=%v", data, err)
	}
	for _, target := range []string{"照片/旅行.jpg", "照片", "照片/旅行.JPG"} {
		// Case variants conflict on the external exFAT volume and default APFS.
		if _, err := root.Lstat(target); errors.Is(err, os.ErrNotExist) {
			continue // The developer's filesystem may be case sensitive.
		}
		if err := root.WriteFile("conflict.part", []byte("replacement"), 0600); err != nil {
			t.Fatal(err)
		}
		if err := commitFile(root, "conflict.part", target); !errors.Is(err, os.ErrExist) {
			t.Fatalf("existing target %q: %v", target, err)
		}
		if data, err := root.ReadFile("conflict.part"); err != nil || string(data) != "replacement" {
			t.Fatalf("conflicting source changed: %q %v", data, err)
		}
	}
	if data, err := root.ReadFile("照片/旅行.jpg"); err != nil || string(data) != "complete" {
		t.Fatalf("existing destination changed: %q %v", data, err)
	}
}

func TestCommitRejectsEscapesAndExistingSymlinks(t *testing.T) {
	directory := t.TempDir()
	outside := t.TempDir()
	root, err := os.OpenRoot(directory)
	if err != nil {
		t.Fatal(err)
	}
	defer root.Close()
	if err := os.WriteFile(filepath.Join(outside, "old"), []byte("old"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := root.Symlink(outside, "escape"); err != nil {
		t.Fatal(err)
	}
	if err := root.Symlink(filepath.Join(outside, "old"), "existing-link"); err != nil {
		t.Fatal(err)
	}
	if err := root.Symlink(filepath.Join(outside, "missing"), "dangling-link"); err != nil {
		t.Fatal(err)
	}
	for _, target := range []string{"../escaped", filepath.Join(outside, "escaped"), "escape/escaped", "existing-link", "dangling-link", "bad\x00name", "."} {
		if err := root.WriteFile("source.part", []byte("new"), 0600); err != nil {
			t.Fatal(err)
		}
		if err := commitFile(root, "source.part", target); err == nil {
			t.Fatalf("accepted unsafe or existing destination %q", target)
		}
		if data, err := root.ReadFile("source.part"); err != nil || string(data) != "new" {
			t.Fatalf("source changed: %q %v", data, err)
		}
	}
	if err := commitFile(root, "escape/old", "stolen"); err == nil {
		t.Fatal("accepted source outside root")
	}
	for _, name := range []string{"existing-link", "dangling-link"} {
		if info, err := root.Lstat(name); err != nil || info.Mode()&os.ModeSymlink == 0 {
			t.Fatalf("existing symlink changed: %s %v", name, err)
		}
	}
	if data, err := os.ReadFile(filepath.Join(outside, "old")); err != nil || string(data) != "old" {
		t.Fatalf("outside file changed: %q %v", data, err)
	}
	if entries, err := os.ReadDir(outside); err != nil || len(entries) != 1 {
		t.Fatalf("created outside entries: %v %v", entries, err)
	}
}

func TestConcurrentCommitsHaveOneWinner(t *testing.T) {
	directory := t.TempDir()
	root, err := os.OpenRoot(directory)
	if err != nil {
		t.Fatal(err)
	}
	defer root.Close()
	const writers = 16
	for i := range writers {
		if err := root.WriteFile(string(rune('a'+i))+".part", []byte{byte(i)}, 0600); err != nil {
			t.Fatal(err)
		}
	}
	var wg sync.WaitGroup
	results := make(chan error, writers)
	for i := range writers {
		wg.Go(func() { results <- commitFile(root, string(rune('a'+i))+".part", "winner") })
	}
	wg.Wait()
	close(results)
	winners := 0
	for err := range results {
		if err == nil {
			winners++
		} else if !errors.Is(err, os.ErrExist) {
			t.Fatal(err)
		}
	}
	data, err := root.ReadFile("winner")
	if winners != 1 || err != nil || len(data) != 1 {
		t.Fatalf("winners=%d data=%v error=%v", winners, data, err)
	}
	if _, err := root.Lstat(string(rune('a'+data[0])) + ".part"); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("winning source remains: %v", err)
	}
}

func TestCommitPreflightPreservesUnexpectedEntries(t *testing.T) {
	for _, name := range []string{".ferry-commit-check.part", ".ferry-commit-check.done"} {
		t.Run(name, func(t *testing.T) {
			root, err := os.OpenRoot(t.TempDir())
			if err != nil {
				t.Fatal(err)
			}
			defer root.Close()
			if err := root.WriteFile(name, []byte("existing"), 0600); err != nil {
				t.Fatal(err)
			}
			if err := checkCommitSupport(root); !errors.Is(err, os.ErrExist) {
				t.Fatalf("preflight ignored existing entry: %v", err)
			}
			if data, err := root.ReadFile(name); err != nil || string(data) != "existing" {
				t.Fatalf("preflight changed existing entry: %q %v", data, err)
			}
		})
	}
}

func TestCancelAfterLastByteDoesNotCommit(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	f := fixture()
	f.afterRead = cancel
	output, err := engine(f).Download(ctx, Request{StorageID: 1, ObjectIDs: []uint32{2}, Destination: t.TempDir()}, "phone")
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("expected cancellation: %v", err)
	}
	entries, err := os.ReadDir(filepath.Join(output, "files"))
	if err != nil || len(entries) != 0 || reportAt(t, output).State != "cancelled" {
		t.Fatalf("cancelled transfer published data: %v %v", entries, err)
	}
}

// Opt-in only: writes synthetic data inside a uniquely named test directory,
// never opens USB, and removes only that directory when the test finishes.
func TestExternalVolumeDownload(t *testing.T) {
	volume := os.Getenv("FERRY_TEST_VOLUME")
	if volume == "" {
		t.Skip("set FERRY_TEST_VOLUME to explicitly test an external destination")
	}
	directory, err := os.MkdirTemp(volume, ".ferry-download-test-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := os.RemoveAll(directory); err != nil {
			t.Errorf("clean test directory %s: %v", directory, err)
		}
	})
	t.Logf("synthetic download destination: %s", directory)
	// Unsupported exclusive rename is expected on macOS exFAT; the download
	// must choose exclusive-copy compatibility automatically.
	t.Run("download-hash-and-time", func(t *testing.T) {
		f := fixture()
		entry := f.entries[2]
		entry.Modified = time.Date(2026, 2, 28, 19, 31, 40, 0, time.FixedZone("UTC+8", 8*3600)).Unix()
		f.entries[2] = entry
		e := engine(f)
		e.Available = nil // Check actual free space on the selected volume.
		output, err := e.Download(context.Background(), Request{StorageID: 1, ObjectIDs: []uint32{1}, Destination: directory}, "synthetic")
		if err != nil {
			t.Fatal(err)
		}
		path := filepath.Join(output, "files", "照片", "旅行.txt")
		data, err := os.ReadFile(path)
		if err != nil || string(data) != "hello" {
			t.Fatalf("data=%q error=%v", data, err)
		}
		hash := sha256.Sum256(data)
		report := reportAt(t, output)
		if report.State != "completed" || report.Items[1].SHA256 != hex.EncodeToString(hash[:]) {
			t.Fatalf("unexpected report: %+v", report)
		}
		info, err := os.Stat(path)
		if err != nil || info.ModTime().Unix() != entry.Modified {
			t.Fatalf("modification time not preserved: %v %v", info, err)
		}
		if matches, _ := filepath.Glob(filepath.Join(output, "files", ".ferry-*")); len(matches) != 0 {
			t.Fatalf("temporary files left: %v", matches)
		}
	})
	t.Run("direct-keep-both", func(t *testing.T) {
		destination, err := os.MkdirTemp(directory, "direct-")
		if err != nil {
			t.Fatal(err)
		}
		testDownloadLayout(t, destination, t.TempDir(), "direct", false)
	})
}
