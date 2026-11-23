package transfer

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type fakeDevice struct {
	entries   map[uint32]Entry
	children  map[uint32][]uint32
	data      map[uint32][]byte
	readErr   error
	listed    []uint32
	read      []uint32
	afterRead func()
}

func (f *fakeDevice) Connect(context.Context) (string, []Storage, error) { return "test", nil, nil }
func (f *fakeDevice) Close()                                             {}
func (f *fakeDevice) Info(ctx context.Context, id uint32) (Entry, error) {
	e, ok := f.entries[id]
	if !ok {
		return Entry{}, errors.New("missing object")
	}
	return e, ctx.Err()
}
func (f *fakeDevice) List(ctx context.Context, storage, parent uint32) ([]Entry, error) {
	f.listed = append(f.listed, parent)
	var entries []Entry
	for _, id := range f.children[parent] {
		entries = append(entries, f.entries[id])
	}
	return entries, ctx.Err()
}
func (f *fakeDevice) Read(ctx context.Context, id uint32, w io.Writer) error {
	f.read = append(f.read, id)
	if err := ctx.Err(); err != nil {
		return err
	}
	if _, err := io.Copy(w, bytes.NewReader(f.data[id])); err != nil {
		return err
	}
	if f.afterRead != nil {
		f.afterRead()
	}
	return f.readErr
}
func fixture() *fakeDevice {
	return &fakeDevice{entries: map[uint32]Entry{
		1: {ID: 1, StorageID: 1, Name: "照片", IsDirectory: true},
		2: {ID: 2, StorageID: 1, Name: "旅行.txt", Size: 5},
		3: {ID: 3, StorageID: 1, Name: "空目录", IsDirectory: true},
	}, children: map[uint32][]uint32{1: {2, 3}}, data: map[uint32][]byte{2: []byte("hello")}}
}
func engine(f *fakeDevice) *Engine {
	return &Engine{Device: f, Emit: func(Event) {}, Available: func(string) (uint64, error) { return 1 << 40, nil }}
}
func reportAt(t *testing.T, output string) Report {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(output, "传输报告.json"))
	if err != nil {
		t.Fatal(err)
	}
	var report Report
	if err := json.Unmarshal(data, &report); err != nil {
		t.Fatal(err)
	}
	return report
}
func TestDownloadPreservesExistingAndWritesReport(t *testing.T) {
	target := t.TempDir()
	os.WriteFile(filepath.Join(target, "旅行.txt"), []byte("old"), 0600)
	output, err := engine(fixture()).Download(context.Background(), Request{StorageID: 1, ObjectIDs: []uint32{1}, Destination: target}, "phone")
	if err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(filepath.Join(output, "files", "照片", "旅行.txt"))
	if err != nil || string(got) != "hello" {
		t.Fatalf("%q %v", got, err)
	}
	old, _ := os.ReadFile(filepath.Join(target, "旅行.txt"))
	if string(old) != "old" {
		t.Fatal("existing backup changed")
	}
	report := reportAt(t, output)
	if report.State != "completed" || len(report.Items) != 3 || report.Items[1].SHA256 == "" {
		t.Fatalf("invalid report: %+v", report)
	}
	if stat, err := os.Stat(filepath.Join(output, "files", "照片", "空目录")); err != nil || !stat.IsDir() {
		t.Fatal("empty directory missing")
	}
}

func hiddenFixture() *fakeDevice {
	f := fixture()
	f.entries[4] = Entry{ID: 4, StorageID: 1, Name: ".nomedia", Size: 7}
	f.entries[5] = Entry{ID: 5, StorageID: 1, Name: ".cache", IsDirectory: true}
	f.entries[6] = Entry{ID: 6, StorageID: 1, Name: "cached.txt", Size: 9}
	f.entries[7] = Entry{ID: 7, StorageID: 1, Name: "子目录", IsDirectory: true}
	f.entries[8] = Entry{ID: 8, StorageID: 1, Name: ".nested", Size: 11}
	f.entries[9] = Entry{ID: 9, StorageID: 1, Name: ".nested-cache", IsDirectory: true}
	f.entries[10] = Entry{ID: 10, StorageID: 1, Name: "nested.txt", Size: 13}
	f.entries[11] = Entry{ID: 11, StorageID: 1, Name: "a.b.txt", Size: 3}
	f.children[1] = append(f.children[1], 4, 5, 7)
	f.children[5] = []uint32{6}
	f.children[7] = []uint32{8, 9, 11}
	f.children[9] = []uint32{10}
	for _, id := range []uint32{4, 6, 8, 10, 11} {
		f.data[id] = bytes.Repeat([]byte("x"), int(f.entries[id].Size))
	}
	return f
}

