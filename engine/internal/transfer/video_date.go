package transfer

import (
	"context"
	"encoding/binary"
	"errors"
	"ferry.local/engine/internal/i18n"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
	"unicode/utf8"
)

const quickTimeEpochOffset = uint64(2_082_844_800)

var errVideoDateFormat = errors.New(i18n.Text("视频日期元数据格式无效"))
var errVideoDateLimit = errors.New(i18n.Text("视频日期元数据超过读取限制"))

type videoBox struct {
	kind       string
	start, end int64
}

// ReaderAt skips mdat and unknown payloads by their validated box lengths.
// Never scan video bytes, decode frames, follow paths outside os.Root or let
// untrusted metadata create unbounded allocations/recursion/work.
type videoDateReader struct {
	ctx              context.Context
	reader           io.ReaderAt
	size, budget     int64
	boxes            int
	location         *time.Location
	metadata, header time.Time
	priority         int
}

func readVideoCaptureDate(ctx context.Context, root *os.Root, path, name string) (time.Time, string, error) {
	switch strings.ToLower(filepath.Ext(name)) {
	case ".mp4", ".mov", ".m4v", ".3gp", ".3g2", ".3gpp", ".3gpp2":
	default:
		return time.Time{}, "", nil
	}
	file, err := root.Open(path)
	if err != nil {
		return time.Time{}, "", err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return time.Time{}, "", err
	}
	if !info.Mode().IsRegular() || info.Size() <= 0 {
		return time.Time{}, "", nil
	}
	return parseVideoCaptureDate(ctx, file, info.Size(), time.Local)
}

func parseVideoCaptureDate(ctx context.Context, reader io.ReaderAt, size int64, location *time.Location) (time.Time, string, error) {
	if size < 0 {
		return time.Time{}, "", errVideoDateFormat
	}
	r := videoDateReader{ctx: ctx, reader: reader, size: size, budget: 2 << 20, location: location}
	if err := r.container(0, size, 0); err != nil {
		return time.Time{}, "", err
	}
	if !r.metadata.IsZero() {
		return r.metadata, "video_metadata", nil
	}
	if !r.header.IsZero() {
		return r.header, "container", nil
	}
	return time.Time{}, "", nil
}

func (r *videoDateReader) read(at, count int64) ([]byte, error) {
	if err := r.ctx.Err(); err != nil {
		return nil, err
	}
	if at < 0 || count < 0 || at > r.size || count > r.size-at {
		return nil, errVideoDateFormat
	}
	if count > r.budget {
		return nil, errVideoDateLimit
	}
	r.budget -= count
	data := make([]byte, int(count))
	if _, err := r.reader.ReadAt(data, at); err != nil {
		return nil, err
	}
	return data, nil
}

func (r *videoDateReader) walk(start, end int64, visit func(videoBox) error) error {
	for at := start; at < end; {
		r.boxes++
		if r.boxes > 4096 {
			return errVideoDateLimit
		}
		if end-at < 8 {
			return errVideoDateFormat
		}
		header, err := r.read(at, 8)
		if err != nil {
			return err
		}
		size := uint64(binary.BigEndian.Uint32(header[:4]))
		headerSize := int64(8)
		if size == 1 {
			extended, err := r.read(at+8, 8)
			if err != nil {
				return err
			}
			size, headerSize = binary.BigEndian.Uint64(extended), 16
		} else if size == 0 {
			size = uint64(end - at)
		}
		if size < uint64(headerSize) || size > uint64(end-at) {
			return errVideoDateFormat
		}
		box := videoBox{kind: string(header[4:8]), start: at + headerSize, end: at + int64(size)}
		if err := visit(box); err != nil {
			return err
		}
		at += int64(size)
	}
	return nil
}

func (r *videoDateReader) container(start, end int64, depth int) error {
	if depth > 8 {
		return errVideoDateLimit
	}
	return r.walk(start, end, func(box videoBox) error {
		switch box.kind {
		case "moov", "udta":
			return r.container(box.start, box.end, depth+1)
		case "mvhd":
			return r.movieDate(box)
		case "meta":
			return r.meta(box)
		case "\xa9day":
			return r.dateTag(box, 1)
		}
		return nil
	})
}

func (r *videoDateReader) movieDate(box videoBox) error {
	if box.end-box.start < 4 {
		return errVideoDateFormat
	}
	full, err := r.read(box.start, 4)
	if err != nil {
		return err
	}
	if full[1] != 0 || full[2] != 0 || full[3] != 0 {
		return errVideoDateFormat
	}
	var seconds uint64
	switch full[0] {
	case 0:
		if box.end-box.start < 20 {
			return errVideoDateFormat
		}
		data, err := r.read(box.start+4, 4)
		if err != nil {
			return err
		}
		seconds = uint64(binary.BigEndian.Uint32(data))
	case 1:
		if box.end-box.start < 32 {
			return errVideoDateFormat
		}
		data, err := r.read(box.start+4, 8)
		if err != nil {
			return err
		}
		seconds = binary.BigEndian.Uint64(data)
	default:
		return nil
	}
	// Zero/1904 defaults and malformed epochs are not useful recording dates.
	maximum := uint64(time.Date(9999, 12, 31, 23, 59, 59, 0, time.UTC).Unix()) + quickTimeEpochOffset
	if seconds < quickTimeEpochOffset || seconds > maximum {
		return nil
	}
	date := time.Unix(int64(seconds-quickTimeEpochOffset), 0).In(r.location)
	if date.Year() > 9999 {
		return nil
	}
	if !r.header.IsZero() && !r.header.Equal(date) {
		return errVideoDateFormat
	}
	r.header = date
	return nil
}

