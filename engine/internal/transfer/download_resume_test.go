package transfer

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestDownloadRecoveryWireFields(t *testing.T) {
	var request Request
	if err := json.Unmarshal([]byte(`{"operation":"download","downloadAction":"resume","downloadID":"task","resumeToken":"token"}`), &request); err != nil {
		t.Fatal(err)
	}
	if request.DownloadAction != "resume" || request.ResumeToken != "token" || request.DownloadID != "task" {
		t.Fatalf("%+v", request)
	}
	data, err := json.Marshal(Event{Type: "progress", ReusedBytes: 4_294_967_296, ResumeToken: "token"})
	if err != nil {
		t.Fatal(err)
	}
	var event Event
	if err := json.Unmarshal(data, &event); err != nil || event.ReusedBytes != 4_294_967_296 || event.ResumeToken != "token" {
		t.Fatalf("%+v %v", event, err)
	}
}

func resumeReport(t *testing.T, job *DownloadJob) Report {
	t.Helper()
	data, err := os.ReadFile(job.ReportPath)
	if err != nil {
		t.Fatal(err)
	}
	var report Report
	if err := json.Unmarshal(data, &report); err != nil {
		t.Fatal(err)
	}
	return report
}

func runResumedJob(t *testing.T, job *DownloadJob) {
	t.Helper()
	for i := 0; i < 100; i++ {
		done, err := job.Step(context.Background())
		if err != nil {
			t.Fatal(err)
		}
		if done {
			return
		}
		if job.Conflict() != nil {
			t.Fatalf("unexpected conflict: %+v", job.Conflict())
		}
	}
	t.Fatal("resumed job did not finish")
}

func TestResumeReusesVerifiedFilesOriginalFoldersAndReport(t *testing.T) {
	for _, layout := range []string{"direct", "folder", ""} {
		t.Run(layout, func(t *testing.T) {
			f := twoFileFixture()
			e := engine(f)
			var last Event
			e.Emit = func(event Event) {
				if event.Type == "progress" {
					last = event
				}
			}
			destination := t.TempDir()
			if err := os.Mkdir(filepath.Join(destination, "照片"), 0700); err != nil {
				t.Fatal(err)
			}
			job, output, err := e.PrepareDownload(context.Background(), Request{StorageID: 1, ObjectIDs: []uint32{1}, Destination: destination, DownloadLayout: layout, ReportDirectory: t.TempDir()}, "phone")
			if err != nil {
				t.Fatal(err)
			}
			// Exercise the exclusive-copy commit used on exFAT without touching
			// a user's disk; other cases retain the native atomic commit path.
			if layout == "folder" {
				job.copyCommit = true
			}
			if _, err = job.Step(context.Background()); err != nil {
				t.Fatal(err)
			}
			checkpoint, err := job.CancelForResume()
			if err != nil || checkpoint == nil {
				t.Fatalf("checkpoint=%v error=%v", checkpoint, err)
			}
			if _, err = job.files.Stat("."); err == nil {
				t.Fatal("cancel retained an open root")
			}
			resumed, err := checkpoint.Resume(context.Background(), e)
			if err != nil {
				t.Fatal(err)
			}
			defer resumed.Cancel()
			if done, err := resumed.Step(context.Background()); err != nil || done || !reflect.DeepEqual(f.read, []uint32{2}) {
				t.Fatalf("verification reread phone: %v %v %v", done, err, f.read)
			}
			// A second cancellation after verification must remain recoverable.
			checkpoint, err = resumed.CancelForResume()
			if err != nil || checkpoint == nil {
				t.Fatal(err)
			}
			resumed, err = checkpoint.Resume(context.Background(), e)
			if err != nil {
				t.Fatal(err)
			}
			runResumedJob(t, resumed)
			if resumed.Output != output || resumed.ReportPath != job.ReportPath || !reflect.DeepEqual(f.read, []uint32{2, 4}) {
				t.Fatalf("output=%s reads=%v", resumed.Output, f.read)
			}
			if last.Bytes != 11 || last.ReusedBytes != 5 || last.Completed != 2 {
				t.Fatalf("progress=%+v", last)
			}
			for _, item := range resumeReport(t, resumed).Items {
				if item.State != "completed" {
					t.Fatalf("unfinished: %+v", item)
				}
			}
			if layout == "direct" {
				if _, err := os.Stat(filepath.Join(output, "照片 (1)", "second.txt")); err != nil {
					t.Fatal("numbered folder was not reused", err)
				}
				if _, err := os.Stat(filepath.Join(output, "照片 (2)")); !os.IsNotExist(err) {
					t.Fatal("duplicated folder")
				}
			}
			if leftovers, _ := filepath.Glob(filepath.Join(resumed.files.Name(), ".ferry-download-*")); len(leftovers) != 0 {
				t.Fatal(leftovers)
			}
		})
	}
}

