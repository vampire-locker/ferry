package transfer

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"ferry.local/engine/internal/i18n"
	"fmt"
	"io"
	"maps"
	"math"
	"os"
	"path/filepath"
	"slices"
)

// A checkpoint is trusted in-memory state from this helper, never parsed from
// a disk report or supplied paths. Cancellation still closes every descriptor.
type DownloadCheckpoint struct {
	job                   DownloadJob
	filesPath, reportPath string
	filesInfo, reportInfo os.FileInfo
	journalInfo           os.FileInfo
}

func (c *DownloadCheckpoint) ItemCount() int { return len(c.job.report.Items) }

func (j *DownloadJob) CancelForResume() (*DownloadCheckpoint, error) {
	if j.closed || j.files == nil || j.root == nil || j.journal == nil {
		return nil, j.Cancel()
	}
	filesInfo, fileErr := j.files.Stat(".")
	reportInfo, reportErr := j.root.Stat(".")
	journalInfo, journalErr := j.journal.Stat()
	targets := maps.Clone(j.resumeTargets)
	if targets == nil {
		targets = make(map[uint32]string)
	}
	for _, item := range j.report.Items {
		if !item.Entry.IsDirectory && item.State == "completed" {
			targets[item.Entry.ID] = item.Path
		}
	}
	if j.pending != nil && j.pending.targetReady && j.next < len(j.report.Items) {
		targets[j.report.Items[j.next].Entry.ID] = j.pending.target
		if j.RecoveryPath != "" {
			j.report.Items[j.next].RecoveryTarget = j.pending.target
		}
	}
	filesPath, reportPath := j.files.Name(), j.root.Name()
	if err := j.Cancel(); err != nil {
		return nil, err
	}
	if fileErr != nil || reportErr != nil || journalErr != nil || j.next >= len(j.report.Items) {
		return nil, nil
	}
	snapshot := *j
	snapshot.root, snapshot.files, snapshot.journal = nil, nil, nil
	snapshot.pending, snapshot.conflict, snapshot.conflictInfo = nil, nil, nil
	snapshot.verifyBuffer = nil
	snapshot.resumeTargets = targets
	return &DownloadCheckpoint{
		job: snapshot, filesPath: filesPath, reportPath: reportPath,
		filesInfo: filesInfo, reportInfo: reportInfo, journalInfo: journalInfo,
	}, nil
}

func reopenDownloadRoot(path string, original os.FileInfo) (*os.Root, error) {
	root, err := os.OpenRoot(path)
	if err != nil {
		return nil, err
	}
	info, err := root.Stat(".")
	if err != nil || !os.SameFile(original, info) {
		root.Close()
		return nil, errors.New(i18n.Text("原保存目录已变化，请重新选择文件并新建下载任务。"))
	}
	return root, nil
}

func (c *DownloadCheckpoint) Resume(ctx context.Context, engine *Engine) (_ *DownloadJob, resultErr error) {
	j := c.job
	j.engine = engine
	j.report.Items = slices.Clone(c.job.report.Items)
	j.monthDirectories = maps.Clone(c.job.monthDirectories)
	j.resumeTargets = maps.Clone(c.job.resumeTargets)
	j.next, j.completed, j.skipped, j.bytes, j.reusedBytes = 0, 0, 0, 0, 0
	j.closed, j.resuming, j.closeErr, j.stage = false, true, nil, ""
	j.fileChoice, j.filePolicy = "", ""
	j.report.State, j.report.Error, j.report.Finished = "running", "", ""
	var err error
	if j.files, err = reopenDownloadRoot(c.filesPath, c.filesInfo); err != nil {
		return nil, err
	}
	defer func() {
		if resultErr != nil {
			if j.journal != nil {
				j.journal.Close()
			}
			if j.root != nil {
				j.root.Close()
			}
			j.files.Close()
		}
	}()
	if j.root, err = reopenDownloadRoot(c.reportPath, c.reportInfo); err != nil {
		return nil, err
	}
	info, err := j.root.Lstat("任务记录.ndjson")
	if err != nil || !info.Mode().IsRegular() || !os.SameFile(c.journalInfo, info) {
		return nil, errors.New(i18n.Text("原任务记录已变化，无法继续此任务。"))
	}
	if j.journal, err = j.root.OpenFile("任务记录.ndjson", os.O_APPEND|os.O_RDWR, 0); err != nil {
		return nil, err
	}
	opened, err := j.journal.Stat()
	if err != nil || !os.SameFile(info, opened) {
		return nil, errors.New(i18n.Text("原任务记录已变化，无法继续此任务。"))
	}
	if j.RecoveryPath != "" {
		if err = lockDownloadJournal(j.journal); err != nil {
			return nil, err
		}
	}
	if j.replayJournal {
		if err = j.restoreJournal(ctx); err != nil {
			return nil, err
		}
		j.replayJournal = false
	}
	if j.recovering {
		j.recoveryResolved = make(map[int]bool)
		j.recoveryListings = make(map[string][]Entry)
		j.recoveryTargets = make(map[int]string)
		for index, item := range j.report.Items {
			if item.Entry.IsDirectory {
				continue
			}
			if item.RecoveryTarget != "" {
				j.recoveryTargets[index] = item.RecoveryTarget
			} else if item.State == "completed" || !archiveMedia(item.Entry, j.archivePhotosByMonth, j.archiveVideosByMonth) {
				j.recoveryTargets[index] = item.Path
			}
		}
		j.resumeTargets = make(map[uint32]string)
	}
	var needed, largest int64
	for _, item := range j.report.Items {
		if !item.Entry.IsDirectory && item.State != "completed" && item.State != "skipped" {
			needed += item.Entry.Size
			largest = max(largest, item.Entry.Size)
		}
	}
	if j.copyCommit {
		if largest > math.MaxInt64-needed {
			return nil, errors.New(i18n.Text("设备返回的文件大小无效"))
		}
		needed += largest
	}
	if err = ctx.Err(); err != nil {
		return nil, err
	}
	if err = engine.checkSpace(c.filesPath, needed); err != nil {
		return nil, err
	}
	if err = j.saveReport(); err != nil {
		return nil, err
	}
	engine.Emit(Event{Type: "progress", CurrentFile: i18n.Text("正在核验已完成文件…"), Total: j.count, TotalBytes: j.total, Output: j.Output, ReportPath: j.ReportPath})
	return &j, nil
}

