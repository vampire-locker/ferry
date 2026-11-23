package transfer

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"io"
	"os"
	"testing"
	"time"
)

func videoAtom(kind string, payload ...[]byte) []byte {
	data := bytes.Join(payload, nil)
	box := make([]byte, 8+len(data))
	binary.BigEndian.PutUint32(box[:4], uint32(len(box)))
	copy(box[4:8], kind)
	copy(box[8:], data)
	return box
}

func videoMovie(date time.Time, version byte) []byte {
	length := 100
	if version == 1 {
		length = 112
	}
	header := make([]byte, length)
	header[0] = version
	var seconds uint64
	if !date.IsZero() {
		seconds = uint64(date.Unix()) + quickTimeEpochOffset
	}
	if version == 0 {
		binary.BigEndian.PutUint32(header[4:8], uint32(seconds))
	} else {
		binary.BigEndian.PutUint64(header[4:12], seconds)
	}
	return videoAtom("mvhd", header)
}

func videoDateMetadata(value string, keysLast bool) []byte {
	key := videoAtom("mdta", []byte("com.apple.quicktime.creationdate"))
	header := make([]byte, 8)
	binary.BigEndian.PutUint32(header[4:], 1)
	keys := videoAtom("keys", header, key)
	dataHeader := make([]byte, 8)
	binary.BigEndian.PutUint32(dataHeader[:4], 1)
	index := string([]byte{0, 0, 0, 1})
	list := videoAtom("ilst", videoAtom(index, videoAtom("data", dataHeader, []byte(value))))
	if keysLast {
		return videoAtom("meta", make([]byte, 4), list, keys)
	}
	return videoAtom("meta", make([]byte, 4), keys, list)
}

func TestVideoDateTextPreservesTimezonesAndRejectsInvalidDates(t *testing.T) {
	local := time.FixedZone("UTC+8", 8*3600)
	for _, tc := range []struct{ value, want string }{
		{"2026-02-28T23:55:00-0500", "2026-02-28T23:55:00-05:00"},
		{"2026-03-01T00:05:00.123+08:00", "2026-03-01T00:05:00.123+08:00"},
		{"2025-12-31T23:50:00Z", "2025-12-31T23:50:00Z"},
		{"2024-02-29 23:59:59", "2024-02-29T23:59:59+08:00"},
		{"2024-02-29", "2024-02-29T00:00:00+08:00"},
		{"\x002026-01-01T00:00:00+0800\x00", "2026-01-01T00:00:00+08:00"},
		{"2026-02-29T12:00:00Z", ""}, {"2026-01-01T12:00:00+24:00", ""},
		{"2026-01-01T12:00:00+0860", ""}, {"1969-12-31T12:00:00Z", ""},
		{"0000-00-00T00:00:00Z", ""}, {"2026", ""}, {"", ""},
	} {
		t.Run(tc.value, func(t *testing.T) {
			date, ok := parseVideoOriginal(tc.value, local)
			if tc.want == "" {
				if ok {
					t.Fatalf("accepted %q: %v", tc.value, date)
				}
				return
			}
			if !ok || date.Format(time.RFC3339Nano) != tc.want {
				t.Fatalf("date=%v valid=%v want=%s", date, ok, tc.want)
			}
		})
	}
}

func TestVideoContainerUTCTimeUsesLocalCalendarAndMetadataTakesPriority(t *testing.T) {
	local := time.FixedZone("UTC+8", 8*3600)
	utc := time.Date(2026, 2, 28, 20, 30, 0, 0, time.UTC)
	for _, version := range []byte{0, 1} {
		for _, withMetadata := range []bool{false, true} {
			data := videoAtom("moov", videoMovie(utc, version))
			if withMetadata {
				data = videoAtom("moov", videoMovie(utc, version), videoAtom("udta", videoDateMetadata("2026-02-28T23:55:00-0500", true)))
			}
			date, source, err := parseVideoCaptureDate(context.Background(), bytes.NewReader(data), int64(len(data)), local)
			if err != nil {
				t.Fatal(err)
			}
			if withMetadata {
				if source != "video_metadata" || date.Format(time.RFC3339) != "2026-02-28T23:55:00-05:00" {
					t.Fatalf("%v %s", date, source)
				}
			} else if source != "container" || date.Format(time.RFC3339) != "2026-03-01T04:30:00+08:00" {
				t.Fatalf("%v %s", date, source)
			}
		}
	}
	data := videoAtom("moov", videoMovie(time.Date(2050, 12, 31, 23, 59, 59, 0, time.UTC), 1))
	date, _, err := parseVideoCaptureDate(context.Background(), bytes.NewReader(data), int64(len(data)), time.UTC)
	if err != nil || date.Year() != 2050 {
		t.Fatalf("64-bit movie date %v %v", date, err)
	}
}

