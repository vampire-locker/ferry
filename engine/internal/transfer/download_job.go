package transfer

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"ferry.local/engine/internal/i18n"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

// DownloadJob holds a validated plan and its private output resources between
// serial requests. Step yields only between complete files; no device call or
// partial file remains in flight while a browser request uses the same session.
type DownloadJob struct {
	Output               string
	ReportPath           string
	RecoveryPath         string
	StorageID            uint32
	engine               *Engine
	root                 *os.Root
	files                *os.Root
	journal              *os.File
	stage                string
	keepBoth             bool
	copyCommit           bool
	usePhotoCreationDate bool
	archivePhotosByMonth bool
	archiveVideosByMonth bool
	promptConflicts      bool
	pending              *pendingDownloadFile
	conflict             *DownloadConflict
	conflictInfo         os.FileInfo
	fileChoice           string
	filePolicy           string
	monthDirectories     map[string]string
	skipped              int
	report               Report
	next                 int
	count                int
	completed            int
	total                int64
	bytes                int64
	closed               bool
	closeErr             error
	resuming             bool
	resumeTargets        map[uint32]string
	reusedBytes          int64
	verifyBuffer         []byte
	recovering           bool
	recoverySources      [][]string
	recoveryTargets      map[int]string
	recoveryResolved     map[int]bool
	recoveryListings     map[string][]Entry
	replayJournal        bool
}

// PrepareDownload completes metadata, path and space validation before any
// file content is read. The returned output also identifies setup failures.
func (e *Engine) PrepareDownload(ctx context.Context, req Request, deviceName string) (job *DownloadJob, output string, resultErr error) {
	e.Emit(Event{Type: "status", Message: i18n.Text("正在检查文件和目标空间…")})
	destination, err := filepath.Abs(req.Destination)
	if err != nil || req.Destination == "" {
		return nil, "", errors.New(i18n.Text("请选择下载位置"))
	}
	stat, err := os.Stat(destination)
	if err != nil || !stat.IsDir() {
		return nil, "", errors.New(i18n.Text("下载位置不存在或不是文件夹"))
	}
	if req.DownloadLayout != "" && req.DownloadLayout != "direct" && req.DownloadLayout != "folder" {
		return nil, "", errors.New(i18n.Text("下载保存方式无效"))
	}
	keepBoth := req.DownloadLayout != "" || req.ArchivePhotosByMonth || req.ArchiveVideosByMonth
	items, total, err := e.plan(ctx, req.StorageID, req.ObjectIDs, req.ShowHiddenFiles, keepBoth)
	if err != nil {
		return nil, "", err
	}
	if req.ArchivePhotosByMonth || req.ArchiveVideosByMonth {
		items = monthArchivePlan(items, req.ArchivePhotosByMonth, req.ArchiveVideosByMonth)
	}
	if err = e.checkSpace(destination, total); err != nil {
		return nil, "", err
	}
	if err = ctx.Err(); err != nil {
		return nil, "", err
	}
	output = destination
	if req.DownloadLayout != "direct" {
		output, err = os.MkdirTemp(destination, "渡舟-"+time.Now().Format("20060102-150405")+"-")
		if err != nil {
			return nil, "", err
		}
	}
	prepared := &DownloadJob{
		Output: output, StorageID: req.StorageID, engine: e, total: total, keepBoth: keepBoth,
		usePhotoCreationDate: req.UsePhotoCreationDate,
		archivePhotosByMonth: req.ArchivePhotosByMonth,
		archiveVideosByMonth: req.ArchiveVideosByMonth,
		promptConflicts:      req.PromptConflicts, monthDirectories: make(map[string]string),
		report: Report{Version: 1, Started: time.Now().Format(time.RFC3339), Device: deviceName, State: "running", Items: items},
	}
	defer func() {
		if resultErr != nil {
			resultErr = errors.Join(resultErr, prepared.finish(resultErr))
		}
	}()
	reportDirectory := output
	filesDirectory := output
	if req.DownloadLayout != "" {
		base := req.ReportDirectory
		if base == "" {
			base, err = os.UserConfigDir()
			if err != nil {
				return nil, output, err
			}
			base = filepath.Join(base, "Ferry", "Transfers")
		}
		if err := os.MkdirAll(base, 0700); err != nil {
			return nil, output, err
		}
		reportDirectory, err = os.MkdirTemp(base, "transfer-")
		if err != nil {
			return nil, output, err
		}
	} else {
		filesDirectory = filepath.Join(output, "files")
		if err := os.Mkdir(filesDirectory, 0700); err != nil {
			return nil, output, err
		}
	}
	prepared.ReportPath = filepath.Join(reportDirectory, "传输报告.json")
	prepared.report.Output = output
	if prepared.root, err = os.OpenRoot(reportDirectory); err != nil {
		return nil, output, err
	}
	if prepared.files, err = os.OpenRoot(filesDirectory); err != nil {
		return nil, output, err
	}
	e.Emit(Event{Type: "status", Output: output, ReportPath: prepared.ReportPath})
	stage := ".ferry-download-" + rand.Text()
	if err = prepared.files.Mkdir(stage, 0700); err != nil {
		return nil, output, err
	}
	prepared.stage = stage
	probe, err := prepared.files.OpenRoot(stage)
	if err != nil {
		return nil, output, err
	}
	err = checkCommitSupport(probe)
	probe.Close()
	cleanupErr := prepared.files.RemoveAll(stage)
	if cleanupErr == nil {
		prepared.stage = ""
	}
	if errors.Is(err, syscall.ENOTSUP) || errors.Is(err, syscall.ENOSYS) || errors.Is(err, syscall.EINVAL) {
		prepared.copyCommit = true
		var largest int64
		for _, item := range items {
			if item.Entry.Size > largest {
				largest = item.Entry.Size
			}
		}
		if largest > math.MaxInt64-total {
			return nil, output, errors.New(i18n.Text("设备返回的文件大小无效"))
		}
		err = e.checkSpace(filesDirectory, total+largest)
	}
	err = errors.Join(err, cleanupErr)
	if err != nil {
		return nil, output, fmt.Errorf(i18n.Text("下载位置无法安全保存文件，请选择其他位置：%w"), err)
	}
	if err = prepared.saveReport(); err != nil {
		return nil, output, err
	}
	if prepared.journal, err = prepared.root.OpenFile("任务记录.ndjson", os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600); err != nil {
		return nil, output, err
	}
	if req.DurableRecovery {
		if err = lockDownloadJournal(prepared.journal); err != nil {
			return nil, output, err
		}
		if err = prepared.prepareRecovery(ctx, req); err != nil {
			return nil, output, err
		}
	}
	for _, item := range items {
		if !item.Entry.IsDirectory {
			prepared.count++
		}
	}
	e.Emit(Event{Type: "progress", Total: prepared.count, TotalBytes: total, Output: output, ReportPath: prepared.ReportPath})
	return prepared, output, nil
}

