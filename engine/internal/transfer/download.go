package transfer

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"ferry.local/engine/internal/i18n"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

const ReserveBytes = 64 * 1024 * 1024
const maxEntries = 1000000

type Engine struct {
	Device   Device
	Emit     func(Event)
	Storages []Storage
	// Available is injectable to exercise low-space failures without filling a disk.
	Available func(string) (uint64, error)
}

func FreeSpace(path string) (uint64, error) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(path, &st); err != nil {
		return 0, err
	}
	return uint64(st.Bavail) * uint64(st.Bsize), nil
}

func (e *Engine) checkSpace(path string, needed int64) error {
	available := e.Available
	if available == nil {
		available = FreeSpace
	}
	free, err := available(path)
	if err != nil {
		return fmt.Errorf(i18n.Text("无法检查目标磁盘空间：%w"), err)
	}
	if needed < 0 || uint64(needed) > math.MaxUint64-ReserveBytes || free < uint64(needed)+ReserveBytes {
		return fmt.Errorf(i18n.Text("磁盘可用空间不足，需预留 64 MiB（剩余 %d 字节，需要 %d 字节）"), free, needed)
	}
	return nil
}

func ValidName(name string) error {
	if name == "" || name == "." || name == ".." || strings.ContainsAny(name, "/\\:\x00\r\n") || len(name) > 240 {
		return fmt.Errorf(i18n.Text("无法安全保存文件名 %q"), name)
	}
	return nil
}

func (e *Engine) Plan(ctx context.Context, storage uint32, ids []uint32, showHiddenFiles bool) ([]Item, int64, error) {
	return e.plan(ctx, storage, ids, showHiddenFiles, false)
}

func (e *Engine) plan(ctx context.Context, storage uint32, ids []uint32, showHiddenFiles, keepBoth bool) ([]Item, int64, error) {
	if len(ids) == 0 {
		return nil, 0, errors.New(i18n.Text("请先选择文件或文件夹"))
	}
	var items []Item
	var total int64
	seen := make(map[uint32]bool)
	paths := make(map[string]bool)
	var visit func(Entry, string, int) error
	visit = func(entry Entry, parent string, depth int) error {
		if err := ctx.Err(); err != nil {
			return err
		}
		if depth > 128 || len(items) >= maxEntries {
			return errors.New(i18n.Text("目录层级或文件数量超过安全限制"))
		}
		if seen[entry.ID] {
			return fmt.Errorf(i18n.Text("重复或循环的设备对象：%s"), entry.Name)
		}
		seen[entry.ID] = true
		if entry.StorageID != storage {
			return errors.New(i18n.Text("文件不属于当前存储，请刷新手机后重试"))
		}
		if err := ValidName(entry.Name); err != nil {
			return err
		}
		if !showHiddenFiles && strings.HasPrefix(entry.Name, ".") {
			return nil
		}
		relative := filepath.Join(parent, entry.Name)
		key := strings.ToLower(relative)
		if paths[key] && !keepBoth {
			return fmt.Errorf(i18n.Text("存在同名或仅大小写不同的目标：%s；请分开下载"), relative)
		}
		paths[key] = true
		items = append(items, Item{Entry: entry, Path: relative, State: "pending"})
		if len(items)%100 == 0 {
			e.Emit(Event{Type: "status", Message: fmt.Sprintf(i18n.Text("正在检查目录，已发现 %d 项…"), len(items))})
		}
		if entry.IsDirectory {
			children, err := e.Device.List(ctx, storage, entry.ID)
			if err != nil {
				return err
			}
			for _, child := range children {
				if err := visit(child, relative, depth+1); err != nil {
					return err
				}
			}
		} else {
			if entry.Size < 0 || entry.Size > math.MaxInt64-total {
				return errors.New(i18n.Text("设备返回的文件大小无效"))
			}
			total += entry.Size
		}
		return nil
	}
	for _, id := range ids {
		if seen[id] {
			continue
		}
		entry, err := e.Device.Info(ctx, id)
		if err != nil {
			return nil, 0, err
		}
		if err := visit(entry, "", 0); err != nil {
			return nil, 0, err
		}
	}
	if len(items) == 0 {
		return nil, 0, errors.New(i18n.Text("所选项目均已隐藏，请开启显示隐藏文件后重试"))
	}
	return items, total, nil
}

