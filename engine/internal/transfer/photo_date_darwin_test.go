package transfer

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"image"
	"image/jpeg"
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"
)

func TestParsePhotoOriginal(t *testing.T) {
	zone := time.FixedZone("UTC+8", 8*3600)
	for _, tc := range []struct{ original, offset, subsecond, want string }{
		{"2026:02:28 19:31:40", "", "", "2026-02-28T19:31:40+08:00"},
		{"2026:02:28 19:31:40", "+08:00", "123", "2026-02-28T19:31:40.123+08:00"},
		{"2026:02:28 19:31:40", "-05:00", "", "2026-02-28T19:31:40-05:00"},
		{"2026:02:28 19:31:40", "+00:00", "", "2026-02-28T19:31:40Z"},
		{"2024:02:29 23:59:59", "", "", "2024-02-29T23:59:59+08:00"},
		{"2026:02:29 12:00:00", "", "", ""},
		{"0000:00:00 00:00:00", "", "", ""},
		{"2026:02:28 19:31:40", "+24:00", "", ""},
		{"2026:02:28 19:31:40", "+08:99", "", ""},
		{"2026:02:28 19:31:40", "bad", "", ""},
		{"2026:02:28 19:31:40", "", "bad", ""},
		{"", "", "", ""},
	} {
		t.Run(tc.original+tc.offset+tc.subsecond, func(t *testing.T) {
			got, valid := parsePhotoOriginal(tc.original, tc.offset, tc.subsecond, zone)
			if tc.want == "" {
				if valid {
					t.Fatalf("accepted invalid EXIF: %v", got)
				}
			} else if !valid || got.Format(time.RFC3339Nano) != tc.want {
				t.Fatalf("date=%v valid=%v want=%s", got, valid, tc.want)
			}
		})
	}
}

func TestPhotoCreationDateRequestProtocol(t *testing.T) {
	for _, test := range []struct {
		payload string
		enabled bool
	}{
		{`{"operation":"download"}`, false},
		{`{"operation":"download","usePhotoCreationDate":false}`, false},
		{`{"operation":"download","usePhotoCreationDate":true}`, true},
	} {
		var request Request
		if err := json.Unmarshal([]byte(test.payload), &request); err != nil || request.UsePhotoCreationDate != test.enabled {
			t.Fatalf("request=%+v err=%v", request, err)
		}
	}
}

// A real one-pixel JPEG with a minimal EXIF TIFF IFD. No user photos or extra
// runtime/test dependencies are needed to exercise ImageIO's metadata reader.
func photoJPEG(t *testing.T, original, offset, subsecond string) []byte {
	t.Helper()
	var jpegData bytes.Buffer
	if err := jpeg.Encode(&jpegData, image.NewRGBA(image.Rect(0, 0, 1, 1)), nil); err != nil {
		t.Fatal(err)
	}
	type tag struct {
		code  uint16
		value string
	}
	var tags []tag
	for _, value := range []tag{{0x9003, original}, {0x9011, offset}, {0x9291, subsecond}} {
		if value.value != "" {
			tags = append(tags, value)
		}
	}
	// IFD0 has one ExifIFDPointer; EXIF IFD follows at byte 26.
	tiff := make([]byte, 26+2+12*len(tags)+4)
	copy(tiff, []byte{'I', 'I', 42, 0, 8, 0, 0, 0})
	binary.LittleEndian.PutUint16(tiff[8:], 1)
	binary.LittleEndian.PutUint16(tiff[10:], 0x8769)
	binary.LittleEndian.PutUint16(tiff[12:], 4)
	binary.LittleEndian.PutUint32(tiff[14:], 1)
	binary.LittleEndian.PutUint32(tiff[18:], 26)
	binary.LittleEndian.PutUint16(tiff[26:], uint16(len(tags)))
	for index, tag := range tags {
		position := 28 + index*12
		value := append([]byte(tag.value), 0)
		binary.LittleEndian.PutUint16(tiff[position:], tag.code)
		binary.LittleEndian.PutUint16(tiff[position+2:], 2)
		binary.LittleEndian.PutUint32(tiff[position+4:], uint32(len(value)))
		if len(value) <= 4 {
			copy(tiff[position+8:position+12], value)
		} else {
			binary.LittleEndian.PutUint32(tiff[position+8:], uint32(len(tiff)))
			tiff = append(tiff, value...)
		}
	}
	app1 := append([]byte("Exif\x00\x00"), tiff...)
	result := append([]byte{0xff, 0xd8, 0xff, 0xe1, byte((len(app1) + 2) >> 8), byte(len(app1) + 2)}, app1...)
	return append(result, jpegData.Bytes()[2:]...)
}

