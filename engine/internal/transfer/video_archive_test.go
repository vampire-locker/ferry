package transfer

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

func videoArchiveFixture(t *testing.T) *fakeDevice {
	t.Helper()
	photo := photoJPEG(t, "2022:02:28 23:40:00", "-05:00", "")
	video := videoAtom("moov", videoMovie(time.Date(2026, 3, 1, 0, 0, 0, 0, time.UTC), 0), videoDateMetadata("2022-02-28T23:55:00-0500", false))
	modified := time.Date(2027, 12, 5, 12, 0, 0, 0, time.Local).Unix()
	f := &fakeDevice{entries: map[uint32]Entry{
		1: {ID: 1, StorageID: 1, Name: "Camera", IsDirectory: true},
		2: {ID: 2, StorageID: 1, Name: "photo.jpg", Modified: modified},
		3: {ID: 3, StorageID: 1, Name: "clip.mp4", Modified: modified},
		4: {ID: 4, StorageID: 1, Name: "fallback.mkv", Modified: modified},
		5: {ID: 5, StorageID: 1, Name: "unknown.webm"},
		6: {ID: 6, StorageID: 1, Name: "broken.mp4", Modified: modified},
		7: {ID: 7, StorageID: 1, Name: "note.txt", Modified: modified},
		8: {ID: 8, StorageID: 1, Name: "Empty", IsDirectory: true},
	}, children: map[uint32][]uint32{1: {2, 3, 4, 5, 6, 7, 8}}, data: map[uint32][]byte{2: photo, 3: video, 4: []byte("unsupported video"), 5: []byte("unknown video"), 6: []byte("invalid"), 7: []byte("note")}}
	for id, data := range f.data {
		entry := f.entries[id]
		entry.Size = int64(len(data))
		f.entries[id] = entry
	}
	return f
}

func TestVideoArchiveRequestProtocolAndLegacyDefault(t *testing.T) {
	for _, payload := range []string{`{"operation":"download"}`, `{"operation":"download","archiveVideosByMonth":false}`, `{"operation":"download","archiveVideosByMonth":true}`} {
		var req Request
		if err := json.Unmarshal([]byte(payload), &req); err != nil {
			t.Fatal(err)
		}
		want := payload == `{"operation":"download","archiveVideosByMonth":true}`
		if req.ArchiveVideosByMonth != want || req.ArchivePhotosByMonth || req.UsePhotoCreationDate {
			t.Fatalf("%+v", req)
		}
	}
}

func TestVideoAndPhotoArchiveOptionsAreIndependentAndPreserveData(t *testing.T) {
	for _, photos := range []bool{false, true} {
		for _, videos := range []bool{false, true} {
			f := videoArchiveFixture(t)
			e := engine(f)
			job, output, err := e.PrepareDownload(context.Background(), Request{StorageID: 1, ObjectIDs: []uint32{1}, Destination: t.TempDir(), DownloadLayout: "direct", ReportDirectory: t.TempDir(), ArchivePhotosByMonth: photos, ArchiveVideosByMonth: videos, UsePhotoCreationDate: true}, "phone")
			if err != nil {
				t.Fatal(err)
			}
			if videos && !photos {
				job.copyCommit = true
			}
			if err = os.MkdirAll(filepath.Join(output, "2022", "2月"), 0700); err != nil {
				t.Fatal(err)
			}
			old := filepath.Join(output, "2022", "2月", "clip.mp4")
			if err = os.WriteFile(old, []byte("existing"), 0600); err != nil {
				t.Fatal(err)
			}
			runResumedJob(t, job)
			if len(f.read) != 6 {
				t.Fatalf("extra device reads: %v", f.read)
			}
			for _, item := range resumeReport(t, job).Items {
				if item.Entry.IsDirectory {
					continue
				}
				data, err := os.ReadFile(filepath.Join(output, item.Path))
				if err != nil || !bytes.Equal(data, f.data[item.Entry.ID]) {
					t.Fatalf("changed data id=%d %v", item.Entry.ID, err)
				}
				hash := sha256.Sum256(data)
				if item.SHA256 != hex.EncodeToString(hash[:]) {
					t.Fatal("hash changed")
				}
				archive := item.Entry.ID == 2 && photos || item.Entry.ID >= 3 && item.Entry.ID <= 6 && videos
				if archive != (item.SourcePath != "") {
					t.Fatalf("wrong media archived: %+v", item)
				}
				if !archive && item.Path != filepath.Join("Camera", item.Entry.Name) {
					t.Fatalf("changed unarchived layout: %+v", item)
				}
				if videos && item.Entry.ID == 3 && (item.Path != filepath.Join("2022", "2月", "clip (1).mp4") || item.ArchiveDateSource != "video_metadata") {
					t.Fatalf("video date/alias lost: %+v", item)
				}
				if photos && item.Entry.ID == 2 && item.Path != filepath.Join("2022", "2月", "photo.jpg") {
					t.Fatalf("photo and video did not share month: %+v", item)
				}
				if videos && item.Entry.ID == 4 && (item.ArchiveDateSource != "modified" || item.Path != filepath.Join("2027", "12月", "fallback.mkv")) {
					t.Fatalf("fallback=%+v", item)
				}
				if videos && item.Entry.ID == 5 && (item.ArchiveDateSource != "unknown" || item.Path != filepath.Join(unknownDateDirectory, "unknown.webm")) {
					t.Fatalf("unknown=%+v", item)
				}
				if videos && item.Entry.ID == 6 && (item.ArchiveDateSource != "modified" || item.ArchiveDateWarning == "") {
					t.Fatalf("broken=%+v", item)
				}
				if MediaKind(item.Entry) == "video" && (item.PhotoCreationTime != 0 || item.CreationDateWarning != "") {
					t.Fatal("photo creation option affected video")
				}
				info, err := os.Stat(filepath.Join(output, item.Path))
				if err != nil {
					t.Fatal(err)
				}
				if item.Entry.Modified > 0 && info.ModTime().Unix() != item.Entry.Modified {
					t.Fatal("modification time changed")
				}
			}
			if _, err = os.Stat(filepath.Join(output, "Camera", "Empty")); err != nil {
				t.Fatal("lost empty directory", err)
			}
			data, _ := os.ReadFile(old)
			if string(data) != "existing" {
				t.Fatal("overwrote existing video")
			}
			if _, err = os.Stat(filepath.Join(output, "2022", "02月")); !os.IsNotExist(err) {
				t.Fatal("ignored existing month alias")
			}
		}
	}
}