func (r *videoDateReader) meta(box videoBox) error {
	if box.end-box.start < 4 {
		return errVideoDateFormat
	}
	first, err := r.read(box.start, 4)
	if err != nil {
		return err
	}
	start := box.start
	if binary.BigEndian.Uint32(first) == 0 {
		start += 4
	}
	keys := make(map[uint32]bool)
	var lists []videoBox
	if err := r.walk(start, box.end, func(child videoBox) error {
		switch child.kind {
		case "keys":
			return r.dateKeys(child, keys)
		case "ilst":
			lists = append(lists, child)
		}
		return nil
	}); err != nil {
		return err
	}
	for _, list := range lists {
		if err := r.walk(list.start, list.end, func(tag videoBox) error {
			if keys[binary.BigEndian.Uint32([]byte(tag.kind))] {
				return r.dateTag(tag, 2)
			}
			if tag.kind == "\xa9day" {
				return r.dateTag(tag, 1)
			}
			return nil
		}); err != nil {
			return err
		}
	}
	return nil
}

func (r *videoDateReader) dateKeys(box videoBox, keys map[uint32]bool) error {
	if box.end-box.start < 8 {
		return errVideoDateFormat
	}
	header, err := r.read(box.start, 8)
	if err != nil {
		return err
	}
	count := binary.BigEndian.Uint32(header[4:])
	if count > 1024 {
		return errVideoDateLimit
	}
	if binary.BigEndian.Uint32(header[:4]) != 0 {
		return errVideoDateFormat
	}
	at := box.start + 8
	for index := uint32(1); index <= count; index++ {
		if box.end-at < 8 {
			return errVideoDateFormat
		}
		header, err := r.read(at, 8)
		if err != nil {
			return err
		}
		size := int64(binary.BigEndian.Uint32(header[:4]))
		if size < 8 || size > box.end-at {
			return errVideoDateFormat
		}
		if string(header[4:]) == "mdta" && size-8 <= 4096 {
			key, err := r.read(at+8, size-8)
			if err != nil {
				return err
			}
			if string(key) == "com.apple.quicktime.creationdate" {
				keys[index] = true
			}
		}
		at += size
	}
	if at != box.end {
		return errVideoDateFormat
	}
	return nil
}

func (r *videoDateReader) dateTag(box videoBox, priority int) error {
	length := box.end - box.start
	if length < 8 {
		return nil
	}
	header, err := r.read(box.start, 8)
	if err != nil {
		return err
	}
	if string(header[4:]) != "data" {
		// Traditional QuickTime udta/©day: 16-bit text length and language.
		count := int64(binary.BigEndian.Uint16(header[:2]))
		if box.kind != "\xa9day" || count <= 0 || count > 4096 || count > length-4 {
			return nil
		}
		data, err := r.read(box.start+4, count)
		if err != nil {
			return err
		}
		return r.useDate(data, priority)
	}
	return r.walk(box.start, box.end, func(data videoBox) error {
		if data.kind != "data" {
			return nil
		}
		if data.end-data.start < 8 {
			return errVideoDateFormat
		}
		if data.end-data.start > 4096+8 {
			return errVideoDateLimit
		}
		value, err := r.read(data.start, data.end-data.start)
		if err != nil {
			return err
		}
		if binary.BigEndian.Uint32(value[:4]) != 1 {
			return nil
		}
		return r.useDate(value[8:], priority)
	})
}

func (r *videoDateReader) useDate(data []byte, priority int) error {
	if !utf8.Valid(data) || priority < r.priority {
		return nil
	}
	date, ok := parseVideoOriginal(strings.TrimPrefix(string(data), "\ufeff"), r.location)
	if !ok {
		return nil
	}
	if priority == r.priority && !r.metadata.IsZero() && (!r.metadata.Equal(date) || r.metadata.Format("2006-01-02") != date.Format("2006-01-02")) {
		return errVideoDateFormat
	}
	r.metadata, r.priority = date, priority
	return nil
}

func parseVideoOriginal(value string, location *time.Location) (time.Time, bool) {
	value = strings.Trim(value, "\x00 \t\r\n")
	offset := ""
	if strings.HasSuffix(value, "Z") {
		value, offset = strings.TrimSuffix(value, "Z"), "+00:00"
	} else if index := strings.LastIndexAny(value, "+-"); index >= 19 {
		offset, value = value[index:], value[:index]
		if len(offset) == 5 {
			offset = offset[:3] + ":" + offset[3:]
		}
		if len(offset) != 6 || offset[3] != ':' {
			return time.Time{}, false
		}
		for _, index := range []int{1, 2, 4, 5} {
			if offset[index] < '0' || offset[index] > '9' {
				return time.Time{}, false
			}
		}
		if (offset[1]-'0')*10+offset[2]-'0' > 23 || (offset[4]-'0')*10+offset[5]-'0' > 59 {
			return time.Time{}, false
		}
	}
	value = strings.TrimSpace(value)
	for _, layout := range []string{"2006-01-02T15:04:05", "2006-01-02 15:04:05", "2006-01-02"} {
		text := value
		if offset != "" {
			layout += " -07:00"
			text += " " + offset
		}
		date, err := time.ParseInLocation(layout, text, location)
		if err == nil && date.Year() >= 1970 && date.Year() <= 9999 {
			return date, true
		}
	}
	return time.Time{}, false
}