func birthTime(t *testing.T, path string) time.Time {
	t.Helper()
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	stat := info.Sys().(*syscall.Stat_t)
	return time.Unix(stat.Birthtimespec.Sec, stat.Birthtimespec.Nsec)
}

func TestPhotoCreationDateDownloads(t *testing.T) {
	for _, enabled := range []bool{false, true} {
		for _, copyCommit := range []bool{false, true} {
			t.Run(map[bool]string{false: "off", true: "on"}[enabled]+map[bool]string{false: "/atomic", true: "/copy"}[copyCommit], func(t *testing.T) {
				testPhotoCreationDownload(t, t.TempDir(), t.TempDir(), enabled, copyCommit)
			})
		}
	}
}

func testPhotoCreationDownload(t *testing.T, destination, reports string, enabled, forceCopy bool) {
	t.Helper()
	savedName := "photo.jpg"
	if _, err := os.Lstat(filepath.Join(destination, savedName)); err == nil {
		savedName = "photo (1).jpg"
	}
	data := photoJPEG(t, "2022:02:28 19:31:40", "+08:00", "120")
	f := fixture()
	modified := time.Date(2024, 3, 4, 12, 13, 14, 0, time.UTC).Unix()
	f.entries[2] = Entry{ID: 2, StorageID: 1, Name: "photo.jpg", Size: int64(len(data)), Modified: modified}
	f.data[2] = data
	e := engine(f)
	job, _, err := e.PrepareDownload(context.Background(), Request{StorageID: 1, ObjectIDs: []uint32{2}, Destination: destination, DownloadLayout: "direct", ReportDirectory: reports, UsePhotoCreationDate: enabled}, "synthetic")
	if err != nil {
		t.Fatal(err)
	}
	defer job.Cancel()
	if forceCopy {
		job.copyCommit = true
	}
	if done, err := job.Step(context.Background()); err != nil || !done {
		t.Fatalf("done=%v error=%v", done, err)
	}
	path := filepath.Join(destination, savedName)
	got, err := os.ReadFile(path)
	if err != nil || !bytes.Equal(got, data) {
		t.Fatalf("photo content changed: %v", err)
	}
	if len(f.read) != 1 {
		t.Fatalf("extra phone reads: %v", f.read)
	}
	info, err := os.Stat(path)
	if err != nil || info.ModTime().Unix() != modified {
		t.Fatalf("modified date changed: %v %v", info, err)
	}
	reportData, err := os.ReadFile(job.ReportPath)
	if err != nil {
		t.Fatal(err)
	}
	var report Report
	if err := json.Unmarshal(reportData, &report); err != nil {
		t.Fatal(err)
	}
	item := report.Items[0]
	if item.Path != savedName {
		t.Fatalf("saved path=%s want=%s", item.Path, savedName)
	}
	hash := sha256.Sum256(data)
	if item.SHA256 != hex.EncodeToString(hash[:]) || item.CreationDateWarning != "" {
		t.Fatalf("report=%+v", item)
	}
	want := time.Date(2022, 2, 28, 19, 31, 40, 120000000, time.FixedZone("UTC+8", 8*3600))
	birth := birthTime(t, path)
	if enabled {
		difference := birth.Sub(want)
		if difference < -time.Second || difference > time.Second || item.PhotoCreationTime != want.Unix() {
			t.Fatalf("birth=%v want=%v item=%+v", birth, want, item)
		}
	} else if item.PhotoCreationTime != 0 || birth.Year() == 2022 {
		t.Fatalf("disabled setting changed creation date: %v %+v", birth, item)
	}
}

