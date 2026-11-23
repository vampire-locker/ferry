package transfer

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func durableFixture(t *testing.T, layout string) (*fakeDevice, *Engine, Request, *DownloadJob) {
	t.Helper()
	f := twoFileFixture()
	f.children[0] = []uint32{1}
	e := engine(f)
	e.Storages = []Storage{{ID: 1, Name: "phone storage", Capacity: 1 << 40}}
	req := Request{Operation: "download", DownloadID: "durable-task", DownloadAction: "begin", DeviceKey: f.Identity(), StorageID: 1,
		ObjectIDs: []uint32{1}, SourceSelection: []Entry{f.entries[1]}, DurableRecovery: true, RecoveryIdentity: "test", SourceStorage: &e.Storages[0],
		Destination: t.TempDir(), DownloadLayout: layout, ReportDirectory: t.TempDir(), PromptConflicts: true}
	req.SourceDirectory = []string{} // Swift encodes an empty array for a storage-root selection.
	job, _, err := e.PrepareDownload(context.Background(), req, "phone")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { job.Cancel() })
	if job.RecoveryPath == "" {
		t.Fatal("no durable record")
	}
	return f, e, req, job
}

func reconnectFixture(f *fakeDevice, offset uint32) *fakeDevice {
	next := &fakeDevice{entries: map[uint32]Entry{}, children: map[uint32][]uint32{}, data: map[uint32][]byte{}}
	for id, value := range f.entries {
		value.ID, value.StorageID = id+offset, 9
		next.entries[value.ID] = value
	}
	for id, data := range f.data {
		next.data[id+offset] = data
	}
	for parent, children := range f.children {
		key := parent
		if parent != 0 {
			key += offset
		}
		for _, id := range children {
			next.children[key] = append(next.children[key], id+offset)
		}
	}
	return next
}

func durableEngine(f *fakeDevice) *Engine {
	e := engine(f)
	e.Storages = []Storage{{ID: 9, Name: "phone storage", Capacity: 1 << 40}}
	return e
}

func recoverRequest(req Request, job *DownloadJob) Request {
	req.DownloadAction, req.RecoveryPath, req.StorageID = "recover", job.RecoveryPath, 9
	return req
}

func TestDurableRecoveryRemapsHandlesAndRetainsNumberedDirectories(t *testing.T) {
	for _, layout := range []string{"direct", "folder"} {
		for _, copyCommit := range []bool{false, true} {
			t.Run(layout+map[bool]string{false: "/rename", true: "/copy"}[copyCommit], func(t *testing.T) {
				f, _, req, job := durableFixture(t, layout)
				job.copyCommit = copyCommit
				// Emulate the volume probe selecting the exclusive-copy path.
				data, err := os.ReadFile(job.RecoveryPath)
				if err != nil {
					t.Fatal(err)
				}
				var manifest recoveryManifest
				if err := json.Unmarshal(data, &manifest); err != nil {
					t.Fatal(err)
				}
				manifest.CopyCommit = copyCommit
				data, err = json.Marshal(manifest)
				if err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(job.RecoveryPath, data, 0600); err != nil {
					t.Fatal(err)
				}
				if err := os.Mkdir(filepath.Join(job.Output, "照片"), 0700); err != nil {
					t.Fatal(err)
				}
				if _, err := job.Step(context.Background()); err != nil {
					t.Fatal(err)
				}
				first := filepath.Join(job.Output, "照片 (1)", "旅行.txt")
				before, err := os.Stat(first)
				if err != nil {
					t.Fatal(err)
				}
				if err := job.Cancel(); err != nil {
					t.Fatal(err)
				}
				next := reconnectFixture(f, 1000)
				recovered, output, err := durableEngine(next).RecoverDownload(context.Background(), recoverRequest(req, job), "phone")
				if err != nil {
					t.Fatal(err)
				}
				defer recovered.Cancel()
				if recovered.copyCommit != copyCommit {
					t.Fatal("lost the volume commit mode")
				}
				runResumedJob(t, recovered)
				if output != job.Output || recovered.ReportPath != job.ReportPath || recovered.reusedBytes != 5 || !reflect.DeepEqual(next.read, []uint32{1004}) {
					t.Fatalf("output=%s reused=%d reads=%v", output, recovered.reusedBytes, next.read)
				}
				after, err := os.Stat(first)
				if err != nil || !os.SameFile(before, after) || !before.ModTime().Equal(after.ModTime()) {
					t.Fatal("rewrote the verified file", err)
				}
				if data, err := os.ReadFile(filepath.Join(output, "照片 (1)", "second.txt")); err != nil || string(data) != "second" {
					t.Fatalf("%q %v", data, err)
				}
				if _, err := os.Stat(filepath.Join(output, "照片 (2)")); !os.IsNotExist(err) {
					t.Fatal("duplicated the source directory")
				}
				// A new process can replay records containing the remapped IDs too.
				again := reconnectFixture(f, 2000)
				verified, _, err := durableEngine(again).RecoverDownload(context.Background(), recoverRequest(req, job), "phone")
				if err != nil {
					t.Fatal(err)
				}
				runResumedJob(t, verified)
				if len(again.read) != 0 || verified.reusedBytes != 11 {
					t.Fatal("did not reuse completed recovery", again.read)
				}
			})
		}
	}
}

