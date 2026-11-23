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

func TestCooperativeDownloadRequestProtocol(t *testing.T) {
	var req Request
	if err := json.Unmarshal([]byte(`{"operation":"download","downloadID":"task","downloadAction":"next","storageID":7,"deviceKey":"phone"}`), &req); err != nil {
		t.Fatal(err)
	}
	if req.DownloadID != "task" || req.DownloadAction != "next" || req.StorageID != 7 || req.DeviceKey != "phone" {
		t.Fatalf("%+v", req)
	}
	var legacy Request
	if err := json.Unmarshal([]byte(`{"operation":"download"}`), &legacy); err != nil || legacy.DownloadID != "" || legacy.DownloadAction != "" {
		t.Fatalf("legacy request changed: %+v %v", legacy, err)
	}
}

func twoFileFixture() *fakeDevice {
	f := fixture()
	f.entries[4] = Entry{ID: 4, StorageID: 1, Name: "second.txt", Size: 6}
	f.data[4] = []byte("second")
	f.children[1] = append(f.children[1], 4)
	return f
}

func TestDownloadJobYieldsOnlyAfterCompleteFilesAndKeepsOneReport(t *testing.T) {
	f := twoFileFixture()
	e := engine(f)
	var progress []Event
	e.Emit = func(event Event) {
		if event.Type == "progress" {
			progress = append(progress, event)
		}
	}
	destination := t.TempDir()
	job, output, err := e.PrepareDownload(context.Background(), Request{StorageID: 1, ObjectIDs: []uint32{1}, Destination: destination}, "phone")
	if err != nil {
		t.Fatal(err)
	}
	defer job.Cancel()
	if len(f.read) != 0 || len(progress) != 1 || progress[0].Total != 2 || progress[0].TotalBytes != 11 {
		t.Fatalf("preparation read contents or lost totals: %v %+v", f.read, progress)
	}
	done, err := job.Step(context.Background())
	if err != nil || done || !reflect.DeepEqual(f.read, []uint32{2}) {
		t.Fatalf("first step: %v %v %v", done, err, f.read)
	}
	if matches, _ := filepath.Glob(filepath.Join(output, "files", ".ferry-*.part")); len(matches) != 0 {
		t.Fatal("yielded with a partial file")
	}
	if _, err := f.List(context.Background(), 2, 999); err != nil {
		t.Fatal(err)
	}
	done, err = job.Step(context.Background())
	if err != nil || !done || !reflect.DeepEqual(f.read, []uint32{2, 4}) {
		t.Fatalf("second step: %v %v %v", done, err, f.read)
	}
	report := reportAt(t, output)
	if report.State != "completed" || len(report.Items) != 4 {
		t.Fatalf("report: %+v", report)
	}
	for _, item := range report.Items {
		if item.State != "completed" {
			t.Fatalf("unfinished item: %+v", item)
		}
		if item.Entry.IsDirectory {
			continue
		}
		data, err := os.ReadFile(filepath.Join(output, "files", item.Path))
		if err != nil {
			t.Fatal(err)
		}
		hash := sha256.Sum256(data)
		if item.SHA256 != hex.EncodeToString(hash[:]) {
			t.Fatal("hash mismatch")
		}
	}
	last := progress[len(progress)-1]
	if last.Completed != 2 || last.Bytes != 11 || last.Total != 2 || last.Output != output {
		t.Fatalf("lost cumulative progress: %+v", last)
	}
	entries, _ := os.ReadDir(destination)
	if len(entries) != 1 {
		t.Fatal("created multiple task directories")
	}
	if _, err := job.files.Stat("."); err == nil {
		t.Fatal("completed task kept filesystem root open")
	}
}

func TestDownloadJobCancellationBetweenStepsPreservesCompletedFiles(t *testing.T) {
	f := twoFileFixture()
	job, output, err := engine(f).PrepareDownload(context.Background(), Request{StorageID: 1, ObjectIDs: []uint32{1}, Destination: t.TempDir()}, "phone")
	if err != nil {
		t.Fatal(err)
	}
	if done, err := job.Step(context.Background()); err != nil || done {
		t.Fatalf("%v %v", done, err)
	}
	if err := job.Cancel(); err != nil {
		t.Fatal(err)
	}
	if err := job.Cancel(); err != nil {
		t.Fatal(err)
	}
	report := reportAt(t, output)
	if report.State != "cancelled" || report.Items[1].State != "completed" || report.Items[3].State != "pending" {
		t.Fatalf("%+v", report)
	}
	if data, err := os.ReadFile(filepath.Join(output, "files", "照片", "旅行.txt")); err != nil || string(data) != "hello" {
		t.Fatalf("%q %v", data, err)
	}
	if _, err := os.Stat(filepath.Join(output, "files", "照片", "second.txt")); !os.IsNotExist(err) {
		t.Fatal("read a cancelled file")
	}
	if _, err := job.Step(context.Background()); err == nil || len(f.read) != 1 {
		t.Fatal("closed task resumed")
	}
}

func TestDownloadJobFailureStopsAndClosesTheEntireTask(t *testing.T) {
	for _, failure := range []string{"read", "space", "cancel"} {
		t.Run(failure, func(t *testing.T) {
			f := twoFileFixture()
			e := engine(f)
			job, output, err := e.PrepareDownload(context.Background(), Request{StorageID: 1, ObjectIDs: []uint32{1}, Destination: t.TempDir()}, "phone")
			if err != nil {
				t.Fatal(err)
			}
			if _, err := job.Step(context.Background()); err != nil {
				t.Fatal(err)
			}
			ctx := context.Background()
			state := "failed"
			switch failure {
			case "read":
				f.readErr = errors.New("USB disconnected")
			case "space":
				e.Available = func(string) (uint64, error) { return 0, nil }
			case "cancel":
				var cancel context.CancelFunc
				ctx, cancel = context.WithCancel(ctx)
				e.Emit = func(event Event) {
					if event.CurrentFile != "" {
						cancel()
					}
				}
				state = "cancelled"
			}
			if _, err := job.Step(ctx); err == nil {
				t.Fatal("expected failure")
			}
			if report := reportAt(t, output); report.State != state || report.Items[1].State != "completed" {
				t.Fatalf("%+v", report)
			}
			if _, err := os.Stat(filepath.Join(output, "files", "照片", "second.txt")); !os.IsNotExist(err) {
				t.Fatal("failed file committed")
			}
			if _, err := job.files.Stat("."); err == nil {
				t.Fatal("failed task kept roots open")
			}
		})
	}
}