func (j *DownloadJob) saveReport() error {
	data, err := json.MarshalIndent(j.report, "", "  ")
	if err != nil {
		return err
	}
	f, err := j.root.OpenFile("report.tmp", os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0600)
	if err != nil {
		return err
	}
	_, writeErr := f.Write(data)
	syncErr := f.Sync()
	closeErr := f.Close()
	if err := errors.Join(writeErr, syncErr, closeErr); err != nil {
		return err
	}
	return j.root.Rename("report.tmp", "传输报告.json")
}

func (j *DownloadJob) record(item Item) error {
	if err := json.NewEncoder(j.journal).Encode(item); err != nil {
		return err
	}
	return j.journal.Sync()
}

// Step copies at most one file and any adjacent directories, preserving the
// output location, progress totals and report across browser requests.
// Completion and all failure paths finalize the report and close resources.
func (j *DownloadJob) Step(ctx context.Context) (done bool, resultErr error) {
	if j.closed {
		return true, errors.New(i18n.Text("下载任务已结束，请新建任务。"))
	}
	defer func() {
		if done || resultErr != nil {
			resultErr = errors.Join(resultErr, j.finish(resultErr))
		}
	}()
	copiedFile := false
	for j.next < len(j.report.Items) {
		if err := ctx.Err(); err != nil {
			return false, err
		}
		item := &j.report.Items[j.next]
		if j.recovering && item.State != "skipped" {
			if err := j.relinkSource(ctx, j.next); err != nil {
				return false, err
			}
		}
		if item.Entry.IsDirectory {
			if j.resuming && item.State == "completed" {
				if err := ensureArchiveDirectory(j.files, item.Path); err != nil {
					return false, err
				}
				j.next++
				continue
			}
			// Fail safely on normalized-name collisions as in the legacy path.
			original := item.Path
			var err error
			for number := 0; number < maxEntries; number++ {
				item.Path = numberedPath(original, number, true)
				err = j.files.Mkdir(item.Path, 0700)
				if err == nil || !j.keepBoth || !errors.Is(err, os.ErrExist) {
					break
				}
			}
			if err != nil {
				item.State, item.Error = "failed", err.Error()
				return false, err
			}
			if item.Path != original {
				for index := j.next + 1; index < len(j.report.Items); index++ {
					child := &j.report.Items[index]
					if !strings.HasPrefix(child.Path, original+string(filepath.Separator)) {
						break
					}
					child.Path = item.Path + strings.TrimPrefix(child.Path, original)
				}
			}
			item.State = "completed"
			if j.RecoveryPath != "" {
				if err := j.record(*item); err != nil {
					return false, err
				}
			}
			j.next++
			continue
		}
		if copiedFile {
			return false, nil
		}
		if j.resuming {
			reused, err := j.reuseCompleted(ctx, item)
			if err != nil {
				return false, err
			}
			if reused {
				copiedFile = true
				continue
			}
		}
		item.State = "running"
		var err error
		if j.pending == nil {
			err = j.record(*item)
		}
		if err == nil {
			err = j.preparePending(ctx, item)
		}
		if err == nil {
			err = j.publishPending(ctx, item)
		}
		if errors.Is(err, errAwaitingDecision) {
			item.State = "waiting"
			if j.RecoveryPath != "" {
				if j.pending.targetReady {
					item.RecoveryTarget = j.pending.target
				}
				if err := j.record(*item); err != nil {
					return false, err
				}
			}
			return false, nil
		}
		if err != nil {
			item.State, item.Error = "failed", err.Error()
			if errors.Is(err, context.Canceled) {
				item.State = "cancelled"
			}
			return false, fmt.Errorf(i18n.Text("%s：%w"), item.Path, err)
		}
		j.completed++
		j.bytes += item.Entry.Size
		if item.State == "skipped" && item.SHA256 == "" {
			// Logical progress still advances; unread bytes must not inflate speed.
			j.reusedBytes += item.Entry.Size
		}
		j.next++
		copiedFile = true
		if err := j.record(*item); err != nil {
			return false, err
		}
		j.engine.Emit(Event{Type: "progress", CurrentFile: item.Path, Completed: j.completed, Total: j.count, Bytes: j.bytes, TotalBytes: j.total, Output: j.Output, Skipped: j.skipped, ReusedBytes: j.reusedBytes})
	}
	return true, nil
}