// Every task keeps its own report. Existing destination files are never replaced.
// Legacy clients still run the same prepared job to completion in one request.
func (e *Engine) Download(ctx context.Context, req Request, deviceName string) (string, error) {
	if req.PromptConflicts {
		return "", errors.New(i18n.Text("冲突询问仅支持协作下载"))
	}
	job, output, err := e.PrepareDownload(ctx, req, deviceName)
	if err != nil {
		return output, err
	}
	defer job.Cancel()
	for {
		done, err := job.Step(ctx)
		if err != nil || done {
			return output, err
		}
	}
}

type guardedWriter struct {
	ctx      context.Context
	writer   io.Writer
	written  int64
	expected int64
	last     time.Time
	check    func(int64) error
	progress func(int64)
}

func (w *guardedWriter) Write(data []byte) (int, error) {
	if err := w.ctx.Err(); err != nil {
		return 0, err
	}
	if int64(len(data)) > w.expected-w.written {
		return 0, errors.New(i18n.Text("设备返回的数据超过声明大小"))
	}
	if w.last.IsZero() || time.Since(w.last) > 250*time.Millisecond {
		if err := w.check(w.expected - w.written); err != nil {
			return 0, err
		}
		w.progress(w.written)
		w.last = time.Now()
	}
	n, err := w.writer.Write(data)
	w.written += int64(n)
	return n, err
}

func (e *Engine) writeFile(ctx context.Context, root *os.Root, output string, item Item, progress func(int64)) (string, error) {
	hash, _, err := e.writeFileTo(ctx, root, output, item, fmt.Sprintf(".ferry-%d.part", item.Entry.ID), false, false, progress, nil)
	return hash, err
}

func (e *Engine) stageFile(ctx context.Context, root *os.Root, output string, item Item, temp string, progress func(int64)) (string, error) {
	if err := e.checkSpace(output, item.Entry.Size); err != nil {
		return "", err
	}
	// Temp path is private to this task; create exclusively and commit without replacement.
	f, err := root.OpenFile(temp, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return "", err
	}
	staged := false
	defer func() {
		if !staged {
			root.Remove(temp)
		}
	}()
	defer f.Close()
	hash := sha256.New()
	writer := &guardedWriter{ctx: ctx, writer: io.MultiWriter(f, hash), expected: item.Entry.Size, progress: progress,
		check: func(needed int64) error { return e.checkSpace(output, needed) }}
	if err = e.Device.Read(ctx, item.Entry.ID, writer); err != nil {
		return "", err
	}
	if err = ctx.Err(); err != nil {
		return "", err
	}
	if writer.written != item.Entry.Size {
		return "", fmt.Errorf(i18n.Text("文件长度不符，预期 %d，实际 %d"), item.Entry.Size, writer.written)
	}
	if err = f.Sync(); err != nil {
		return "", err
	}
	if err = f.Close(); err != nil {
		return "", err
	}
	if item.Entry.Modified > 0 {
		date := time.Unix(item.Entry.Modified, 0)
		if err = root.Chtimes(temp, date, date); err != nil {
			return "", err
		}
	}
	if err = ctx.Err(); err != nil {
		return "", err
	}
	staged = true
	return hex.EncodeToString(hash.Sum(nil)), nil
}

func (e *Engine) writeFileTo(ctx context.Context, root *os.Root, output string, item Item, temp string, copyCommit, keepBoth bool, progress func(int64), destination func(string) (string, error)) (string, string, error) {
	digest, err := e.stageFile(ctx, root, output, item, temp, progress)
	if err != nil {
		return "", "", err
	}
	defer root.Remove(temp)
	target := item.Path
	if destination != nil {
		target, err = destination(temp)
		if err != nil {
			return "", "", err
		}
	}
	path, err := e.publishFile(ctx, root, output, item, temp, digest, target, copyCommit, keepBoth)
	return digest, path, err
}

func (e *Engine) publishFile(ctx context.Context, root *os.Root, output string, item Item, temp, digest, target string, copyCommit, keepBoth bool) (string, error) {
	var err error
	for number := 0; number < maxEntries; number++ {
		if err := ctx.Err(); err != nil {
			return "", err
		}
		path := numberedPath(target, number, false)
		if copyCommit {
			err = e.copyExclusive(ctx, root, output, temp, path, item.Entry, digest)
		} else {
			err = commitFile(root, temp, path)
		}
		if err == nil {
			return path, nil
		}
		if !keepBoth || !errors.Is(err, os.ErrExist) {
			return "", fmt.Errorf(i18n.Text("提交文件失败（不会覆盖已有文件）：%w"), err)
		}
	}
	return "", errors.New(i18n.Text("同名项目过多，请选择其他下载位置"))
}
