package transfer

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func interactiveJob(t *testing.T, f *fakeDevice, destination string, ids []uint32) *DownloadJob {
	t.Helper()
	job, _, err := engine(f).PrepareDownload(context.Background(), Request{StorageID: 1, ObjectIDs: ids,
		Destination: destination, DownloadLayout: "direct", ReportDirectory: t.TempDir(), PromptConflicts: true}, "synthetic")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { job.Cancel() })
	return job
}

func decisionFor(job *DownloadJob, choice string, all bool) *ConflictDecision {
	return &ConflictDecision{ID: job.Conflict().ID, Choice: choice, ApplyToAll: all}
}

func TestInteractiveFileConflictChoicesAndTaskPolicy(t *testing.T) {
	for _, choice := range []string{"keepBoth", "skip", "replace"} {
		for _, all := range []bool{false, true} {
			t.Run(choice+map[bool]string{false: "/one", true: "/all"}[all], func(t *testing.T) {
				f := twoFileFixture()
				destination := t.TempDir()
				for _, name := range []string{"旅行.txt", "second.txt"} {
					if err := os.WriteFile(filepath.Join(destination, name), []byte("old"), 0600); err != nil {
						t.Fatal(err)
					}
				}
				job := interactiveJob(t, f, destination, []uint32{2, 4})
				prompts := 0
				for {
					done, err := job.Step(context.Background())
					if err != nil {
						t.Fatal(err)
					}
					if done {
						break
					}
					if job.Conflict() != nil {
						prompts++
						if job.pending.temp != "" || job.stage != "" && choice == "skip" {
							t.Fatal("conflict staged phone content before asking")
						}
						conflict := job.Conflict()
						if conflict.Kind != "file" || !conflict.CanReplace || conflict.ExistingSize != 3 || conflict.TargetPath == "" {
							t.Fatalf("%+v", conflict)
						}
						reads := len(f.read)
						if _, err := job.Step(context.Background()); err != nil || len(f.read) != reads {
							t.Fatal("waiting repeated a device read")
						}
						if err := job.ResolveConflict(decisionFor(job, choice, all)); err != nil {
							t.Fatal(err)
						}
					}
				}
				wantPrompts := 2
				if all {
					wantPrompts = 1
				}
				wantReads := 2
				if choice == "skip" {
					wantReads = 0
				}
				if prompts != wantPrompts || len(f.read) != wantReads {
					t.Fatalf("prompts=%d reads=%v", prompts, f.read)
				}
				for _, id := range []uint32{2, 4} {
					name := f.entries[id].Name
					want := []byte("old")
					if choice == "replace" {
						want = f.data[id]
					}
					if data, err := os.ReadFile(filepath.Join(destination, name)); err != nil || !bytes.Equal(data, want) {
						t.Fatalf("%s: %q %v", name, data, err)
					}
					if choice == "keepBoth" {
						if data, err := os.ReadFile(filepath.Join(destination, numberedPath(name, 1, false))); err != nil || !bytes.Equal(data, f.data[id]) {
							t.Fatalf("numbered file: %q %v", data, err)
						}
					}
				}
				for _, item := range job.report.Items {
					wantState := "completed"
					if choice == "skip" {
						wantState = "skipped"
					}
					if item.State != wantState || item.ConflictAction != choice {
						t.Fatalf("%+v", item)
					}
				}
				if choice == "skip" && job.skipped != 2 {
					t.Fatalf("skipped=%d", job.skipped)
				}
				if choice == "skip" && (job.bytes != 11 || job.reusedBytes != 11 || job.stage != "") {
					t.Fatalf("unread skips inflated transfer or staged content: bytes=%d reused=%d stage=%q", job.bytes, job.reusedBytes, job.stage)
				}
				// The next task starts with no inherited apply-to-all policy.
				next := interactiveJob(t, f, destination, []uint32{2})
				if _, err := next.Step(context.Background()); err != nil || next.Conflict() == nil {
					t.Fatalf("new task inherited a decision: %v", err)
				}
			})
		}
	}
}