func TestMissingAndInvalidExifLeaveCreationDateUnchanged(t *testing.T) {
	for _, data := range [][]byte{photoJPEG(t, "", "", ""), photoJPEG(t, "0000:00:00 00:00:00", "", ""), []byte("not an image")} {
		directory := t.TempDir()
		path := filepath.Join(directory, "photo.jpg")
		if err := os.WriteFile(path, data, 0600); err != nil {
			t.Fatal(err)
		}
		before := birthTime(t, path)
		root, err := os.OpenRoot(directory)
		if err != nil {
			t.Fatal(err)
		}
		date, err := applyPhotoCreationDate(root, "photo.jpg")
		root.Close()
		if err != nil || !date.IsZero() || !birthTime(t, path).Equal(before) {
			t.Fatalf("invalid EXIF changed creation date: %v %v", date, err)
		}
	}
}

func TestNativePhotoFormatsAndModificationDate(t *testing.T) {
	for _, name := range []string{"capture.heic", "capture.tiff"} {
		t.Run(name, func(t *testing.T) {
			data, err := os.ReadFile(filepath.Join("testdata", name))
			if err != nil {
				t.Fatal(err)
			}
			root, err := os.OpenRoot(t.TempDir())
			if err != nil {
				t.Fatal(err)
			}
			defer root.Close()
			if err := root.WriteFile(name, data, 0600); err != nil {
				t.Fatal(err)
			}
			// A capture date can be later than the modification date; setting
			// birth time must not silently move modification time forward.
			modified := time.Date(2020, 1, 2, 3, 4, 5, 0, time.UTC)
			if err := root.Chtimes(name, modified, modified); err != nil {
				t.Fatal(err)
			}
			date, err := applyPhotoCreationDate(root, name)
			want := time.Date(2022, 2, 28, 19, 31, 40, 120000000, time.FixedZone("UTC+8", 8*3600))
			if err != nil || !date.Equal(want) {
				t.Fatalf("capture date=%v want=%v error=%v", date, want, err)
			}
			info, err := root.Stat(name)
			if err != nil || !info.ModTime().Equal(modified) {
				t.Fatalf("modified time changed: %v %v", info, err)
			}
			if got, err := root.ReadFile(name); err != nil || !bytes.Equal(got, data) {
				t.Fatalf("image contents changed: %v", err)
			}
		})
	}
}

func TestPhotoDateDoesNotModifyExistingCollision(t *testing.T) {
	destination := t.TempDir()
	path := filepath.Join(destination, "photo.jpg")
	if err := os.WriteFile(path, []byte("old"), 0600); err != nil {
		t.Fatal(err)
	}
	before := birthTime(t, path)
	testPhotoCreationDownload(t, destination, t.TempDir(), true, false)
	if got, err := os.ReadFile(path); err != nil || string(got) != "old" || !birthTime(t, path).Equal(before) {
		t.Fatalf("existing file changed: %q %v", got, err)
	}
}

func TestExternalVolumePhotoCreationDate(t *testing.T) {
	volume := os.Getenv("FERRY_TEST_VOLUME")
	if volume == "" {
		t.Skip("set FERRY_TEST_VOLUME to explicitly test an external destination")
	}
	directory, err := os.MkdirTemp(volume, ".ferry-photo-date-test-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := os.RemoveAll(directory); err != nil {
			t.Errorf("clean test directory: %v", err)
		}
	})
	testPhotoCreationDownload(t, directory, t.TempDir(), true, false)
}