func TestVideoLegacyDateAndInvalidMetadataFallback(t *testing.T) {
	value := "2025-12-31T23:59:00+0800"
	header := make([]byte, 4)
	binary.BigEndian.PutUint16(header[:2], uint16(len(value)))
	legacy := videoAtom("udta", videoAtom("\xa9day", header, []byte(value)))
	data := videoAtom("moov", videoMovie(time.Time{}, 0), legacy)
	date, source, err := parseVideoCaptureDate(context.Background(), bytes.NewReader(data), int64(len(data)), time.UTC)
	if err != nil || source != "video_metadata" || date.Month() != 12 {
		t.Fatalf("%v %s %v", date, source, err)
	}
	utc := time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)
	data = videoAtom("moov", videoDateMetadata("not a date", false), videoMovie(utc, 0))
	date, source, err = parseVideoCaptureDate(context.Background(), bytes.NewReader(data), int64(len(data)), time.UTC)
	if err != nil || source != "container" || !date.Equal(utc) {
		t.Fatalf("%v %s %v", date, source, err)
	}
	data = videoAtom("moov", videoDateMetadata("2026-01-01T00:00:00Z", false), videoDateMetadata("2026-02-01T00:00:00Z", false))
	if _, _, err := parseVideoCaptureDate(context.Background(), bytes.NewReader(data), int64(len(data)), time.UTC); err == nil {
		t.Fatal("accepted contradictory metadata")
	}
}

type sparseVideoReader struct {
	segments  map[int64][]byte
	readBytes int
}

func (r *sparseVideoReader) ReadAt(p []byte, offset int64) (int, error) {
	r.readBytes += len(p)
	clear(p)
	for at, data := range r.segments {
		start, end := max(at, offset), min(at+int64(len(data)), offset+int64(len(p)))
		if end > start {
			copy(p[start-offset:end-offset], data[start-at:end-at])
		}
	}
	return len(p), nil
}

func TestVideoMoovAtEndSkipsNineGiBOfVideoPayload(t *testing.T) {
	const mediaSize = int64(9) << 30
	mdat := make([]byte, 16)
	binary.BigEndian.PutUint32(mdat[:4], 1)
	copy(mdat[4:8], "mdat")
	binary.BigEndian.PutUint64(mdat[8:], uint64(mediaSize))
	date := time.Date(2026, 3, 1, 0, 0, 0, 0, time.UTC)
	moov := videoAtom("moov", videoMovie(date, 1))
	reader := &sparseVideoReader{segments: map[int64][]byte{0: mdat, mediaSize: moov}}
	got, source, err := parseVideoCaptureDate(context.Background(), reader, mediaSize+int64(len(moov)), time.UTC)
	if err != nil || !got.Equal(date) || source != "container" {
		t.Fatalf("%v %s %v", got, source, err)
	}
	if reader.readBytes > 4096 {
		t.Fatalf("read video content: %d bytes", reader.readBytes)
	}
}

func TestVideoMetadataLimitsMalformedBoxesAndCancellation(t *testing.T) {
	giant := make([]byte, 16)
	binary.BigEndian.PutUint32(giant[:4], 1)
	copy(giant[4:8], "moov")
	binary.BigEndian.PutUint64(giant[8:], ^uint64(0))
	deep := videoAtom("free")
	for range 12 {
		deep = videoAtom("udta", deep)
	}
	keys := make([]byte, 8)
	binary.BigEndian.PutUint32(keys[4:], 1025)
	for _, data := range [][]byte{[]byte("short"), giant, videoAtom("mvhd"), deep, bytes.Repeat(videoAtom("free"), 4097), videoAtom("moov", videoAtom("meta", make([]byte, 4), videoAtom("keys", keys)))} {
		if _, _, err := parseVideoCaptureDate(context.Background(), bytes.NewReader(data), int64(len(data)), time.UTC); err == nil {
			t.Fatal("accepted malformed or unbounded metadata")
		}
	}
	// Even well-framed metadata is subject to the total read budget.
	key := videoAtom("mdta", bytes.Repeat([]byte("x"), 4096))
	keys = make([]byte, 8)
	binary.BigEndian.PutUint32(keys[4:], 1024)
	data := videoAtom("moov", videoAtom("meta", make([]byte, 4), videoAtom("keys", keys, bytes.Repeat(key, 1024))))
	if _, _, err := parseVideoCaptureDate(context.Background(), bytes.NewReader(data), int64(len(data)), time.UTC); !errors.Is(err, errVideoDateLimit) {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	data = videoAtom("moov", videoMovie(time.Now(), 0))
	if _, _, err := parseVideoCaptureDate(ctx, bytes.NewReader(data), int64(len(data)), time.UTC); !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
}

func TestVideoBundledMP4CanBeReadWithoutDecoding(t *testing.T) {
	file, err := os.Open("../device/fixtures/demo.mp4")
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := parseVideoCaptureDate(context.Background(), io.NewSectionReader(file, 0, info.Size()), info.Size(), time.UTC); err != nil {
		t.Fatal(err)
	}
}

func FuzzVideoDateParser(f *testing.F) {
	f.Add(videoAtom("moov", videoMovie(time.Date(2026, 2, 28, 20, 30, 0, 0, time.UTC), 0)))
	f.Add(videoAtom("moov", videoDateMetadata("2026-02-28T23:55:00+0800", false)))
	f.Add([]byte("invalid"))
	f.Fuzz(func(t *testing.T, data []byte) {
		if len(data) > 1<<20 {
			t.Skip()
		}
		date, source, err := parseVideoCaptureDate(context.Background(), bytes.NewReader(data), int64(len(data)), time.UTC)
		if err != nil && (!date.IsZero() || source != "") {
			t.Fatal("failed metadata returned a usable date")
		}
		if !date.IsZero() && (date.Year() < 1970 || date.Year() > 9999) {
			t.Fatal(date)
		}
	})
}