func TestResumeMissingOrChangedCompletedFileDoesNotTrustItsName(t *testing.T) {
	for _, change := range []string{"missing", "same-size-corrupt"} {
		t.Run(change, func(t *testing.T) {
			f := twoFileFixture()
			e := engine(f)
			job, output, err := e.PrepareDownload(context.Background(), Request{StorageID: 1, ObjectIDs: []uint32{1}, Destination: t.TempDir(), DownloadLayout: "direct", ReportDirectory: t.TempDir(), PromptConflicts: true}, "phone")
			if err != nil {
				t.Fatal(err)
			}
			if _, err = job.Step(context.Background()); err != nil {
				t.Fatal(err)
			}
			checkpoint, err := job.CancelForResume()
			if err != nil {
				t.Fatal(err)
			}
			path := filepath.Join(output, "照片", "旅行.txt")
			if change == "missing" {
				err = os.Remove(path)
			} else {
				err = os.WriteFile(path, []byte("xxxxx"), 0600)
			}
			if err != nil {
				t.Fatal(err)
			}
			resumed, err := checkpoint.Resume(context.Background(), e)
			if err != nil {
				t.Fatal(err)
			}
			defer resumed.Cancel()
			if _, err = resumed.Step(context.Background()); err != nil {
				t.Fatal(err)
			}
			wantReads := []uint32{2, 2}
			if change != "missing" {
				wantReads = []uint32{2}
			}
			if !reflect.DeepEqual(f.read, wantReads) {
				t.Fatalf("unexpected reads before conflict decision: %v", f.read)
			}
			if change != "missing" {
				conflict := resumed.Conflict()
				if conflict == nil {
					t.Fatal("changed existing file was not offered as a conflict")
				}
				data, _ := os.ReadFile(path)
				if string(data) != "xxxxx" {
					t.Fatal("overwrote without consent")
				}
				if err = resumed.ResolveConflict(&ConflictDecision{ID: conflict.ID, Choice: "keepBoth"}); err != nil {
					t.Fatal(err)
				}
			}
			runResumedJob(t, resumed)
			if !reflect.DeepEqual(f.read, []uint32{2, 2, 4}) {
				t.Fatalf("did not redownload changed file: %v", f.read)
			}
			if resumed.reusedBytes != 0 {
				t.Fatal("counted corrupt file as reused")
			}
			if change != "missing" {
				data, err := os.ReadFile(filepath.Join(output, "照片", "旅行 (1).txt"))
				if err != nil || string(data) != "hello" {
					t.Fatalf("%q %v", data, err)
				}
			}
		})
	}
}

func TestResumeRejectsChangedSourceBeforeReadingOrOverwriting(t *testing.T) {
	f := twoFileFixture()
	e := engine(f)
	job, output, err := e.PrepareDownload(context.Background(), Request{StorageID: 1, ObjectIDs: []uint32{1}, Destination: t.TempDir(), DownloadLayout: "direct", ReportDirectory: t.TempDir()}, "phone")
	if err != nil {
		t.Fatal(err)
	}
	if _, err = job.Step(context.Background()); err != nil {
		t.Fatal(err)
	}
	checkpoint, err := job.CancelForResume()
	if err != nil {
		t.Fatal(err)
	}
	entry := f.entries[2]
	entry.Modified++
	f.entries[2] = entry
	resumed, err := checkpoint.Resume(context.Background(), e)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = resumed.Step(context.Background()); err == nil {
		t.Fatal("accepted changed source")
	}
	if !reflect.DeepEqual(f.read, []uint32{2}) {
		t.Fatal(f.read)
	}
	data, _ := os.ReadFile(filepath.Join(output, "照片", "旅行.txt"))
	if string(data) != "hello" {
		t.Fatal("changed original backup")
	}
}