func TestConflictStaleIDsAndChangedTargetsNeverReplaceSilently(t *testing.T) {
	destination := t.TempDir()
	target := filepath.Join(destination, "旅行.txt")
	if err := os.WriteFile(target, []byte("old"), 0600); err != nil {
		t.Fatal(err)
	}
	f := fixture()
	job := interactiveJob(t, f, destination, []uint32{2})
	if _, err := job.Step(context.Background()); err != nil {
		t.Fatal(err)
	}
	id := job.Conflict().ID
	if err := job.ResolveConflict(&ConflictDecision{ID: "stale", Choice: "replace", ApplyToAll: true}); err == nil {
		t.Fatal("stale decision accepted")
	}
	if job.Conflict().ID != id || job.filePolicy != "" {
		t.Fatal("stale decision changed state")
	}
	if err := os.WriteFile(target, []byte("changed while waiting"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := job.ResolveConflict(decisionFor(job, "replace", true)); err != nil {
		t.Fatal(err)
	}
	if _, err := job.Step(context.Background()); err != nil {
		t.Fatal(err)
	}
	if job.Conflict() == nil || job.Conflict().ID == id || job.filePolicy != "" {
		t.Fatal("changed target was not re-prompted")
	}
	if data, err := os.ReadFile(target); err != nil || string(data) != "changed while waiting" {
		t.Fatalf("changed target replaced: %q %v", data, err)
	}
	if err := job.ResolveConflict(decisionFor(job, "keepBoth", false)); err != nil {
		t.Fatal(err)
	}
	if done, err := job.Step(context.Background()); err != nil || !done || len(f.read) != 1 {
		t.Fatalf("done=%v reads=%v err=%v", done, f.read, err)
	}
}

func TestSkipPolicyStillDownloadsNonConflictingFiles(t *testing.T) {
	for _, copyCommit := range []bool{false, true} {
		f := twoFileFixture()
		destination := t.TempDir()
		if err := os.WriteFile(filepath.Join(destination, "旅行.txt"), []byte("old"), 0600); err != nil {
			t.Fatal(err)
		}
		job := interactiveJob(t, f, destination, []uint32{2, 4})
		job.copyCommit = copyCommit
		if _, err := job.Step(context.Background()); err != nil || job.Conflict() == nil || len(f.read) != 0 {
			t.Fatalf("preflight: conflict=%+v reads=%v err=%v", job.Conflict(), f.read, err)
		}
		if err := job.ResolveConflict(decisionFor(job, "skip", true)); err != nil {
			t.Fatal(err)
		}
		runResumedJob(t, job)
		if len(f.read) != 1 || f.read[0] != 4 || job.bytes != 11 || job.reusedBytes != 5 || job.skipped != 1 {
			t.Fatalf("reads=%v bytes=%d reused=%d skipped=%d", f.read, job.bytes, job.reusedBytes, job.skipped)
		}
		if data, err := os.ReadFile(filepath.Join(destination, "second.txt")); err != nil || !bytes.Equal(data, f.data[4]) {
			t.Fatalf("non-conflicting file: %q %v", data, err)
		}
		if item := job.report.Items[0]; item.State != "skipped" || item.SHA256 != "" {
			t.Fatalf("unread skip report: %+v", item)
		}
	}
}

func TestConflictAppearingDuringReadCanSkipWithoutRereading(t *testing.T) {
	f := fixture()
	destination := t.TempDir()
	target := filepath.Join(destination, "旅行.txt")
	f.afterRead = func() {
		if err := os.WriteFile(target, []byte("appeared during read"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	job := interactiveJob(t, f, destination, []uint32{2})
	if _, err := job.Step(context.Background()); err != nil || job.Conflict() == nil || len(f.read) != 1 {
		t.Fatalf("late conflict: reads=%v err=%v", f.read, err)
	}
	temp := filepath.Join(destination, job.pending.temp)
	if _, err := os.Stat(temp); err != nil {
		t.Fatal(err)
	}
	if err := job.ResolveConflict(decisionFor(job, "skip", false)); err != nil {
		t.Fatal(err)
	}
	if done, err := job.Step(context.Background()); err != nil || !done || len(f.read) != 1 {
		t.Fatalf("done=%v reads=%v err=%v", done, f.read, err)
	}
	if _, err := os.Stat(temp); !os.IsNotExist(err) {
		t.Fatalf("staged file survived skip: %v", err)
	}
	if data, err := os.ReadFile(target); err != nil || string(data) != "appeared during read" {
		t.Fatalf("target changed: %q %v", data, err)
	}
	if job.reusedBytes != 0 || job.bytes != 5 || job.report.Items[0].SHA256 == "" {
		t.Fatal("already-read skip lost actual transfer accounting")
	}
}

func TestPreflightReplacementRechecksTargetAfterRead(t *testing.T) {
	f := fixture()
	destination := t.TempDir()
	target := filepath.Join(destination, "旅行.txt")
	if err := os.WriteFile(target, []byte("old"), 0600); err != nil {
		t.Fatal(err)
	}
	job := interactiveJob(t, f, destination, []uint32{2})
	if _, err := job.Step(context.Background()); err != nil || job.Conflict() == nil {
		t.Fatalf("%v", err)
	}
	id := job.Conflict().ID
	if err := job.ResolveConflict(decisionFor(job, "replace", true)); err != nil {
		t.Fatal(err)
	}
	f.afterRead = func() {
		if err := os.WriteFile(target, []byte("changed during read"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	if done, err := job.Step(context.Background()); err != nil || done || job.Conflict() == nil || job.Conflict().ID == id {
		t.Fatalf("changed target was not re-prompted: done=%v conflict=%+v err=%v", done, job.Conflict(), err)
	}
	if data, err := os.ReadFile(target); err != nil || string(data) != "changed during read" {
		t.Fatalf("changed target overwritten: %q %v", data, err)
	}
	if err := job.ResolveConflict(decisionFor(job, "replace", false)); err != nil {
		t.Fatal(err)
	}
	if done, err := job.Step(context.Background()); err != nil || !done || len(f.read) != 1 {
		t.Fatalf("replacement reread phone: done=%v reads=%v err=%v", done, f.read, err)
	}
	if data, err := os.ReadFile(target); err != nil || !bytes.Equal(data, f.data[2]) {
		t.Fatalf("replacement: %q %v", data, err)
	}
}

func TestArchivedSkipReadsDateOnceAndResumeUsesKnownTarget(t *testing.T) {
	f := archiveFixture(t)
	e := engine(f)
	destination := t.TempDir()
	directory := filepath.Join(destination, "2022", "02月")
	if err := os.MkdirAll(directory, 0700); err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(directory, "same.jpg")
	if err := os.WriteFile(target, []byte("old"), 0600); err != nil {
		t.Fatal(err)
	}
	job, _, err := e.PrepareDownload(context.Background(), Request{StorageID: 1, ObjectIDs: []uint32{2},
		Destination: destination, DownloadLayout: "direct", ReportDirectory: t.TempDir(),
		ArchivePhotosByMonth: true, PromptConflicts: true}, "phone")
	if err != nil {
		t.Fatal(err)
	}
	defer job.Cancel()
	if _, err = job.Step(context.Background()); err != nil || job.Conflict() == nil || len(f.read) != 1 {
		t.Fatalf("archive conflict: reads=%v err=%v", f.read, err)
	}
	checkpoint, err := job.CancelForResume()
	if err != nil || checkpoint == nil {
		t.Fatalf("checkpoint=%v err=%v", checkpoint, err)
	}
	resumed, err := checkpoint.Resume(context.Background(), e)
	if err != nil {
		t.Fatal(err)
	}
	defer resumed.Cancel()
	if _, err = resumed.Step(context.Background()); err != nil || resumed.Conflict() == nil || len(f.read) != 1 {
		t.Fatalf("known archive path reread phone: reads=%v err=%v", f.read, err)
	}
	if err := resumed.ResolveConflict(decisionFor(resumed, "skip", false)); err != nil {
		t.Fatal(err)
	}
	if done, err := resumed.Step(context.Background()); err != nil || !done || len(f.read) != 1 {
		t.Fatalf("done=%v reads=%v err=%v", done, f.read, err)
	}
	if resumed.reusedBytes != f.entries[2].Size || resumed.report.Items[0].SHA256 != "" {
		t.Fatal("resumed skip counted a new device read")
	}
	if data, err := os.ReadFile(target); err != nil || string(data) != "old" {
		t.Fatalf("archive target changed: %q %v", data, err)
	}
}

func TestReplacementNeverAcceptsDirectoriesOrSymlinks(t *testing.T) {
	for _, kind := range []string{"directory", "symlink"} {
		t.Run(kind, func(t *testing.T) {
			destination, outside := t.TempDir(), t.TempDir()
			target := filepath.Join(destination, "旅行.txt")
			if kind == "directory" {
				if err := os.Mkdir(target, 0700); err != nil {
					t.Fatal(err)
				}
			} else {
				if err := os.WriteFile(filepath.Join(outside, "old"), []byte("outside"), 0600); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink(filepath.Join(outside, "old"), target); err != nil {
					t.Fatal(err)
				}
			}
			job := interactiveJob(t, fixture(), destination, []uint32{2})
			if _, err := job.Step(context.Background()); err != nil {
				t.Fatal(err)
			}
			if job.Conflict().CanReplace {
				t.Fatal("non-regular replacement offered")
			}
			if err := job.ResolveConflict(decisionFor(job, "replace", true)); err == nil {
				t.Fatal("replaced non-regular entry")
			}
			if err := job.ResolveConflict(decisionFor(job, "keepBoth", false)); err != nil {
				t.Fatal(err)
			}
			if done, err := job.Step(context.Background()); err != nil || !done {
				t.Fatalf("%v %v", done, err)
			}
			info, err := os.Lstat(target)
			if err != nil {
				t.Fatal(err)
			}
			if kind == "directory" && !info.IsDir() || kind == "symlink" && info.Mode()&os.ModeSymlink == 0 {
				t.Fatal("existing entry changed")
			}
		})
	}
}

func TestWaitingCancellationAndReadFailureKeepOriginalFiles(t *testing.T) {
	for _, failure := range []string{"cancel", "read"} {
		t.Run(failure, func(t *testing.T) {
			destination := t.TempDir()
			target := filepath.Join(destination, "旅行.txt")
			if err := os.WriteFile(target, []byte("old"), 0600); err != nil {
				t.Fatal(err)
			}
			f := fixture()
			if failure == "read" {
				f.readErr = errors.New("read failure")
			}
			job := interactiveJob(t, f, destination, []uint32{2})
			_, err := job.Step(context.Background())
			if failure == "read" {
				if err != nil || job.Conflict() == nil {
					t.Fatalf("expected preflight conflict: %v", err)
				}
				if err := job.ResolveConflict(decisionFor(job, "replace", false)); err != nil {
					t.Fatal(err)
				}
				if _, err := job.Step(context.Background()); err == nil {
					t.Fatal("expected read error")
				}
			}
			if failure == "cancel" {
				if err != nil || job.Conflict() == nil {
					t.Fatalf("%v", err)
				}
				if err := job.Cancel(); err != nil {
					t.Fatal(err)
				}
				if job.Conflict() != nil || job.report.Items[0].State != "cancelled" {
					t.Fatal("waiting state survived cancellation")
				}
			}
			if data, err := os.ReadFile(target); err != nil || string(data) != "old" {
				t.Fatalf("original changed: %q %v", data, err)
			}
			if matches, _ := filepath.Glob(filepath.Join(destination, ".ferry-*")); len(matches) != 0 {
				t.Fatalf("temporary files remain: %v", matches)
			}
		})
	}
}

func TestSkippingPhotoNeverChangesExistingCreationDate(t *testing.T) {
	destination := t.TempDir()
	target := filepath.Join(destination, "photo.jpg")
	if err := os.WriteFile(target, []byte("old"), 0600); err != nil {
		t.Fatal(err)
	}
	before := birthTime(t, target)
	data := photoJPEG(t, "2022:02:28 19:31:40", "+08:00", "")
	f := fixture()
	f.entries[2] = Entry{ID: 2, StorageID: 1, Name: "photo.jpg", Size: int64(len(data))}
	f.data[2] = data
	job, _, err := engine(f).PrepareDownload(context.Background(), Request{StorageID: 1, ObjectIDs: []uint32{2}, Destination: destination,
		DownloadLayout: "direct", ReportDirectory: t.TempDir(), PromptConflicts: true, UsePhotoCreationDate: true}, "synthetic")
	if err != nil {
		t.Fatal(err)
	}
	defer job.Cancel()
	if _, err := job.Step(context.Background()); err != nil {
		t.Fatal(err)
	}
	if err := job.ResolveConflict(decisionFor(job, "skip", false)); err != nil {
		t.Fatal(err)
	}
	if done, err := job.Step(context.Background()); err != nil || !done {
		t.Fatalf("%v %v", done, err)
	}
	if data, err := os.ReadFile(target); err != nil || string(data) != "old" || !birthTime(t, target).Equal(before) {
		t.Fatalf("skipped target changed: %q %v", data, err)
	}
	if job.report.Items[0].PhotoCreationTime != 0 {
		t.Fatal("reported a skipped file as having its creation date changed")
	}
	if len(f.read) != 0 || job.report.Items[0].SHA256 != "" {
		t.Fatal("skipping a photo read its contents or reported a content hash")
	}
}

func TestMonthAliasesAndAmbiguousChoice(t *testing.T) {
	for _, name := range []string{"02月", "2月", "02", "2"} {
		t.Run(name, func(t *testing.T) {
			destination := t.TempDir()
			if err := os.MkdirAll(filepath.Join(destination, "2022", name), 0700); err != nil {
				t.Fatal(err)
			}
			f := archiveFixture(t)
			req := Request{StorageID: 1, ObjectIDs: []uint32{2}, Destination: destination, DownloadLayout: "direct", ReportDirectory: t.TempDir(), ArchivePhotosByMonth: true, PromptConflicts: true}
			job, _, err := engine(f).PrepareDownload(context.Background(), req, "synthetic")
			if err != nil {
				t.Fatal(err)
			}
			defer job.Cancel()
			if done, err := job.Step(context.Background()); err != nil || !done {
				t.Fatalf("%v %v", done, err)
			}
			if job.report.Items[0].Path != filepath.Join("2022", name, "same.jpg") {
				t.Fatal(job.report.Items[0])
			}
		})
	}
	destination := t.TempDir()
	for _, name := range []string{"02月", "2"} {
		if err := os.MkdirAll(filepath.Join(destination, "2022", name), 0700); err != nil {
			t.Fatal(err)
		}
	}
	f := archiveFixture(t)
	job, _, err := engine(f).PrepareDownload(context.Background(), Request{StorageID: 1, ObjectIDs: []uint32{2, 8}, Destination: destination, DownloadLayout: "direct", ReportDirectory: t.TempDir(), ArchivePhotosByMonth: true, PromptConflicts: true}, "synthetic")
	if err != nil {
		t.Fatal(err)
	}
	defer job.Cancel()
	if _, err := job.Step(context.Background()); err != nil {
		t.Fatal(err)
	}
	if conflict := job.Conflict(); conflict == nil || conflict.Kind != "monthDirectory" || len(conflict.Candidates) != 2 {
		t.Fatalf("%+v", conflict)
	}
	if err := job.ResolveConflict(&ConflictDecision{ID: job.Conflict().ID, Choice: "directory", Directory: "../outside"}); err == nil {
		t.Fatal("arbitrary directory accepted")
	}
	if err := job.ResolveConflict(&ConflictDecision{ID: job.Conflict().ID, Choice: "directory", Directory: "2022/2"}); err != nil {
		t.Fatal(err)
	}
	if done, err := job.Step(context.Background()); err != nil || done {
		t.Fatalf("%v %v", done, err)
	}
	if _, err := job.Step(context.Background()); err != nil {
		t.Fatal(err)
	}
	if job.Conflict() == nil || job.Conflict().Kind != "file" {
		t.Fatal("month choice was not reused")
	}
	if err := job.ResolveConflict(decisionFor(job, "keepBoth", false)); err != nil {
		t.Fatal(err)
	}
	if done, err := job.Step(context.Background()); err != nil || !done || len(f.read) != 2 {
		t.Fatalf("%v %v reads=%v", done, err, f.read)
	}
	for _, item := range job.report.Items {
		if !strings.HasPrefix(item.Path, "2022/2/") {
			t.Fatal(item)
		}
	}
	if entries, err := os.ReadDir(filepath.Join(destination, "2022/02月")); err != nil || len(entries) != 0 {
		t.Fatalf("other directory changed: %v %v", entries, err)
	}
}

func TestExternalVolumeInteractiveReplacement(t *testing.T) {
	volume := os.Getenv("FERRY_TEST_VOLUME")
	if volume == "" {
		t.Skip("set FERRY_TEST_VOLUME to test external replacement")
	}
	destination, err := os.MkdirTemp(volume, ".ferry-conflict-test-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := os.RemoveAll(destination); err != nil {
			t.Errorf("cleanup: %v", err)
		}
	})
	target := filepath.Join(destination, "旅行.txt")
	if err := os.WriteFile(target, []byte("old"), 0600); err != nil {
		t.Fatal(err)
	}
	f := fixture()
	job := interactiveJob(t, f, destination, []uint32{2})
	if _, err := job.Step(context.Background()); err != nil || job.Conflict() == nil {
		t.Fatalf("%v", err)
	}
	if data, err := os.ReadFile(target); err != nil || string(data) != "old" {
		t.Fatal("changed target before confirmation")
	}
	if err := job.ResolveConflict(decisionFor(job, "replace", false)); err != nil {
		t.Fatal(err)
	}
	if done, err := job.Step(context.Background()); err != nil || !done {
		t.Fatalf("%v %v", done, err)
	}
	if data, err := os.ReadFile(target); err != nil || !bytes.Equal(data, f.data[2]) {
		t.Fatalf("replacement=%q error=%v", data, err)
	}
}
