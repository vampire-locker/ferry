package transfer

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestMonthArchiveRequestProtocol(t *testing.T) {
	for _, tc := range []struct {
		payload string
		enabled bool
	}{
		{`{"operation":"download"}`, false},
		{`{"operation":"download","archivePhotosByMonth":false}`, false},
		{`{"operation":"download","archivePhotosByMonth":true}`, true},
	} {
		var request Request
		if err := json.Unmarshal([]byte(tc.payload), &request); err != nil || request.ArchivePhotosByMonth != tc.enabled {
			t.Fatalf("request=%+v error=%v", request, err)
		}
	}
}

func archiveFixture(t *testing.T) *fakeDevice {
	t.Helper()
	exif := photoJPEG(t, "2022:02:28 23:40:00", "-05:00", "")
	nextYear := photoJPEG(t, "2023:01:01 00:01:00", "+08:00", "")
	missing := photoJPEG(t, "", "", "")
	modified := time.Date(2024, 3, 1, 0, 30, 0, 0, time.Local).Unix()
	return &fakeDevice{
		entries: map[uint32]Entry{
			1: {ID: 1, StorageID: 1, Name: "Camera", IsDirectory: true},
			2: {ID: 2, StorageID: 1, Name: "same.jpg", Size: int64(len(exif)), Modified: modified},
			3: {ID: 3, StorageID: 1, Name: "fallback.jpg", Size: int64(len(missing)), Modified: modified},
			4: {ID: 4, StorageID: 1, Name: "unknown.jpg", Size: int64(len(missing))},
			5: {ID: 5, StorageID: 1, Name: "new-year.jpg", Size: int64(len(nextYear)), Modified: modified},
			6: {ID: 6, StorageID: 1, Name: "note.txt", Size: 4, Modified: modified},
			7: {ID: 7, StorageID: 1, Name: "Trip", IsDirectory: true},
			8: {ID: 8, StorageID: 1, Name: "same.jpg", Size: int64(len(exif)), Modified: modified},
			9: {ID: 9, StorageID: 1, Name: "Empty", IsDirectory: true},
		},
		children: map[uint32][]uint32{1: {2, 3, 4, 5, 6, 7, 9}, 7: {8}},
		data:     map[uint32][]byte{2: exif, 3: missing, 4: missing, 5: nextYear, 6: []byte("note"), 8: exif},
	}
}

func TestMonthArchiveDateAndUnknown(t *testing.T) {
	// Travel photos belong to their recorded capture month, not the Mac's
	// timezone-converted month or the newer modification month.
	capture := time.Date(2022, 2, 28, 23, 40, 0, 0, time.FixedZone("UTC-5", -5*3600))
	modified := time.Date(2024, 3, 1, 0, 30, 0, 0, time.Local).Unix()
	date, source := monthArchiveDate(capture, modified)
	if source != "exif" || date.Month() != time.February || date.Year() != 2022 {
		t.Fatalf("%v %s", date, source)
	}
	date, source = monthArchiveDate(time.Time{}, modified)
	if source != "modified" || date.Month() != time.March || date.Year() != 2024 {
		t.Fatalf("%v %s", date, source)
	}
	for _, value := range []int64{0, -1, 1 << 62} {
		date, source = monthArchiveDate(time.Time{}, value)
		if source != "unknown" || !date.IsZero() {
			t.Fatalf("accepted invalid modification time %d: %v %s", value, date, source)
		}
	}
}

func TestMonthArchiveReusesFoldersKeepsBothAndPreservesData(t *testing.T) {
	for _, layout := range []string{"direct", "folder"} {
		for _, copyCommit := range []bool{false, true} {
			for _, creationDate := range []bool{false, true} {
				t.Run(layout+map[bool]string{false: "/atomic", true: "/copy"}[copyCommit]+map[bool]string{false: "/creation-off", true: "/creation-on"}[creationDate], func(t *testing.T) {
					testMonthArchive(t, t.TempDir(), t.TempDir(), layout, copyCommit, creationDate)
				})
			}
		}
	}
}

