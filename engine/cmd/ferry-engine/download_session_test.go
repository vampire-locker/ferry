package main

import (
	"bytes"
	"context"
	"encoding/json"
	"ferry.local/engine/internal/device"
	"ferry.local/engine/internal/transfer"
	"io"
	"os"
	"path/filepath"
	"testing"
)

type sessionDevice struct {
	transfer.Device
	reads int
}

func (d *sessionDevice) Info(context.Context, uint32) (transfer.Entry, error) {
	return transfer.Entry{ID: 1, StorageID: 1, Name: "file.txt", Size: 3}, nil
}
func (d *sessionDevice) Read(_ context.Context, _ uint32, w io.Writer) error {
	d.reads++
	_, err := io.Copy(w, bytes.NewBufferString("one"))
	return err
}

func TestCooperativeSessionValidatesIDAndStorageWithoutReadingFiles(t *testing.T) {
	for _, changed := range []string{"id", "storage", "begin"} {
		t.Run(changed, func(t *testing.T) {
			dev := &sessionDevice{}
			engine := &transfer.Engine{Device: dev, Emit: func(transfer.Event) {}, Available: func(string) (uint64, error) { return 1 << 40, nil }}
			session := downloadSession{}
			defer session.close(context.Canceled)
			req := transfer.Request{Operation: "download", DownloadID: "opaque/../token", DownloadAction: "begin", StorageID: 1, ObjectIDs: []uint32{1}, Destination: t.TempDir()}
			event, output, err := session.handle(context.Background(), engine, req, "phone")
			if err != nil || event.Type != "yielded" || event.State != "running" || dev.reads != 0 {
				t.Fatalf("%+v %s %v", event, output, err)
			}
			if filepath.Base(output) == req.DownloadID {
				t.Fatal("used task ID as path")
			}
			req.DownloadAction = "next"
			switch changed {
			case "id":
				req.DownloadID = "other"
			case "storage":
				req.StorageID = 2
			case "begin":
				req.DownloadAction = "begin"
			}
			if _, _, err := session.handle(context.Background(), engine, req, "phone"); err == nil || dev.reads != 0 {
				t.Fatal("wrong task mutated active job")
			}
		})
	}
}

func TestCooperativeSessionCancelAndEOFStyleCleanupWriteFinalReports(t *testing.T) {
	for _, action := range []string{"cancel", "eof", "next"} {
		t.Run(action, func(t *testing.T) {
			dev := &sessionDevice{}
			engine := &transfer.Engine{Device: dev, Emit: func(transfer.Event) {}, Available: func(string) (uint64, error) { return 1 << 40, nil }}
			session := downloadSession{}
			req := transfer.Request{DownloadID: "task", DownloadAction: "begin", StorageID: 1, ObjectIDs: []uint32{1}, Destination: t.TempDir()}
			_, output, err := session.handle(context.Background(), engine, req, "phone")
			if err != nil {
				t.Fatal(err)
			}
			if action == "eof" {
				if err := session.close(context.Canceled); err != nil {
					t.Fatal(err)
				}
			} else {
				req.DownloadAction = action
				event, nextOutput, err := session.handle(context.Background(), engine, req, "phone")
				if err != nil || event.Type != "completed" || nextOutput != output {
					t.Fatalf("%+v %v", event, err)
				}
			}
			data, err := os.ReadFile(filepath.Join(output, "传输报告.json"))
			if err != nil {
				t.Fatal(err)
			}
			var report transfer.Report
			if err := json.Unmarshal(data, &report); err != nil {
				t.Fatal(err)
			}
			want := "cancelled"
			if action == "next" {
				want = "completed"
			}
			if report.State != want || session.job != nil {
				t.Fatalf("%+v %+v", report, session)
			}
		})
	}
}

