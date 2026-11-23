package device

import (
	"bytes"
	"context"
	_ "embed"
	"ferry.local/engine/internal/i18n"
	"ferry.local/engine/internal/transfer"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"io"
	"strings"
	"time"
)

// Demo contains only synthetic text and media; it never opens a USB device.
type Demo struct{}

//go:embed fixtures/demo.mp4
var demoVideo []byte

var demoImage = func() []byte {
	image := image.NewRGBA(image.Rect(0, 0, 480, 270))
	for y := 0; y < 270; y++ {
		for x := 0; x < 480; x++ {
			c := color.RGBA{10, uint8(55 + y/4), uint8(70 + x/8), 255}
			if (x-340)*(x-340)+(y-70)*(y-70) < 30*30 {
				c = color.RGBA{255, 190, 87, 255}
			}
			if y > 250-x && y > x-30 {
				c = color.RGBA{35, 150, 145, 255}
			}
			image.SetRGBA(x, y, c)
		}
	}
	var buffer bytes.Buffer
	png.Encode(&buffer, image)
	return buffer.Bytes()
}()

func (d *Demo) Connect(context.Context) (string, []transfer.Storage, error) {
	return i18n.Text("演示 Android 手机"), []transfer.Storage{{ID: 1, Name: i18n.Text("内部存储（演示）"), Capacity: 128 << 30, Free: 64 << 30}}, nil
}
func demoContent(id uint32) string {
	return strings.Repeat(fmt.Sprintf("这是渡舟的演示文件 %d，用于验证下载流程。\n", id), 2048)
}
func demoBytes(id uint32) []byte {
	if id == 111 {
		return demoImage
	}
	if id == 112 {
		return demoVideo
	}
	return []byte(demoContent(id))
}
func demoEntry(id uint32) transfer.Entry {
	e := transfer.Entry{ID: id, StorageID: 1, Modified: 1760000000}
	switch id {
	case 10:
		e.Name = "旅行记录"
		e.IsDirectory = true
	case 20:
		e.Name = "工作资料"
		e.IsDirectory = true
	default:
		e.Name = fmt.Sprintf("记录-%02d.txt", id)
		if id == 111 {
			e.Name = "演示照片.png"
		}
		if id == 112 {
			e.Name = "演示视频.mp4"
		}
		e.Size = int64(len(demoBytes(id)))
	}
	return e
}
func (d *Demo) Info(ctx context.Context, id uint32) (transfer.Entry, error) {
	if err := ctx.Err(); err != nil {
		return transfer.Entry{}, err
	}
	if id == 10 || id == 20 || id == 30 || (id >= 101 && id <= 112) || (id >= 201 && id <= 205) {
		return demoEntry(id), nil
	}
	return transfer.Entry{}, fmt.Errorf(i18n.Text("演示对象不存在：%d"), id)
}
func (d *Demo) List(ctx context.Context, storage, parent uint32) ([]transfer.Entry, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if storage != 1 {
		return nil, fmt.Errorf("%s", i18n.Text("演示存储不存在"))
	}
	var ids []uint32
	switch parent {
	case 0:
		ids = []uint32{10, 20, 30}
	case 10:
		for i := uint32(101); i <= 112; i++ {
			ids = append(ids, i)
		}
	case 20:
		for i := uint32(201); i <= 205; i++ {
			ids = append(ids, i)
		}
	default:
		return nil, fmt.Errorf("%s", i18n.Text("演示目录不存在"))
	}
	entries := make([]transfer.Entry, 0, len(ids))
	for _, id := range ids {
		entries = append(entries, demoEntry(id))
	}
	return entries, nil
}
func (d *Demo) Read(ctx context.Context, id uint32, w io.Writer) error {
	data := demoBytes(id)
	for len(data) > 0 {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(15 * time.Millisecond):
		}
		n := min(8192, len(data))
		if _, err := w.Write(data[:n]); err != nil {
			return err
		}
		data = data[n:]
	}
	return nil
}
func (d *Demo) Close() {}

func (d *Demo) Identity() string { return "ferry-demo-v1" }

func (d *Demo) Thumbnail(ctx context.Context, id uint32, w io.Writer) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if id != 111 && id != 112 {
		return transfer.ErrThumbnailUnavailable
	}
	_, err := w.Write(demoImage)
	return err
}

func (d *Demo) ListForBrowse(ctx context.Context, storage, parent uint32, includeSizes bool) ([]transfer.Entry, error) {
	entries, err := d.List(ctx, storage, parent)
	if !includeSizes {
		for i := range entries {
			if !entries[i].IsDirectory {
				entries[i].Size = -1
			}
		}
	}
	return entries, err
}

func (d *Demo) Sizes(ctx context.Context, storage, parent uint32) ([]transfer.ObjectSize, error) {
	entries, err := d.List(ctx, storage, parent)
	if err != nil {
		return nil, err
	}
	sizes := make([]transfer.ObjectSize, 0, len(entries))
	for _, entry := range entries {
		sizes = append(sizes, transfer.ObjectSize{ID: entry.ID, Size: entry.Size})
	}
	return sizes, nil
}