func testMonthArchive(t *testing.T, destination, reports, layout string, forceCopy, creationDate bool) {
	t.Helper()
	f := archiveFixture(t)
	job, output, err := engine(f).PrepareDownload(context.Background(), Request{
		StorageID: 1, ObjectIDs: []uint32{1}, Destination: destination, DownloadLayout: layout,
		ReportDirectory: reports, ArchivePhotosByMonth: true, UsePhotoCreationDate: creationDate,
	}, "synthetic")
	if err != nil {
		t.Fatal(err)
	}
	defer job.Cancel()
	if forceCopy {
		job.copyCommit = true
	}
	for _, directory := range []string{"2022/02月", "日期未知", "Camera"} {
		if err := os.MkdirAll(filepath.Join(output, directory), 0700); err != nil {
			t.Fatal(err)
		}
	}
	existing := map[string]string{"2022/02月/same.jpg": "old photo", "日期未知/old.txt": "old unknown", "Camera/old.txt": "old folder"}
	for name, data := range existing {
		if err := os.WriteFile(filepath.Join(output, name), []byte(data), 0600); err != nil {
			t.Fatal(err)
		}
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
	reportBytes, err := os.ReadFile(job.ReportPath)
	if err != nil {
		t.Fatal(err)
	}
	var report Report
	if err := json.Unmarshal(reportBytes, &report); err != nil {
		t.Fatal(err)
	}
	if report.State != "completed" || len(f.read) != 6 {
		t.Fatalf("state=%s reads=%v", report.State, f.read)
	}
	expected := map[uint32]string{1: "Camera (1)", 2: "2022/02月/same (1).jpg", 3: "2024/03月/fallback.jpg", 4: "日期未知/unknown.jpg", 5: "2023/01月/new-year.jpg", 6: "Camera (1)/note.txt", 8: "2022/02月/same (2).jpg", 9: "Camera (1)/Empty"}
	if len(report.Items) != len(expected) {
		t.Fatalf("unexpected plan: %+v", report.Items)
	}
	for _, item := range report.Items {
		if item.Path != expected[item.Entry.ID] || item.State != "completed" || item.ArchiveDateWarning != "" || item.CreationDateWarning != "" {
			t.Fatalf("item=%+v", item)
		}
		path := filepath.Join(output, item.Path)
		if item.Entry.IsDirectory {
			if info, err := os.Stat(path); err != nil || !info.IsDir() {
				t.Fatalf("directory=%s error=%v", path, err)
			}
			continue
		}
		data, err := os.ReadFile(path)
		if err != nil || !bytes.Equal(data, f.data[item.Entry.ID]) {
			t.Fatalf("data changed: %s %v", path, err)
		}
		hash := sha256.Sum256(data)
		if item.SHA256 != hex.EncodeToString(hash[:]) {
			t.Fatal("hash mismatch")
		}
		info, err := os.Stat(path)
		if err != nil || item.Entry.Modified > 0 && info.ModTime().Unix() != item.Entry.Modified {
			t.Fatalf("modification date changed: %s %v", path, err)
		}
		source := ""
		switch item.Entry.ID {
		case 2, 5, 8:
			source = "exif"
		case 3:
			source = "modified"
		case 4:
			source = "unknown"
		}
		if item.ArchiveDateSource != source {
			t.Fatalf("unexpected date source: %+v", item)
		}
		if source != "" && !strings.HasPrefix(item.SourcePath, "Camera/") {
			t.Fatalf("original path lost: %+v", item)
		}
		if source == "exif" && creationDate {
			date, err := time.Parse(time.RFC3339Nano, item.ArchiveDate)
			if err != nil || item.PhotoCreationTime != date.Unix() || !birthTime(t, path).Equal(date) {
				t.Fatalf("creation date=%v report=%+v error=%v", birthTime(t, path), item, err)
			}
		} else if item.PhotoCreationTime != 0 {
			t.Fatalf("unrequested creation date change: %+v", item)
		}
	}
	for name, want := range existing {
		if data, err := os.ReadFile(filepath.Join(output, name)); err != nil || string(data) != want {
			t.Fatalf("existing file changed: %s %v", name, err)
		}
	}
	if matches, _ := filepath.Glob(filepath.Join(output, ".ferry-*")); len(matches) != 0 {
		t.Fatalf("temporary files remain: %v", matches)
	}
	if _, err := os.Stat(filepath.Join(output, "2022 (1)")); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("existing year folder was not reused")
	}
}