func TestVideoOnlyArchiveRemovesMediaOnlyFoldersAndKeepsOtherTypes(t *testing.T) {
	for _, tc := range []struct {
		photos, videos bool
		want           []uint32
	}{
		{false, false, []uint32{1, 2, 10, 3, 20, 7}},
		{true, false, []uint32{2, 10, 3, 20, 7}},
		{false, true, []uint32{1, 2, 3, 20, 7}},
		{true, true, []uint32{2, 3, 20, 7}},
	} {
		items := []Item{{Entry: Entry{ID: 1, IsDirectory: true}, Path: "Photos"}, {Entry: Entry{ID: 2, Name: "one.jpg"}, Path: "Photos/one.jpg"}, {Entry: Entry{ID: 10, IsDirectory: true}, Path: "Videos"}, {Entry: Entry{ID: 3, Name: "one.mp4"}, Path: "Videos/one.mp4"}, {Entry: Entry{ID: 20, IsDirectory: true}, Path: "Other"}, {Entry: Entry{ID: 7, Name: "note.txt"}, Path: "Other/note.txt"}}
		var got []uint32
		for _, item := range monthArchivePlan(items, tc.photos, tc.videos) {
			got = append(got, item.Entry.ID)
		}
		if !reflect.DeepEqual(got, tc.want) {
			t.Fatalf("photos=%v videos=%v got=%v want=%v", tc.photos, tc.videos, got, tc.want)
		}
	}
}

func TestVideoArchiveMonthAndFileConflictsDoNotReread(t *testing.T) {
	f := videoArchiveFixture(t)
	e := engine(f)
	job, output, err := e.PrepareDownload(context.Background(), Request{StorageID: 1, ObjectIDs: []uint32{3}, Destination: t.TempDir(), DownloadLayout: "direct", ReportDirectory: t.TempDir(), ArchiveVideosByMonth: true, PromptConflicts: true}, "phone")
	if err != nil {
		t.Fatal(err)
	}
	defer job.Cancel()
	for _, month := range []string{"02月", "2月"} {
		if err = os.MkdirAll(filepath.Join(output, "2022", month), 0700); err != nil {
			t.Fatal(err)
		}
	}
	old := filepath.Join(output, "2022", "2月", "clip.mp4")
	if err = os.WriteFile(old, []byte("old"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err = job.Step(context.Background()); err != nil {
		t.Fatal(err)
	}
	if job.Conflict() == nil || job.Conflict().Kind != "monthDirectory" {
		t.Fatal("missing month choice")
	}
	if err = job.ResolveConflict(&ConflictDecision{ID: job.Conflict().ID, Choice: "directory", Directory: filepath.Join("2022", "2月")}); err != nil {
		t.Fatal(err)
	}
	if _, err = job.Step(context.Background()); err != nil {
		t.Fatal(err)
	}
	if job.Conflict() == nil || job.Conflict().Kind != "file" {
		t.Fatal("missing file choice")
	}
	if err = job.ResolveConflict(&ConflictDecision{ID: job.Conflict().ID, Choice: "keepBoth"}); err != nil {
		t.Fatal(err)
	}
	runResumedJob(t, job)
	if !reflect.DeepEqual(f.read, []uint32{3}) {
		t.Fatalf("reread video: %v", f.read)
	}
	if job.report.Items[0].Path != filepath.Join("2022", "2月", "clip (1).mp4") {
		t.Fatal(job.report.Items[0])
	}
	data, _ := os.ReadFile(old)
	if string(data) != "old" {
		t.Fatal("replaced original")
	}
}

func TestVideoArchiveCancellationResumeKeepsOptionsAndVerifiedPaths(t *testing.T) {
	f := videoArchiveFixture(t)
	e := engine(f)
	job, output, err := e.PrepareDownload(context.Background(), Request{StorageID: 1, ObjectIDs: []uint32{3, 4}, Destination: t.TempDir(), DownloadLayout: "folder", ReportDirectory: t.TempDir(), ArchiveVideosByMonth: true}, "phone")
	if err != nil {
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
	resumed, err := checkpoint.Resume(context.Background(), e)
	if err != nil {
		t.Fatal(err)
	}
	runResumedJob(t, resumed)
	if !resumed.archiveVideosByMonth || resumed.archivePhotosByMonth || resumed.Output != output || resumed.ReportPath != job.ReportPath || resumed.report.Items[0].Path != saved {
		t.Fatal("lost original video settings or paths")
	}
	if !reflect.DeepEqual(f.read, []uint32{3, 4}) {
		t.Fatalf("reread completed video: %v", f.read)
	}
	if resumed.reusedBytes != f.entries[3].Size {
		t.Fatal("reused video counted as new transfer")
	}
}
