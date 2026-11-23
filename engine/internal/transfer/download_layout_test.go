package transfer

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestDownloadLayoutProtocol(t *testing.T) {
	var req Request
	if err := json.Unmarshal([]byte(`{"operation":"download","downloadLayout":"direct","reportDirectory":"/tmp/reports"}`), &req); err != nil {
		t.Fatal(err)
	}
	if req.DownloadLayout != "direct" || req.ReportDirectory != "/tmp/reports" {
		t.Fatal(req)
	}
	data, err := json.Marshal(Event{Type: "progress", ReportPath: "/tmp/reports/report.json"})
	if err != nil {
		t.Fatal(err)
	}
	var event map[string]any
	if err := json.Unmarshal(data, &event); err != nil || event["reportPath"] != "/tmp/reports/report.json" {
		t.Fatalf("%s %v", data, err)
	}
}

func TestDownloadLayoutsKeepBothAndSeparateReports(t *testing.T) {
	for _, layout := range []string{"direct", "folder"} {
		for _, copyCommit := range []bool{false, true} {
			t.Run(layout+map[bool]string{false: "/atomic", true: "/copy"}[copyCommit], func(t *testing.T) {
				testDownloadLayout(t, t.TempDir(), t.TempDir(), layout, copyCommit)
			})
		}
	}
}

func testDownloadLayout(t *testing.T, destination, reports, layout string, forceCopy bool) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(destination, "旅行.txt"), []byte("old"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(destination, "照片"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(destination, "照片", "old.jpg"), []byte("old photo"), 0600); err != nil {
		t.Fatal(err)
	}
	f := fixture()
	// Two distinct objects whose names collide on common destination volumes.
	f.entries[4] = Entry{ID: 4, StorageID: 1, Name: "旅行.txt", Size: 3}
	f.data[4] = []byte("new")
	f.entries[5] = Entry{ID: 5, StorageID: 1, Name: "旅行.txt", Size: 5}
	f.data[5] = []byte("hello")
	f.children[1] = []uint32{5, 3}
	e := engine(f)
	job, output, err := e.PrepareDownload(context.Background(), Request{StorageID: 1, ObjectIDs: []uint32{2, 4, 1}, Destination: destination, DownloadLayout: layout, ReportDirectory: reports}, "synthetic")
	if err != nil {
		t.Fatal(err)
	}
	defer job.Cancel()
	if forceCopy {
		job.copyCommit = true
	}
	if layout == "direct" && output != destination {
		t.Fatalf("direct output=%s", output)
	}
	if layout == "folder" && (output == destination || filepath.Dir(output) != destination) {
		t.Fatalf("folder output=%s", output)
	}
	for {
		done, err := job.Step(context.Background())
		if err != nil {
			t.Fatal(err)
		}
		if done {
			break
		}
	}
	data, err := os.ReadFile(job.ReportPath)
	if err != nil {
		t.Fatal(err)
	}
	var report Report
	if err := json.Unmarshal(data, &report); err != nil {
		t.Fatal(err)
	}
	if report.State != "completed" || report.Output != output || len(report.Items) != 5 {
		t.Fatalf("report=%+v", report)
	}
	if filepath.Dir(filepath.Dir(job.ReportPath)) != reports {
		t.Fatalf("report outside reports directory: %s", job.ReportPath)
	}
	var paths []string
	for _, item := range report.Items {
		paths = append(paths, item.Path)
		if item.Entry.IsDirectory {
			continue
		}
		got, err := os.ReadFile(filepath.Join(output, item.Path))
		if err != nil || !reflect.DeepEqual(got, f.data[item.Entry.ID]) {
			t.Fatalf("%s: %q %v", item.Path, got, err)
		}
		hash := sha256.Sum256(got)
		if item.SHA256 != hex.EncodeToString(hash[:]) {
			t.Fatal("hash mismatch")
		}
	}
	want := []string{"旅行 (1).txt", "旅行 (2).txt", "照片 (1)", "照片 (1)/旅行.txt", "照片 (1)/空目录"}
	if layout == "folder" {
		want = []string{"旅行.txt", "旅行 (1).txt", "照片", "照片/旅行.txt", "照片/空目录"}
	}
	if !reflect.DeepEqual(paths, want) {
		t.Fatalf("paths=%v want=%v", paths, want)
	}
	if got, err := os.ReadFile(filepath.Join(destination, "旅行.txt")); err != nil || string(got) != "old" {
		t.Fatalf("old file changed: %q %v", got, err)
	}
	if got, err := os.ReadFile(filepath.Join(destination, "照片", "old.jpg")); err != nil || string(got) != "old photo" {
		t.Fatalf("old folder changed: %q %v", got, err)
	}
	entries, err := os.ReadDir(output)
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if entry.Name() == "传输报告.json" || entry.Name() == "任务记录.ndjson" || len(entry.Name()) >= 7 && entry.Name()[:7] == ".ferry-" {
			t.Fatalf("auxiliary entry in output: %s", entry.Name())
		}
	}
}