// Cancel is idempotent. It is also the cleanup path for helper EOF, device
// errors and cancellation between Step requests. Completed files are retained.
func (j *DownloadJob) Cancel() error { return j.finish(context.Canceled) }

// Abort records session failures that occur while browsing between files.
func (j *DownloadJob) Abort(err error) error { return j.finish(err) }

func (j *DownloadJob) finish(resultErr error) error {
	if j.closed {
		return j.closeErr
	}
	j.closed = true
	if j.pending != nil && resultErr != nil && j.next < len(j.report.Items) {
		item := &j.report.Items[j.next]
		item.State, item.Error = "failed", resultErr.Error()
		if errors.Is(resultErr, context.Canceled) {
			item.State = "cancelled"
		}
	}
	j.conflict, j.conflictInfo = nil, nil
	if j.files != nil && j.stage != "" {
		j.closeErr = j.files.RemoveAll(j.stage)
		if resultErr == nil {
			resultErr = j.closeErr
		}
	}
	j.report.Finished = time.Now().Format(time.RFC3339)
	j.report.State = "completed"
	if resultErr != nil {
		j.report.State, j.report.Error = "failed", resultErr.Error()
		if errors.Is(resultErr, context.Canceled) {
			j.report.State = "cancelled"
		}
	}
	if j.root != nil {
		if err := j.saveReport(); err != nil {
			j.closeErr = errors.Join(j.closeErr, fmt.Errorf(i18n.Text("保存传输报告失败：%w"), err))
		}
	}
	if j.journal != nil {
		j.closeErr = errors.Join(j.closeErr, j.journal.Close())
	}
	if j.files != nil {
		j.closeErr = errors.Join(j.closeErr, j.files.Close())
	}
	if j.root != nil {
		j.closeErr = errors.Join(j.closeErr, j.root.Close())
	}
	return j.closeErr
}