func TestCooperativeSessionYieldsConflictAndResolvesWithoutRereading(t *testing.T) {
	dev := &sessionDevice{}
	engine := &transfer.Engine{Device: dev, Emit: func(transfer.Event) {}, Available: func(string) (uint64, error) { return 1 << 40, nil }}
	destination := t.TempDir()
	if err := os.WriteFile(filepath.Join(destination, "file.txt"), []byte("old"), 0600); err != nil {
		t.Fatal(err)
	}
	session := downloadSession{}
	defer session.close(context.Canceled)
	req := transfer.Request{DownloadID: "task", DownloadAction: "begin", StorageID: 1, ObjectIDs: []uint32{1}, Destination: destination, DownloadLayout: "direct", ReportDirectory: t.TempDir(), PromptConflicts: true}
	if _, _, err := session.handle(context.Background(), engine, req, "phone"); err != nil {
		t.Fatal(err)
	}
	req.DownloadAction = "next"
	event, _, err := session.handle(context.Background(), engine, req, "phone")
	if err != nil || event.Type != "yielded" || event.State != "waiting" || event.Conflict == nil || dev.reads != 0 {
		t.Fatalf("%+v reads=%d error=%v", event, dev.reads, err)
	}
	req.DownloadAction = "resolve"
	req.ConflictDecision = &transfer.ConflictDecision{ID: event.Conflict.ID, Choice: "replace", ApplyToAll: true}
	event, _, err = session.handle(context.Background(), engine, req, "phone")
	if err != nil || event.Type != "completed" || dev.reads != 1 {
		t.Fatalf("%+v reads=%d error=%v", event, dev.reads, err)
	}
	if data, err := os.ReadFile(filepath.Join(destination, "file.txt")); err != nil || string(data) != "one" {
		t.Fatalf("%q %v", data, err)
	}
}

func TestCancelledSessionResumeTokenIsBoundToOriginalTaskAndOptions(t *testing.T) {
	for _, change := range []string{"none", "id", "storage", "objects", "destination", "archive", "video archive", "token", "closed"} {
		t.Run(change, func(t *testing.T) {
			dev := &sessionDevice{}
			engine := &transfer.Engine{Device: dev, Emit: func(transfer.Event) {}, Available: func(string) (uint64, error) { return 1 << 40, nil }}
			session := downloadSession{}
			defer session.close(context.Canceled)
			req := transfer.Request{DownloadID: "task", DownloadAction: "begin", StorageID: 1, ObjectIDs: []uint32{1}, Destination: t.TempDir(), DownloadLayout: "folder", ReportDirectory: t.TempDir()}
			_, output, err := session.handle(context.Background(), engine, req, "phone")
			if err != nil {
				t.Fatal(err)
			}
			req.DownloadAction = "cancel"
			event, _, err := session.handle(context.Background(), engine, req, "phone")
			if err != nil || event.ResumeToken == "" || session.job != nil {
				t.Fatalf("%+v %v", event, err)
			}
			req.DownloadAction, req.ResumeToken = "resume", event.ResumeToken
			switch change {
			case "id":
				req.DownloadID = "another"
			case "storage":
				req.StorageID = 2
			case "objects":
				req.ObjectIDs = []uint32{2}
			case "destination":
				req.Destination = t.TempDir()
			case "archive":
				req.ArchivePhotosByMonth = true
			case "video archive":
				req.ArchiveVideosByMonth = true
			case "token":
				req.ResumeToken = "not-a-token"
			case "closed":
				session.close(context.Canceled)
			}
			event, resumedOutput, err := session.handle(context.Background(), engine, req, "phone")
			if change != "none" {
				if err == nil || dev.reads != 0 {
					t.Fatalf("invalid resume read phone: %v reads=%d", err, dev.reads)
				}
				return
			}
			if err != nil || event.Type != "yielded" || resumedOutput != output || dev.reads != 0 {
				t.Fatalf("%+v %v %s", event, err, resumedOutput)
			}
			if len(session.checkpoints) != 0 {
				t.Fatal("resume token was not consumed")
			}
			req.DownloadAction = "next"
			event, _, err = session.handle(context.Background(), engine, req, "phone")
			if err != nil || event.State != "completed" || dev.reads != 1 {
				t.Fatalf("%+v %v", event, err)
			}
		})
	}
}