func TestResumeRejectsReplacementOutputDirectory(t *testing.T) {
	base := t.TempDir()
	destination := filepath.Join(base, "output")
	if err := os.Mkdir(destination, 0700); err != nil {
		t.Fatal(err)
	}
	f := twoFileFixture()
	e := engine(f)
	job, _, err := e.PrepareDownload(context.Background(), Request{StorageID: 1, ObjectIDs: []uint32{1}, Destination: destination, DownloadLayout: "direct", ReportDirectory: t.TempDir()}, "phone")
	if err != nil {
		t.Fatal(err)
	}
	if _, err = job.Step(context.Background()); err != nil {
		t.Fatal(err)
	}
	checkpoint, err := job.CancelForResume()
	if err != nil {
		t.Fatal(err)
	}
	if err = os.Rename(destination, destination+"-original"); err != nil {
		t.Fatal(err)
	}
	if err = os.Mkdir(destination, 0700); err != nil {
		t.Fatal(err)
	}
	if _, err = checkpoint.Resume(context.Background(), e); err == nil {
		t.Fatal("accepted another folder at the same path")
	}
	contents, _ := os.ReadDir(destination)
	if len(contents) != 0 || len(f.read) != 1 {
		t.Fatal("replacement directory was modified")
	}
}

func TestResumeKeepsArchivedNumberedPathWhenRestoringMissingPhoto(t *testing.T) {
	f := archiveFixture(t)
	e := engine(f)
	job, output, err := e.PrepareDownload(context.Background(), Request{StorageID: 1, ObjectIDs: []uint32{2, 3}, Destination: t.TempDir(), DownloadLayout: "direct", ReportDirectory: t.TempDir(), ArchivePhotosByMonth: true}, "phone")
	if err != nil {
		t.Fatal(err)
	}
	if err = os.MkdirAll(filepath.Join(output, "2022", "2月"), 0700); err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(filepath.Join(output, "2022", "2月", "same.jpg"), []byte("original"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err = job.Step(context.Background()); err != nil {
		t.Fatal(err)
	}
	saved := job.report.Items[0].Path
	checkpoint, err := job.CancelForResume()
	if err != nil {
		t.Fatal(err)
	}
	if err = os.Remove(filepath.Join(output, saved)); err != nil {
		t.Fatal(err)
	}
	resumed, err := checkpoint.Resume(context.Background(), e)
	if err != nil {
		t.Fatal(err)
	}
	runResumedJob(t, resumed)
	if resumed.report.Items[0].Path != saved {
		t.Fatalf("lost archive path %s -> %s", saved, resumed.report.Items[0].Path)
	}
	data, _ := os.ReadFile(filepath.Join(output, "2022", "2月", "same.jpg"))
	if string(data) != "original" {
		t.Fatal("changed preexisting photo")
	}
}

func TestResumePreservesExplicitSkipAndReasksCancelledConflict(t *testing.T) {
	for _, skip := range []bool{true, false} {
		f := twoFileFixture()
		e := engine(f)
		job, output, err := e.PrepareDownload(context.Background(), Request{StorageID: 1, ObjectIDs: []uint32{2, 4}, Destination: t.TempDir(), DownloadLayout: "direct", ReportDirectory: t.TempDir(), PromptConflicts: true}, "phone")
		if err != nil {
			t.Fatal(err)
		}
		if err = os.WriteFile(filepath.Join(output, "旅行.txt"), []byte("old"), 0600); err != nil {
			t.Fatal(err)
		}
		if _, err = job.Step(context.Background()); err != nil {
			t.Fatal(err)
		}
		oldID := job.Conflict().ID
		if skip {
			if err = job.ResolveConflict(&ConflictDecision{ID: oldID, Choice: "skip", ApplyToAll: true}); err != nil {
				t.Fatal(err)
			}
			if _, err = job.Step(context.Background()); err != nil {
				t.Fatal(err)
			}
		}
		checkpoint, err := job.CancelForResume()
		if err != nil {
			t.Fatal(err)
		}
		resumed, err := checkpoint.Resume(context.Background(), e)
		if err != nil {
			t.Fatal(err)
		}
		if _, err = resumed.Step(context.Background()); err != nil {
			t.Fatal(err)
		}
		if skip {
			if len(f.read) != 0 || resumed.skipped != 1 || resumed.reusedBytes != 5 || resumed.bytes != 5 {
				t.Fatal("reread an intentionally skipped file")
			}
		} else {
			if len(f.read) != 0 || resumed.Conflict() == nil || resumed.Conflict().ID == oldID {
				t.Fatal("did not reask pending conflict")
			}
			if err = resumed.ResolveConflict(&ConflictDecision{ID: oldID, Choice: "replace"}); err == nil {
				t.Fatal("accepted old decision")
			}
		}
		if err := resumed.Cancel(); err != nil {
			t.Fatal(err)
		}
	}
}
