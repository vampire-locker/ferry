package transfer

import (
	"bytes"
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"testing"
)

type thumbnailDevice struct {
	*fakeDevice
	thumb    []byte
	thumbErr error
	calls    int
}

func (d *thumbnailDevice) Thumbnail(ctx context.Context, id uint32, w io.Writer) error {
	d.calls++
	if d.thumbErr != nil {
		return d.thumbErr
	}
	_, err := w.Write(d.thumb)
	return err
}

func mediaFixture() *fakeDevice {
	f := fixture()
	f.entries[2] = Entry{ID: 2, StorageID: 1, Name: "照片.JPG", Size: 5}
	f.entries[4] = Entry{ID: 4, StorageID: 1, Name: "视频.mp4", Size: 1 << 30}
	f.entries[5] = Entry{ID: 5, StorageID: 1, Name: "大图.heic", Size: MaxThumbnailBytes + 1}
	return f
}

func TestPreviewStagesOneCompleteMediaFile(t *testing.T) {
	f := mediaFixture()
	destination := t.TempDir()
	output, err := engine(f).Preview(context.Background(), Request{StorageID: 1, ObjectIDs: []uint32{2}, Destination: destination})
	if err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(output)
	if err != nil || !bytes.Equal(data, f.data[2]) {
		t.Fatalf("%q, %v", data, err)
	}
	files, _ := os.ReadDir(filepath.Dir(output))
	if len(files) != 1 || files[0].Name() != "照片.JPG" {
		t.Fatalf("unexpected output: %v", files)
	}
}

func TestPreviewRejectsInvalidRequestsAndCleansFailures(t *testing.T) {
	for _, test := range []string{"empty", "multiple", "folder", "unsafe", "storage", "hidden", "type", "length", "read", "space", "cancel"} {
		t.Run(test, func(t *testing.T) {
			f := mediaFixture()
			e := engine(f)
			destination := t.TempDir()
			req := Request{StorageID: 1, ObjectIDs: []uint32{2}, Destination: destination}
			entry := f.entries[2]
			ctx := context.Background()
			switch test {
			case "empty":
				req.ObjectIDs = nil
			case "multiple":
				req.ObjectIDs = []uint32{2, 4}
			case "folder":
				req.ObjectIDs = []uint32{1}
			case "unsafe":
				entry.Name = "../escape.jpg"
			case "storage":
				req.StorageID = 2
			case "hidden":
				entry.Name = ".photo.jpg"
			case "type":
				entry.Name = "file.zip"
			case "length":
				f.data[2] = []byte("bad")
			case "read":
				f.readErr = errors.New("disconnected")
			case "space":
				e.Available = func(string) (uint64, error) { return ReserveBytes, nil }
			case "cancel":
				var cancel context.CancelFunc
				ctx, cancel = context.WithCancel(ctx)
				cancel()
			}
			f.entries[2] = entry
			if output, err := e.Preview(ctx, req); err == nil || output != "" {
				t.Fatalf("%q, %v", output, err)
			}
			files, _ := os.ReadDir(destination)
			if len(files) != 0 {
				t.Fatal("failed preview left cache/partial files")
			}
		})
	}
}

func TestThumbnailsUseDeviceAndBoundImageFallback(t *testing.T) {
	for _, native := range []bool{false, true} {
		f := mediaFixture()
		e := engine(f)
		thumb := &thumbnailDevice{fakeDevice: f, thumb: []byte("thumbnail")}
		if native {
			e.Device = thumb
		}
		var events []Event
		e.Emit = func(event Event) { events = append(events, event) }
		err := e.Thumbnails(context.Background(), Request{StorageID: 1, ObjectIDs: []uint32{2, 4, 5}, Destination: t.TempDir()})
		if err != nil {
			t.Fatal(err)
		}
		if len(events) != 3 {
			t.Fatal(events)
		}
		if native {
			if thumb.calls != 3 || len(f.read) != 0 {
				t.Fatal("native thumbnail downloaded original")
			}
		} else if len(f.read) != 1 || f.read[0] != 2 {
			t.Fatal("auto-downloaded a video or large image")
		}
		for index, event := range events {
			if event.ObjectID != []uint32{2, 4, 5}[index] {
				t.Fatal("wrong object ID")
			}
			if native || index == 0 {
				data, err := os.ReadFile(event.Output)
				wanted := f.data[2]
				if native {
					wanted = thumb.thumb
				}
				if err != nil || !bytes.Equal(data, wanted) {
					t.Fatalf("%q, %v", data, err)
				}
			} else if event.State != "unavailable" || event.Output != "" {
				t.Fatal(event)
			}
		}
	}
}

func TestThumbnailFailuresNeverFallBackAfterTransportError(t *testing.T) {
	for _, test := range []string{"unsupported", "transport", "oversize", "cancel"} {
		t.Run(test, func(t *testing.T) {
			f := mediaFixture()
			d := &thumbnailDevice{fakeDevice: f, thumb: []byte("thumb")}
			e := engine(f)
			e.Device = d
			destination := t.TempDir()
			ctx := context.Background()
			switch test {
			case "unsupported":
				d.thumbErr = ErrThumbnailUnavailable
			case "transport":
				d.thumbErr = errors.New("USB timeout")
			case "oversize":
				d.thumb = make([]byte, MaxThumbnailBytes+1)
			case "cancel":
				var cancel context.CancelFunc
				ctx, cancel = context.WithCancel(ctx)
				cancel()
			}
			err := e.Thumbnails(ctx, Request{StorageID: 1, ObjectIDs: []uint32{2}, Destination: destination})
			if test == "unsupported" {
				if err != nil || len(f.read) != 1 {
					t.Fatalf("fallback failed: %v", err)
				}
			} else {
				if err == nil || len(f.read) != 0 {
					t.Fatalf("unexpected fallback: %v", err)
				}
				files, _ := os.ReadDir(destination)
				if len(files) != 0 {
					t.Fatal("partial thumbnail left behind")
				}
			}
		})
	}
}

func TestThumbnailBatchLimitAndMediaKinds(t *testing.T) {
	for _, count := range []int{0, MaxThumbnailBatch + 1} {
		f := mediaFixture()
		if err := engine(f).Thumbnails(context.Background(), Request{ObjectIDs: make([]uint32, count)}); err == nil {
			t.Fatal("invalid batch accepted")
		}
		if len(f.read) != 0 {
			t.Fatal("read before validation")
		}
	}
	for name, wanted := range map[string]string{"PHOTO.HEIF": "image", "a.m4v": "video", "a.txt": "", "x.tiff": "image"} {
		if got := MediaKind(Entry{Name: name}); got != wanted {
			t.Fatalf("%s: %q", name, got)
		}
	}
	if MediaKind(Entry{Name: "folder.jpg", IsDirectory: true}) != "" {
		t.Fatal("folder treated as image")
	}
}