func TestDurableRecoveryRejectsChangedSourcesAndDestinations(t *testing.T) {
	for _, change := range []string{"source", "missing", "ambiguous", "storage", "duplicate storage", "destination", "journal link", "settings"} {
		t.Run(change, func(t *testing.T) {
			f, _, req, job := durableFixture(t, "direct")
			if _, err := job.Step(context.Background()); err != nil {
				t.Fatal(err)
			}
			if err := job.Cancel(); err != nil {
				t.Fatal(err)
			}
			next := reconnectFixture(f, 1000)
			e := durableEngine(next)
			recoverReq := recoverRequest(req, job)
			switch change {
			case "source":
				value := next.entries[1004]
				value.Size++
				next.entries[1004] = value
			case "missing":
				next.children[1001] = []uint32{1002, 1003}
			case "ambiguous":
				next.children[1001] = append(next.children[1001], 1004)
			case "storage":
				e.Storages[0].Capacity++
			case "duplicate storage":
				e.Storages = append(e.Storages, Storage{ID: 10, Name: "phone storage", Capacity: 1 << 40})
			case "destination":
				if err := os.Rename(job.Output, job.Output+"-old"); err != nil {
					t.Fatal(err)
				}
				if err := os.Mkdir(job.Output, 0700); err != nil {
					t.Fatal(err)
				}
			case "journal link":
				path := filepath.Join(filepath.Dir(job.ReportPath), "任务记录.ndjson")
				if err := os.Rename(path, path+"-old"); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink(path+"-old", path); err != nil {
					t.Fatal(err)
				}
			case "settings":
				recoverReq.ArchiveVideosByMonth = true
			}
			recovered, _, err := e.RecoverDownload(context.Background(), recoverReq, "phone")
			if err == nil {
				defer recovered.Cancel()
				for step := 0; step < 10 && err == nil; step++ {
					var done bool
					done, err = recovered.Step(context.Background())
					if done {
						break
					}
				}
			}
			if err == nil || len(next.read) != 0 {
				t.Fatalf("unsafe recovery: change=%s reads=%v err=%v", change, next.read, err)
			}
		})
	}
}