func TestDownloadRecursivelyFollowsHiddenFilesSetting(t *testing.T) {
	for _, showHidden := range []bool{false, true} {
		name := "hidden-excluded"
		if showHidden {
			name = "hidden-included"
		}
		t.Run(name, func(t *testing.T) {
			f := hiddenFixture()
			wanted := map[uint32]string{1: "照片", 2: "照片/旅行.txt", 3: "照片/空目录", 7: "照片/子目录", 11: "照片/子目录/a.b.txt"}
			var totalBytes int64 = 8
			fileCount := 2
			if showHidden {
				wanted[4] = "照片/.nomedia"
				wanted[5] = "照片/.cache"
				wanted[6] = "照片/.cache/cached.txt"
				wanted[8] = "照片/子目录/.nested"
				wanted[9] = "照片/子目录/.nested-cache"
				wanted[10] = "照片/子目录/.nested-cache/nested.txt"
				totalBytes = 48
				fileCount = 6
			}
			e := engine(f)
			// Exactly enough space for the filtered plan plus the required reserve.
			e.Available = func(string) (uint64, error) { return ReserveBytes + uint64(totalBytes), nil }
			var progress Event
			e.Emit = func(event Event) {
				if event.Type == "progress" {
					if event.Total != fileCount || event.TotalBytes != totalBytes {
						t.Fatalf("incorrect progress totals: %+v", event)
					}
					progress = event
				}
			}
			output, err := e.Download(context.Background(), Request{
				StorageID: 1, ObjectIDs: []uint32{1}, Destination: t.TempDir(), ShowHiddenFiles: showHidden,
			}, "phone")
			if err != nil {
				t.Fatal(err)
			}
			report := reportAt(t, output)
			if report.State != "completed" || len(report.Items) != len(wanted) {
				t.Fatalf("unexpected report: %+v", report)
			}
			for _, item := range report.Items {
				if path, ok := wanted[item.Entry.ID]; !ok || item.Path != path {
					t.Fatalf("unexpected planned item: %+v", item)
				}
				path := filepath.Join(output, "files", item.Path)
				if item.Entry.IsDirectory {
					if stat, err := os.Stat(path); err != nil || !stat.IsDir() {
						t.Fatalf("directory missing: %s (%v)", path, err)
					}
				} else if data, err := os.ReadFile(path); err != nil || !bytes.Equal(data, f.data[item.Entry.ID]) {
					t.Fatalf("file content mismatch: %s (%v)", path, err)
				}
			}
			if progress.Completed != fileCount || progress.Bytes != totalBytes || len(f.read) != fileCount {
				t.Fatalf("incorrect completed transfer: %+v, reads: %v", progress, f.read)
			}
			if !showHidden {
				for _, id := range f.listed {
					if id == 5 || id == 9 {
						t.Fatal("traversed a hidden directory")
					}
				}
				err := filepath.WalkDir(filepath.Join(output, "files"), func(path string, entry os.DirEntry, err error) error {
					if err == nil && strings.HasPrefix(entry.Name(), ".") {
						t.Errorf("hidden entry copied: %s", path)
					}
					return err
				})
				if err != nil {
					t.Fatal(err)
				}
			}
		})
	}
}

func TestPlanFiltersDirectHiddenSelections(t *testing.T) {
	for _, id := range []uint32{4, 5} {
		if _, _, err := engine(hiddenFixture()).Plan(context.Background(), 1, []uint32{id}, false); err == nil {
			t.Fatal("hidden-only selection should be rejected")
		}
		items, _, err := engine(hiddenFixture()).Plan(context.Background(), 1, []uint32{id}, true)
		if err != nil || len(items) == 0 || items[0].Entry.ID != id {
			t.Fatalf("explicitly visible hidden selection failed: %v, %v", items, err)
		}
	}
	items, total, err := engine(hiddenFixture()).Plan(context.Background(), 1, []uint32{4, 5, 2}, false)
	if err != nil || len(items) != 1 || items[0].Entry.ID != 2 || total != 5 {
		t.Fatalf("hidden selection not filtered: %v, %d, %v", items, total, err)
	}
}