// Each Step checks at most one file, so hashing a large backup never turns
// into a single unbounded request that starves browsing or safe cancellation.
func (j *DownloadJob) reuseCompleted(ctx context.Context, item *Item) (bool, error) {
	if item.State != "skipped" {
		current, err := j.engine.Device.Info(ctx, item.Entry.ID)
		if err != nil {
			return false, err
		}
		if current != item.Entry {
			return false, fmt.Errorf(i18n.Text("手机文件已变化，无法继续原任务：%s"), item.Entry.Name)
		}
	}
	if item.State != "completed" && item.State != "skipped" {
		return false, nil
	}
	if item.State == "completed" {
		if archiveMedia(item.Entry, j.archivePhotosByMonth, j.archiveVideosByMonth) {
			if err := ensureArchiveDirectory(j.files, filepath.Dir(item.Path)); err != nil {
				return false, err
			}
		}
		j.engine.Emit(Event{Type: "progress", CurrentFile: fmt.Sprintf(i18n.Text("正在核验：%s"), item.Path), Completed: j.completed, Total: j.count, Bytes: j.bytes, TotalBytes: j.total, Output: j.Output, ReusedBytes: j.reusedBytes, Skipped: j.skipped})
		valid, err := j.matchesCompletedFile(ctx, *item)
		if err != nil {
			return false, err
		}
		if !valid {
			item.State, item.Error = "pending", ""
			return false, nil
		}
	} else {
		j.skipped++
	}
	j.completed++
	j.bytes += item.Entry.Size
	j.reusedBytes += item.Entry.Size
	j.next++
	// The original completion/skip record is already durable. Verification
	// does not change it and must not add a disk sync per reused photo.
	j.engine.Emit(Event{Type: "progress", CurrentFile: item.Path, Completed: j.completed, Total: j.count, Bytes: j.bytes, TotalBytes: j.total, Output: j.Output, ReusedBytes: j.reusedBytes, Skipped: j.skipped})
	return true, nil
}

func (j *DownloadJob) matchesCompletedFile(ctx context.Context, item Item) (bool, error) {
	info, err := j.files.Lstat(item.Path)
	if os.IsNotExist(err) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if !info.Mode().IsRegular() || info.Size() != item.Entry.Size || item.SHA256 == "" {
		return false, nil
	}
	file, err := j.files.Open(item.Path)
	if err != nil {
		return false, err
	}
	defer file.Close()
	before, err := file.Stat()
	if err != nil || !os.SameFile(info, before) || !before.Mode().IsRegular() {
		return false, err
	}
	hash := sha256.New()
	if j.verifyBuffer == nil {
		j.verifyBuffer = make([]byte, 256*1024)
	}
	buffer := j.verifyBuffer
	for {
		if err := ctx.Err(); err != nil {
			return false, err
		}
		n, err := file.Read(buffer)
		if n > 0 {
			hash.Write(buffer[:n])
		}
		if err == io.EOF {
			break
		}
		if err != nil {
			return false, err
		}
	}
	after, err := file.Stat()
	if err != nil {
		return false, err
	}
	latest, err := j.files.Lstat(item.Path)
	if os.IsNotExist(err) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return os.SameFile(info, latest) && latest.Mode().IsRegular() && before.Size() == after.Size() &&
		before.ModTime().Equal(after.ModTime()) && hex.EncodeToString(hash.Sum(nil)) == item.SHA256, nil
}