func TestRecoveryCapacityLimitStillCancelsAndClosesNormally(t *testing.T) {
	dev := &sessionDevice{}
	engine := &transfer.Engine{Device: dev, Emit: func(transfer.Event) {}, Available: func(string) (uint64, error) { return 1 << 40, nil }}
	session := downloadSession{retained: 1_000_000}
	req := transfer.Request{DownloadID: "task", DownloadAction: "begin", StorageID: 1, ObjectIDs: []uint32{1}, Destination: t.TempDir()}
	if _, _, err := session.handle(context.Background(), engine, req, "phone"); err != nil {
		t.Fatal(err)
	}
	job := session.job
	req.DownloadAction = "cancel"
	event, _, err := session.handle(context.Background(), engine, req, "phone")
	if err != nil || event.State != "cancelled" || event.ResumeToken != "" || event.Message == "" || session.job != nil {
		t.Fatalf("%+v %v", event, err)
	}
	if _, err := job.Step(context.Background()); err == nil {
		t.Fatal("capacity limit left job active")
	}
}

func TestDiskRecoveryInNewSessionCanCancelAndResumeAgain(t *testing.T) {
	dev := &device.Demo{}
	_, storages, err := dev.Connect(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	first, _ := dev.Info(context.Background(), 101)
	second, _ := dev.Info(context.Background(), 102)
	folder, _ := dev.Info(context.Background(), 10)
	engine := &transfer.Engine{Device: dev, Storages: storages, Emit: func(transfer.Event) {}, Available: func(string) (uint64, error) { return 1 << 40, nil }}
	req := transfer.Request{Operation: "download", DownloadID: "disk-recovery", DownloadAction: "begin",
		DeviceKey: dev.Identity(), RecoveryIdentity: dev.Identity(), StorageID: 1, ObjectIDs: []uint32{101, 102},
		SourceSelection: []transfer.Entry{first, second}, SourceStorage: &storages[0], DurableRecovery: true,
		SourceDirectory: []string{folder.Name}, ParentID: 10,
		Destination: t.TempDir(), DownloadLayout: "direct", ReportDirectory: t.TempDir(), PromptConflicts: true}
	original := downloadSession{}
	event, output, err := original.handle(context.Background(), engine, req, "demo")
	if err != nil || event.RecoveryPath == "" {
		t.Fatalf("%+v %v", event, err)
	}
	recoveryPath := event.RecoveryPath
	req.DownloadAction = "next"
	if _, _, err := original.handle(context.Background(), engine, req, "demo"); err != nil {
		t.Fatal(err)
	}
	completedFile := filepath.Join(output, first.Name)
	before, err := os.Stat(completedFile)
	if err != nil {
		t.Fatal(err)
	}
	if err := original.close(context.Canceled); err != nil {
		t.Fatal(err)
	}
	engine.Device = &device.Demo{}
	reconnected := downloadSession{}
	defer reconnected.close(context.Canceled)
	req.DownloadAction, req.RecoveryPath = "recover", recoveryPath
	if _, recoveredOutput, err := reconnected.handle(context.Background(), engine, req, "demo"); err != nil || recoveredOutput != output {
		t.Fatalf("%s %v", recoveredOutput, err)
	}
	req.DownloadAction, req.RecoveryPath = "next", ""
	if _, _, err := reconnected.handle(context.Background(), engine, req, "demo"); err != nil {
		t.Fatal(err)
	}
	req.DownloadAction = "cancel"
	event, _, err = reconnected.handle(context.Background(), engine, req, "demo")
	if err != nil || event.ResumeToken == "" {
		t.Fatalf("%+v %v", event, err)
	}
	req.DownloadAction, req.ResumeToken = "resume", event.ResumeToken
	if _, _, err := reconnected.handle(context.Background(), engine, req, "demo"); err != nil {
		t.Fatal("disk recovery broke subsequent memory recovery", err)
	}
	req.DownloadAction, req.ResumeToken = "next", ""
	for step := 0; step < 4; step++ {
		event, _, err = reconnected.handle(context.Background(), engine, req, "demo")
		if err != nil {
			t.Fatal(err)
		}
		if event.Type == "completed" {
			break
		}
	}
	if event.State != "completed" {
		t.Fatal("recovery did not complete")
	}
	after, err := os.Stat(completedFile)
	if err != nil || !os.SameFile(before, after) {
		t.Fatal("rewrote the original verified file", err)
	}
}