func TestRequestDecodesHiddenFilesSetting(t *testing.T) {
	for _, test := range []struct {
		payload string
		want    bool
	}{
		{`{"operation":"download"}`, false},
		{`{"operation":"download","showHiddenFiles":false}`, false},
		{`{"operation":"download","showHiddenFiles":true}`, true},
	} {
		var req Request
		if err := json.Unmarshal([]byte(test.payload), &req); err != nil {
			t.Fatal(err)
		}
		if req.ShowHiddenFiles != test.want {
			t.Fatalf("%s: got %v, want %v", test.payload, req.ShowHiddenFiles, test.want)
		}
	}
}
func TestReadFailureNeverCommitsPartial(t *testing.T) {
	f := fixture()
	f.readErr = errors.New("USB disconnected")
	output, err := engine(f).Download(context.Background(), Request{StorageID: 1, ObjectIDs: []uint32{2}, Destination: t.TempDir()}, "phone")
	if err == nil {
		t.Fatal("expected failure")
	}
	files, _ := os.ReadDir(filepath.Join(output, "files"))
	if len(files) != 0 {
		t.Fatal("partial data exposed")
	}
	report := reportAt(t, output)
	if report.State != "failed" || report.Items[0].State != "failed" {
		t.Fatal(report)
	}
}
func TestLengthMismatch(t *testing.T) {
	f := fixture()
	f.data[2] = []byte("bad")
	_, err := engine(f).Download(context.Background(), Request{StorageID: 1, ObjectIDs: []uint32{2}, Destination: t.TempDir()}, "phone")
	if err == nil || !strings.Contains(err.Error(), "长度不符") {
		t.Fatal(err)
	}
}
func TestInsufficientSpaceWritesNothing(t *testing.T) {
	e := engine(fixture())
	e.Available = func(string) (uint64, error) { return ReserveBytes, nil }
	target := t.TempDir()
	_, err := e.Download(context.Background(), Request{StorageID: 1, ObjectIDs: []uint32{1}, Destination: target}, "phone")
	if err == nil {
		t.Fatal("expected low-space error")
	}
	items, _ := os.ReadDir(target)
	if len(items) != 0 {
		t.Fatal("wrote before preflight")
	}
}
func TestSpaceLostDuringWrite(t *testing.T) {
	e := engine(fixture())
	checks := 0
	e.Available = func(string) (uint64, error) {
		checks++
		if checks > 2 {
			return 0, nil
		}
		return 1 << 40, nil
	}
	output, err := e.Download(context.Background(), Request{StorageID: 1, ObjectIDs: []uint32{2}, Destination: t.TempDir()}, "phone")
	if err == nil {
		t.Fatal("expected low-space error")
	}
	files, _ := os.ReadDir(filepath.Join(output, "files"))
	if len(files) != 0 {
		t.Fatal("partial file remains")
	}
}
func TestCancelBeforeTransfer(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	target := t.TempDir()
	_, err := engine(fixture()).Download(ctx, Request{StorageID: 1, ObjectIDs: []uint32{1}, Destination: target}, "phone")
	if !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
	items, _ := os.ReadDir(target)
	if len(items) != 0 {
		t.Fatal("cancelled task wrote data")
	}
}
func TestCancelDuringTransfer(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	e := engine(fixture())
	e.Emit = func(event Event) {
		if event.CurrentFile != "" {
			cancel()
		}
	}
	output, err := e.Download(ctx, Request{StorageID: 1, ObjectIDs: []uint32{2}, Destination: t.TempDir()}, "phone")
	if !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
	if reportAt(t, output).State != "cancelled" {
		t.Fatal("cancel not recorded")
	}
	files, _ := os.ReadDir(filepath.Join(output, "files"))
	if len(files) != 0 {
		t.Fatal("cancelled file published")
	}
}
func TestUnsafeNameAndCollision(t *testing.T) {
	for _, name := range []string{"../escape", "a/b", "..", "a:b", "a\x00b"} {
		t.Run(name, func(t *testing.T) {
			f := fixture()
			entry := f.entries[2]
			entry.Name = name
			f.entries[2] = entry
			if _, _, err := engine(f).Plan(context.Background(), 1, []uint32{2}, false); err == nil {
				t.Fatal("unsafe name accepted")
			}
		})
	}
	f := fixture()
	f.entries[4] = Entry{ID: 4, StorageID: 1, Name: "旅行.TXT", Size: 5}
	f.children[1] = append(f.children[1], 4)
	if _, _, err := engine(f).Plan(context.Background(), 1, []uint32{1}, false); err == nil {
		t.Fatal("collision accepted")
	}
}
func TestCycleAndStorageMismatch(t *testing.T) {
	f := fixture()
	f.children[1] = append(f.children[1], 1)
	if _, _, err := engine(f).Plan(context.Background(), 1, []uint32{1}, false); err == nil {
		t.Fatal("cycle accepted")
	}
	if _, _, err := engine(fixture()).Plan(context.Background(), 2, []uint32{1}, false); err == nil {
		t.Fatal("wrong storage accepted")
	}
}
func TestCommitDoesNotReplaceExisting(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "旅行.txt"), []byte("old"), 0600)
	root, err := os.OpenRoot(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer root.Close()
	_, err = engine(fixture()).writeFile(context.Background(), root, dir, Item{Entry: fixture().entries[2], Path: "旅行.txt"}, func(int64) {})
	if err == nil {
		t.Fatal("overwrote existing file")
	}
	data, _ := os.ReadFile(filepath.Join(dir, "旅行.txt"))
	if string(data) != "old" {
		t.Fatal("old file changed")
	}
}

func (f *fakeDevice) Identity() string { return "test" }

func TestDownloadNeverTreatsUnknownSizeAsZero(t *testing.T) {
	f := fixture()
	e := f.entries[2]
	e.Size = -1
	f.entries[2] = e
	output, err := engine(f).Download(context.Background(), Request{StorageID: 1, ObjectIDs: []uint32{1}, Destination: t.TempDir()}, "phone")
	if err == nil || output != "" || len(f.read) != 0 {
		t.Fatalf("unknown size reached writing: %q %v", output, err)
	}
}