func TestExclusiveCopyFailureAndCancellationCleanFinalFile(t *testing.T) {
	for _, failure := range []string{"hash", "space", "cancel"} {
		t.Run(failure, func(t *testing.T) {
			root, err := os.OpenRoot(t.TempDir())
			if err != nil {
				t.Fatal(err)
			}
			defer root.Close()
			if err := root.WriteFile("source", []byte("new"), 0600); err != nil {
				t.Fatal(err)
			}
			hash := sha256.Sum256([]byte("new"))
			expected := hex.EncodeToString(hash[:])
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			e := engine(fixture())
			checks := 0
			e.Available = func(string) (uint64, error) {
				checks++
				if checks > 1 && failure == "space" {
					return 0, nil
				}
				if checks > 1 && failure == "cancel" {
					cancel()
				}
				return 1 << 40, nil
			}
			if failure == "hash" {
				expected = "wrong"
			}
			err = e.copyExclusive(ctx, root, root.Name(), "source", "target", Entry{Size: 3}, expected)
			if err == nil {
				t.Fatal("expected failure")
			}
			if failure == "cancel" && !errors.Is(err, context.Canceled) {
				t.Fatal(err)
			}
			if _, err := root.Stat("target"); !errors.Is(err, os.ErrNotExist) {
				t.Fatalf("incomplete target remains: %v", err)
			}
			if got, err := root.ReadFile("source"); err != nil || string(got) != "new" {
				t.Fatalf("source changed: %q %v", got, err)
			}
		})
	}
}

func TestDirectDownloadCancellationKeepsEarlierFileAndExistingFiles(t *testing.T) {
	e := engine(twoFileFixture())
	destination := t.TempDir()
	job, _, err := e.PrepareDownload(context.Background(), Request{StorageID: 1, ObjectIDs: []uint32{1}, Destination: destination, DownloadLayout: "direct", ReportDirectory: t.TempDir()}, "synthetic")
	if err != nil {
		t.Fatal(err)
	}
	job.copyCommit = true
	if done, err := job.Step(context.Background()); err != nil || done {
		t.Fatalf("%v %v", done, err)
	}
	if err := job.Cancel(); err != nil {
		t.Fatal(err)
	}
	if got, err := os.ReadFile(filepath.Join(destination, "照片", "旅行.txt")); err != nil || string(got) != "hello" {
		t.Fatalf("earlier file lost: %q %v", got, err)
	}
	if _, err := os.Stat(filepath.Join(destination, "照片", "second.txt")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("cancelled file exists: %v", err)
	}
	if matches, _ := filepath.Glob(filepath.Join(destination, ".ferry-*")); len(matches) != 0 {
		t.Fatalf("temporary paths remain: %v", matches)
	}
}