func TestDurableRecoveryRechecksCorruptLocalFilesAndKeepsExplicitSkips(t *testing.T) {
	for _, choice := range []string{"skip", "keepBoth"} {
		t.Run(choice, func(t *testing.T) {
			f, _, req, job := durableFixture(t, "direct")
			if _, err := job.Step(context.Background()); err != nil {
				t.Fatal(err)
			}
			if err := job.Cancel(); err != nil {
				t.Fatal(err)
			}
			target := filepath.Join(job.Output, "照片", "旅行.txt")
			if err := os.WriteFile(target, []byte("xxxxx"), 0600); err != nil {
				t.Fatal(err)
			}
			next := reconnectFixture(f, 1000)
			recovered, _, err := durableEngine(next).RecoverDownload(context.Background(), recoverRequest(req, job), "phone")
			if err != nil {
				t.Fatal(err)
			}
			defer recovered.Cancel()
			if _, err := recovered.Step(context.Background()); err != nil || recovered.Conflict() == nil || len(next.read) != 0 {
				t.Fatalf("corrupt file trusted or read before consent: %v", err)
			}
			if err := recovered.ResolveConflict(decisionFor(recovered, choice, false)); err != nil {
				t.Fatal(err)
			}
			runResumedJob(t, recovered)
			if data, _ := os.ReadFile(target); string(data) != "xxxxx" {
				t.Fatal("overwrote the modified local file")
			}
			if choice == "skip" {
				again := reconnectFixture(f, 2000)
				delete(again.entries, 2002)
				verified, _, err := durableEngine(again).RecoverDownload(context.Background(), recoverRequest(req, job), "phone")
				if err != nil {
					t.Fatal(err)
				}
				runResumedJob(t, verified)
				if len(again.read) != 0 || verified.skipped != 1 {
					t.Fatal("lost the explicit skip")
				}
			}
		})
	}
}

