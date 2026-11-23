package transfer

import (
	"context"
	"errors"
	"ferry.local/engine/internal/i18n"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

var ErrThumbnailUnavailable = errors.New(i18n.Text("设备未提供缩略图"))

// A complete, synchronized MTP response rejected this object. Unlike a USB or
// session error, this does not require abandoning other objects in the batch.
var ErrMediaObjectUnavailable = errors.New(i18n.Text("无法读取该文件"))

const MaxThumbnailBytes = 16 * 1024 * 1024
const MaxThumbnailBatch = 24

func MediaKind(entry Entry) string {
	if entry.IsDirectory {
		return ""
	}
	switch strings.ToLower(filepath.Ext(entry.Name)) {
	// Keep these extensions aligned with RemoteEntry in FerryCore/Models.swift.
	case ".jpg", ".jpeg", ".jpe", ".jfif", ".pjpeg", ".pjp", ".png", ".apng",
		".heic", ".heif", ".heics", ".heifs", ".hif", ".avif", ".avifs", ".webp", ".gif",
		".bmp", ".dib", ".tif", ".tiff", ".jp2", ".j2k", ".jpf", ".jpx", ".jxl",
		".svg", ".svgz", ".ico", ".icns", ".psd", ".psb",
		".dng", ".cr2", ".cr3", ".crw", ".nef", ".nrw", ".arw", ".srf", ".sr2",
		".orf", ".rw2", ".rwl", ".raf", ".srw", ".pef", ".x3f", ".erf", ".kdc", ".dcr",
		".mos", ".mrw", ".3fr", ".fff", ".iiq":
		return "image"
	case ".mp4", ".mov", ".m4v", ".mkv", ".webm", ".avi", ".3gp", ".3g2", ".3gpp", ".3gpp2",
		".mpg", ".mpeg", ".mpe", ".m1v", ".m2v", ".mpv", ".mts", ".m2ts", ".m2t", ".ts",
		".mxf", ".flv", ".f4v", ".vob", ".ogv", ".wmv", ".asf", ".rm", ".rmvb",
		".divx", ".xvid", ".nsv", ".h264", ".264", ".h265", ".265", ".hevc":
		return "video"
	}
	return ""
}

// PreviewKind includes explicitly requested audio/documents; MediaKind remains
// image/video only so grid browsing cannot download whole documents or audio.
func PreviewKind(entry Entry) string {
	if entry.IsDirectory {
		return ""
	}
	if kind := MediaKind(entry); kind != "" {
		return kind
	}
	switch strings.ToLower(filepath.Ext(entry.Name)) {
	case ".mp3", ".m4a", ".m4b", ".m4r", ".aac", ".wav", ".wave", ".aif", ".aiff", ".aifc",
		".flac", ".alac", ".ogg", ".oga", ".opus", ".amr", ".wma", ".caf":
		return "audio"
	case ".txt", ".text", ".md", ".markdown", ".csv", ".tsv", ".log", ".json", ".xml", ".yaml", ".yml",
		".pdf", ".rtf", ".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx", ".odt", ".ods", ".odp":
		return "document"
	}
	return ""
}

func (e *Engine) previewEntry(ctx context.Context, req Request, id uint32) (Entry, error) {
	entry, err := e.Device.Info(ctx, id)
	if err != nil {
		return Entry{}, err
	}
	if entry.StorageID != req.StorageID {
		return Entry{}, errors.New(i18n.Text("文件不属于当前存储，请刷新后重试"))
	}
	if err := ValidName(entry.Name); err != nil {
		return Entry{}, err
	}
	if PreviewKind(entry) == "" {
		return Entry{}, errors.New(i18n.Text("此格式暂不支持预览，可下载后打开"))
	}
	if entry.Size < 0 {
		return Entry{}, errors.New(i18n.Text("设备返回的文件大小无效"))
	}
	if !req.ShowHiddenFiles && strings.HasPrefix(entry.Name, ".") {
		return Entry{}, errors.New(i18n.Text("该项目已隐藏"))
	}
	return entry, nil
}

// Preview stages exactly one supported file using the download writer's capacity,
// length, cancellation and no-replacement guarantees. No phone writes occur.
func (e *Engine) Preview(ctx context.Context, req Request) (string, error) {
	if len(req.ObjectIDs) != 1 {
		return "", errors.New(i18n.Text("请每次选择一个文件预览"))
	}
	entry, err := e.previewEntry(ctx, req, req.ObjectIDs[0])
	if err != nil {
		return "", err
	}
	if err := e.checkSpace(req.Destination, entry.Size); err != nil {
		return "", err
	}
	dir, err := os.MkdirTemp(req.Destination, "media-")
	if err != nil {
		return "", err
	}
	keep := false
	defer func() {
		if !keep {
			os.RemoveAll(dir)
		}
	}()
	root, err := os.OpenRoot(dir)
	if err != nil {
		return "", err
	}
	defer root.Close()
	item := Item{Entry: entry, Path: entry.Name}
	_, err = e.writeFile(ctx, root, dir, item, func(written int64) {
		e.Emit(Event{Type: "progress", Bytes: written, TotalBytes: entry.Size})
	})
	if err != nil {
		return "", err
	}
	keep = true
	return filepath.Join(dir, entry.Name), nil
}

type boundedMediaWriter struct {
	ctx     context.Context
	w       io.Writer
	written int64
	limit   int64
}

func (w *boundedMediaWriter) Write(data []byte) (int, error) {
	if err := w.ctx.Err(); err != nil {
		return 0, err
	}
	if int64(len(data)) > w.limit-w.written {
		return 0, errors.New(i18n.Text("缩略图超过大小限制"))
	}
	n, err := w.w.Write(data)
	w.written += int64(n)
	return n, err
}

// Thumbnails is a bounded batch for visible cells, never a recursive download.
func (e *Engine) Thumbnails(ctx context.Context, req Request) error {
	if len(req.ObjectIDs) == 0 || len(req.ObjectIDs) > MaxThumbnailBatch {
		return errors.New(i18n.Text("缩略图请求数量无效"))
	}
	if err := e.checkSpace(req.Destination, MaxThumbnailBytes); err != nil {
		return err
	}
	for _, id := range req.ObjectIDs {
		if err := ctx.Err(); err != nil {
			return err
		}
		entry, err := e.previewEntry(ctx, req, id)
		if err != nil {
			if errors.Is(err, ErrMediaObjectUnavailable) {
				e.Emit(Event{Type: "thumbnail", ObjectID: id, State: "unavailable", Message: err.Error()})
				continue
			}
			return err
		}
		if MediaKind(entry) == "" {
			e.Emit(Event{Type: "thumbnail", ObjectID: id, State: "unavailable", Message: i18n.Text("此文件不提供图片或视频缩略图")})
			continue
		}
		path, err := e.thumbnail(ctx, req.Destination, entry)
		if errors.Is(err, ErrThumbnailUnavailable) || errors.Is(err, ErrMediaObjectUnavailable) {
			e.Emit(Event{Type: "thumbnail", ObjectID: id, State: "unavailable", Message: err.Error()})
			continue
		}
		if err != nil {
			return fmt.Errorf(i18n.Text("读取 %s 的缩略图失败：%w"), entry.Name, err)
		}
		e.Emit(Event{Type: "thumbnail", ObjectID: id, Output: path, State: "completed"})
	}
	return nil
}

func (e *Engine) thumbnail(ctx context.Context, destination string, entry Entry) (string, error) {
	f, err := os.CreateTemp(destination, "thumb-*")
	if err != nil {
		return "", err
	}
	keep := false
	defer func() {
		f.Close()
		if !keep {
			os.Remove(f.Name())
		}
	}()
	writer := &boundedMediaWriter{ctx: ctx, w: f, limit: MaxThumbnailBytes}
	err = ErrThumbnailUnavailable
	if device, ok := e.Device.(ThumbnailDevice); ok {
		err = device.Thumbnail(ctx, entry.ID, writer)
	}
	if stopped := ctx.Err(); stopped != nil {
		return "", stopped
	}
	if err == nil && writer.written == 0 {
		err = ErrThumbnailUnavailable
	}
	if errors.Is(err, ErrThumbnailUnavailable) {
		// Never auto-download whole videos or large images for a grid cell.
		if MediaKind(entry) != "image" || entry.Size > MaxThumbnailBytes {
			return "", ErrThumbnailUnavailable
		}
		if err := f.Truncate(0); err != nil {
			return "", err
		}
		if _, err := f.Seek(0, io.SeekStart); err != nil {
			return "", err
		}
		writer.written = 0
		writer.limit = entry.Size
		err = e.Device.Read(ctx, entry.ID, writer)
		if stopped := ctx.Err(); stopped != nil {
			return "", stopped
		}
		if err == nil && writer.written != entry.Size {
			err = fmt.Errorf(i18n.Text("%w：缩略图源文件长度不符"), ErrMediaObjectUnavailable)
		}
	}
	if err != nil {
		return "", err
	}
	if writer.written == 0 {
		return "", ErrThumbnailUnavailable
	}
	if err := f.Close(); err != nil {
		return "", err
	}
	keep = true
	return f.Name(), nil
}