func TestMonthArchiveDropsPhotoOnlySourceFolders(t *testing.T) {
	f := archiveFixture(t)
	f.children[1] = []uint32{2, 7}
	items, _, err := engine(f).plan(context.Background(), 1, []uint32{1}, false, true)
	if err != nil {
		t.Fatal(err)
	}
	items = monthArchivePlan(items, true, false)
	if len(items) != 2 || items[0].SourcePath != "Camera/same.jpg" || items[1].SourcePath != "Camera/Trip/same.jpg" {
		t.Fatalf("plan=%+v", items)
	}
}

func TestMonthArchivePathConflictsPreserveExistingEntries(t *testing.T) {
	for _, kind := range []string{"year-file", "month-file", "year-link", "month-link"} {
		t.Run(kind, func(t *testing.T) {
			destination, outside := t.TempDir(), t.TempDir()
			path := "2022"
			if strings.HasPrefix(kind, "month") {
				path = "2022/02月"
				if err := os.Mkdir(filepath.Join(destination, "2022"), 0700); err != nil {
					t.Fatal(err)
				}
			}
			if strings.HasSuffix(kind, "file") {
				if err := os.WriteFile(filepath.Join(destination, path), []byte("old"), 0600); err != nil {
					t.Fatal(err)
				}
			} else if err := os.Symlink(outside, filepath.Join(destination, path)); err != nil {
				t.Fatal(err)
			}
			f := archiveFixture(t)
			_, err := engine(f).Download(context.Background(), Request{StorageID: 1, ObjectIDs: []uint32{2}, Destination: destination, DownloadLayout: "direct", ReportDirectory: t.TempDir(), ArchivePhotosByMonth: true}, "synthetic")
			if err == nil {
				t.Fatal("expected archive path conflict")
			}
			if strings.HasSuffix(kind, "file") {
				if data, err := os.ReadFile(filepath.Join(destination, path)); err != nil || string(data) != "old" {
					t.Fatalf("existing file changed: %v", err)
				}
			} else if info, err := os.Lstat(filepath.Join(destination, path)); err != nil || info.Mode()&os.ModeSymlink == 0 {
				t.Fatalf("existing symlink changed: %v", err)
			}
			if entries, err := os.ReadDir(outside); err != nil || len(entries) != 0 {
				t.Fatalf("wrote outside destination: %v %v", entries, err)
			}
			if matches, _ := filepath.Glob(filepath.Join(destination, ".ferry-*")); len(matches) != 0 {
				t.Fatalf("temporary files remain: %v", matches)
			}
		})
	}
}

func TestMonthArchiveCancellationKeepsCompletedFiles(t *testing.T) {
	f := archiveFixture(t)
	destination := t.TempDir()
	job, _, err := engine(f).PrepareDownload(context.Background(), Request{StorageID: 1, ObjectIDs: []uint32{2, 5}, Destination: destination, DownloadLayout: "direct", ReportDirectory: t.TempDir(), ArchivePhotosByMonth: true}, "synthetic")
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
	if data, err := os.ReadFile(filepath.Join(destination, "2022/02月/same.jpg")); err != nil || !bytes.Equal(data, f.data[2]) {
		t.Fatalf("completed file lost: %v", err)
	}
	if len(f.read) != 1 {
		t.Fatalf("cancelled file was read: %v", f.read)
	}
	if _, err := os.Stat(filepath.Join(destination, "2023/01月/new-year.jpg")); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("cancelled file was published")
	}
}

func TestExternalVolumeMonthArchive(t *testing.T) {
	volume := os.Getenv("FERRY_TEST_VOLUME")
	if volume == "" {
		t.Skip("set FERRY_TEST_VOLUME to explicitly test an external destination")
	}
	directory, err := os.MkdirTemp(volume, ".ferry-month-archive-test-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := os.RemoveAll(directory); err != nil {
			t.Errorf("clean test directory: %v", err)
		}
	})
	testMonthArchive(t, directory, t.TempDir(), "direct", false, true)
}