func TestDurableRecoveryHandlesCrashTailAndRejectsUnsafeJournal(t *testing.T) {
	for _, tail := range []string{"partial", "unsafe", "invalid"} {
		t.Run(tail, func(t *testing.T) {
			f, _, req, job := durableFixture(t, "direct")
			if _, err := job.Step(context.Background()); err != nil {
				t.Fatal(err)
			}
			var data []byte
			switch tail {
			case "partial":
				data = []byte(`{"recoveryIndex":`)
			case "invalid":
				data = []byte("not-json\n")
			case "unsafe":
				item := job.report.Items[1]
				item.Path = "../outside"
				data, _ = json.Marshal(item)
				data = append(data, '\n')
			}
			if _, err := job.journal.Write(data); err != nil {
				t.Fatal(err)
			}
			if err := job.journal.Sync(); err != nil {
				t.Fatal(err)
			}
			// Simulate process loss without finalizing a human report.
			job.journal.Close()
			job.files.Close()
			job.root.Close()
			job.closed = true
			next := reconnectFixture(f, 1000)
			recovered, _, err := durableEngine(next).RecoverDownload(context.Background(), recoverRequest(req, job), "phone")
			if tail != "partial" {
				if err == nil {
					recovered.Cancel()
					t.Fatal("accepted an unsafe journal")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			runResumedJob(t, recovered)
			again, _, err := durableEngine(next).RecoverDownload(context.Background(), recoverRequest(req, job), "phone")
			if err != nil {
				t.Fatal("partial tail was not removed before appending", err)
			}
			runResumedJob(t, again)
		})
	}
}

func TestDurableRecoveryLocksTheOriginalJournal(t *testing.T) {
	f, _, req, job := durableFixture(t, "direct")
	next := reconnectFixture(f, 1000)
	if other, _, err := durableEngine(next).RecoverDownload(context.Background(), recoverRequest(req, job), "phone"); err == nil {
		other.Cancel()
		t.Fatal("two processes own the journal")
	}
	if _, err := job.Step(context.Background()); err != nil {
		t.Fatal("second recovery affected the live owner", err)
	}
}

type stableRecoveryFake struct {
	*fakeDevice
	stable string
}

func (d *stableRecoveryFake) RecoveryIdentity() string { return d.stable }

func TestDurableRecoveryRequiresStablePhoneIdentity(t *testing.T) {
	f, _, req, job := durableFixture(t, "direct")
	if err := job.Cancel(); err != nil {
		t.Fatal(err)
	}
	next := reconnectFixture(f, 1000)
	e := durableEngine(next)
	e.Device = &stableRecoveryFake{fakeDevice: next, stable: "another-phone"}
	if recovered, _, err := e.RecoverDownload(context.Background(), recoverRequest(req, job), "phone"); err == nil {
		recovered.Cancel()
		t.Fatal("recovered onto another phone")
	}
	e.Device = &stableRecoveryFake{fakeDevice: next}
	req = recoverRequest(req, job)
	req.RecoveryPath = ""
	if recovered, _, err := e.RecoverDownload(context.Background(), req, "phone"); err == nil {
		recovered.Cancel()
		t.Fatal("recovered an unplanned selection without a stable phone identity")
	}
}

func TestPhoneWithoutStableIdentityKeepsMemoryRecovery(t *testing.T) {
	f, _, req, original := durableFixture(t, "direct")
	if err := original.Cancel(); err != nil {
		t.Fatal(err)
	}
	e := engine(f)
	e.Storages = []Storage{*req.SourceStorage}
	e.Device = &stableRecoveryFake{fakeDevice: f}
	warned := false
	e.Emit = func(event Event) {
		if event.State == "session_only" && event.Message != "" {
			warned = true
		}
	}
	req.RecoveryIdentity = ""
	job, _, err := e.PrepareDownload(context.Background(), req, "phone")
	if err != nil {
		t.Fatal(err)
	}
	if !warned || job.RecoveryPath != "" {
		t.Fatal("did not explain session-only recovery")
	}
	if _, err := job.Step(context.Background()); err != nil {
		t.Fatal(err)
	}
	checkpoint, err := job.CancelForResume()
	if err != nil || checkpoint == nil {
		t.Fatalf("%v", err)
	}
	recovered, err := checkpoint.Resume(context.Background(), e)
	if err != nil {
		t.Fatal(err)
	}
	runResumedJob(t, recovered)
	if recovered.reusedBytes != 5 || len(f.read) != 2 {
		t.Fatal("lost same-connection recovery", f.read)
	}
}

func TestDurableUnstartedSelectionResolvesNewHandles(t *testing.T) {
	f, _, req, job := durableFixture(t, "direct")
	if err := job.Cancel(); err != nil {
		t.Fatal(err)
	}
	next := reconnectFixture(f, 1000)
	req = recoverRequest(req, job)
	req.RecoveryPath = ""
	recovered, _, err := durableEngine(next).RecoverDownload(context.Background(), req, "phone")
	if err != nil {
		t.Fatal(err)
	}
	runResumedJob(t, recovered)
	if !reflect.DeepEqual(next.read, []uint32{1002, 1004}) || recovered.RecoveryPath == "" {
		t.Fatal("unstarted selection was not re-resolved", next.read)
	}
	if req.SourceSelection[0].ID != 1 {
		t.Fatal("modified the caller's frozen selection")
	}
}

func TestDurableArchiveRecoveryRetainsMonthChoiceAndSkipsBeforeReread(t *testing.T) {
	f := archiveFixture(t)
	f.children[0] = []uint32{1}
	e := engine(f)
	e.Storages = []Storage{{ID: 1, Name: "phone storage", Capacity: 1 << 40}}
	req := Request{Operation: "download", DownloadID: "archive", DeviceKey: "test", RecoveryIdentity: "test", DurableRecovery: true,
		StorageID: 1, SourceStorage: &e.Storages[0], ObjectIDs: []uint32{1}, SourceSelection: []Entry{f.entries[1]},
		Destination: t.TempDir(), ReportDirectory: t.TempDir(), DownloadLayout: "direct", PromptConflicts: true, ArchivePhotosByMonth: true}
	for _, directory := range []string{"2022/02月", "2022/2"} {
		if err := os.MkdirAll(filepath.Join(req.Destination, directory), 0700); err != nil {
			t.Fatal(err)
		}
	}
	target := filepath.Join(req.Destination, "2022/2/same.jpg")
	if err := os.WriteFile(target, []byte("old"), 0600); err != nil {
		t.Fatal(err)
	}
	job, _, err := e.PrepareDownload(context.Background(), req, "phone")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := job.Step(context.Background()); err != nil || job.Conflict() == nil || job.Conflict().Kind != "monthDirectory" {
		t.Fatalf("%v", err)
	}
	if err := job.ResolveConflict(&ConflictDecision{ID: job.Conflict().ID, Choice: "directory", Directory: "2022/2"}); err != nil {
		t.Fatal(err)
	}
	if _, err := job.Step(context.Background()); err != nil || job.Conflict() == nil || job.Conflict().Kind != "file" {
		t.Fatalf("%v", err)
	}
	if err := job.Cancel(); err != nil {
		t.Fatal(err)
	}
	next := reconnectFixture(f, 1000)
	recovered, _, err := durableEngine(next).RecoverDownload(context.Background(), recoverRequest(req, job), "phone")
	if err != nil {
		t.Fatal(err)
	}
	defer recovered.Cancel()
	if _, err := recovered.Step(context.Background()); err != nil || recovered.Conflict() == nil || recovered.Conflict().Kind != "file" || len(next.read) != 0 {
		t.Fatalf("known archive path reread phone: %v %v", next.read, err)
	}
	if err := recovered.ResolveConflict(decisionFor(recovered, "skip", false)); err != nil {
		t.Fatal(err)
	}
	for step := 0; step < 30; step++ {
		done, err := recovered.Step(context.Background())
		if err != nil {
			t.Fatal(err)
		}
		if done {
			break
		}
		if conflict := recovered.Conflict(); conflict != nil {
			if conflict.Kind != "file" {
				t.Fatal("forgot the saved month choice")
			}
			if err := recovered.ResolveConflict(decisionFor(recovered, "keepBoth", false)); err != nil {
				t.Fatal(err)
			}
		}
	}
	if !recovered.closed {
		t.Fatal("recovery did not finish")
	}
	for _, id := range next.read {
		if id == 1002 {
			t.Fatal("reread an explicitly skipped archived photo")
		}
	}
	if data, _ := os.ReadFile(target); string(data) != "old" {
		t.Fatal("changed the original archived file")
	}
}

func TestDurableArchiveRecreatesMissingMonthAndRejectsLinkedParent(t *testing.T) {
	for _, linked := range []bool{false, true} {
		t.Run(map[bool]string{false: "missing", true: "linked"}[linked], func(t *testing.T) {
			f := archiveFixture(t)
			f.children[0] = []uint32{1}
			e := engine(f)
			e.Storages = []Storage{{ID: 1, Name: "phone storage", Capacity: 1 << 40}}
			req := Request{Operation: "download", DownloadID: "archive-parent", DeviceKey: "test", RecoveryIdentity: "test", DurableRecovery: true,
				StorageID: 1, SourceStorage: &e.Storages[0], ParentID: 1, SourceDirectory: []string{"Camera"}, ObjectIDs: []uint32{2, 3}, SourceSelection: []Entry{f.entries[2], f.entries[3]},
				Destination: t.TempDir(), ReportDirectory: t.TempDir(), DownloadLayout: "direct", PromptConflicts: true, ArchivePhotosByMonth: true}
			month := filepath.Join(req.Destination, "2022", "2")
			if err := os.MkdirAll(month, 0700); err != nil {
				t.Fatal(err)
			}
			job, _, err := e.PrepareDownload(context.Background(), req, "phone")
			if err != nil {
				t.Fatal(err)
			}
			if _, err := job.Step(context.Background()); err != nil {
				t.Fatal(err)
			}
			if err := job.Cancel(); err != nil {
				t.Fatal(err)
			}
			if linked {
				moved := filepath.Join(req.Destination, "moved-month")
				if err := os.Rename(month, moved); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink(moved, month); err != nil {
					t.Fatal(err)
				}
			} else if err := os.RemoveAll(month); err != nil {
				t.Fatal(err)
			}
			next := reconnectFixture(f, 1000)
			recovered, _, err := durableEngine(next).RecoverDownload(context.Background(), recoverRequest(req, job), "phone")
			if err != nil {
				t.Fatal(err)
			}
			defer recovered.Cancel()
			if linked {
				if _, err := recovered.Step(context.Background()); err == nil || len(next.read) != 0 {
					t.Fatal("followed a replaced month directory", err)
				}
				return
			}
			runResumedJob(t, recovered)
			if !reflect.DeepEqual(next.read, []uint32{1002, 1003}) {
				t.Fatal("missing archived file was not reread", next.read)
			}
			if data, err := os.ReadFile(filepath.Join(month, "same.jpg")); err != nil || !reflect.DeepEqual(data, f.data[2]) {
				t.Fatal("did not restore the original month path", err)
			}
		})
	}
}
