package transfer

import (
	"context"
	"crypto/rand"
	"errors"
	"ferry.local/engine/internal/i18n"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"time"
)

var errAwaitingDecision = errors.New("download is awaiting a conflict decision")

type pendingDownloadFile struct {
	temp          string
	hash          string
	target        string
	targetReady   bool
	capture       time.Time
	captureSource string
	monthKey      string
	replaceInfo   os.FileInfo
}

func (j *DownloadJob) Conflict() *DownloadConflict { return j.conflict }

func (j *DownloadJob) ResolveConflict(decision *ConflictDecision) error {
	if j.closed || j.pending == nil || j.conflict == nil || decision == nil || decision.ID != j.conflict.ID {
		return errors.New(i18n.Text("冲突已变化，请重新选择"))
	}
	if j.conflict.Kind == "monthDirectory" {
		if decision.Choice != "directory" || !slices.Contains(j.conflict.Candidates, decision.Directory) {
			return errors.New(i18n.Text("文件夹选择无效"))
		}
		if err := ensureArchiveDirectory(j.files, decision.Directory); err != nil {
			return err
		}
		j.monthDirectories[j.pending.monthKey] = decision.Directory
	} else {
		if decision.Choice != "keepBoth" && decision.Choice != "skip" && decision.Choice != "replace" {
			return errors.New(i18n.Text("同名文件处理方式无效"))
		}
		if decision.Choice == "replace" {
			if !j.conflict.CanReplace {
				return errors.New(i18n.Text("不能替换文件夹或符号链接"))
			}
			info, err := j.files.Lstat(j.pending.target)
			if err != nil && !os.IsNotExist(err) {
				return err
			}
			// Re-prompt when the displayed item changed while the user was deciding.
			if err != nil || !info.Mode().IsRegular() || !os.SameFile(j.conflictInfo, info) ||
				info.Size() != j.conflictInfo.Size() || !info.ModTime().Equal(j.conflictInfo.ModTime()) {
				j.conflict, j.conflictInfo = nil, nil
				return nil
			}
			j.pending.replaceInfo = info
		}
		j.fileChoice = decision.Choice
		if decision.ApplyToAll {
			j.filePolicy = decision.Choice
		}
	}
	j.conflict, j.conflictInfo = nil, nil
	return nil
}

func (j *DownloadJob) preparePending(ctx context.Context, item *Item) error {
	if j.conflict != nil {
		return errAwaitingDecision
	}
	if j.pending == nil {
		j.pending = &pendingDownloadFile{target: item.Path,
			targetReady: !archiveMedia(item.Entry, j.archivePhotosByMonth, j.archiveVideosByMonth)}
		if target, exists := j.resumeTargets[item.Entry.ID]; exists {
			if err := ensureArchiveDirectory(j.files, filepath.Dir(target)); err != nil {
				return err
			}
			j.pending.target, j.pending.targetReady = target, true
		}
	}
	pending := j.pending
	if pending.temp != "" {
		return nil
	}
	// Known paths can be checked before any phone content or staging writes.
	// Archived media need their local metadata first, unless resuming a known path.
	if j.promptConflicts && pending.targetReady {
		info, err := j.files.Lstat(pending.target)
		if err != nil && !os.IsNotExist(err) {
			return err
		}
		choice := j.fileChoice
		if choice == "" {
			choice = j.filePolicy
		}
		if err == nil && (choice == "" || choice == "replace" && !info.Mode().IsRegular()) {
			return j.fileConflict(item, info)
		}
		if choice == "skip" && (err == nil || j.fileChoice == "skip") {
			j.fileChoice = "skip"
			return nil
		}
	}
	if j.stage == "" {
		stage := ".ferry-download-" + rand.Text()
		if err := j.files.Mkdir(stage, 0700); err != nil {
			return err
		}
		j.stage = stage
	}
	temp := filepath.Join(j.stage, fmt.Sprintf(".ferry-%d.part", item.Entry.ID))
	hash, err := j.engine.stageFile(ctx, j.files, j.Output, *item, temp, func(written int64) {
		j.engine.Emit(Event{Type: "progress", CurrentFile: item.Path, Completed: j.completed, Total: j.count,
			Bytes: j.bytes + written, TotalBytes: j.total, Output: j.Output, Skipped: j.skipped, ReusedBytes: j.reusedBytes})
	})
	if err != nil {
		return err
	}
	pending.temp, pending.hash = temp, hash
	if (j.archivePhotosByMonth || j.usePhotoCreationDate) && MediaKind(item.Entry) == "image" {
		pending.capture, err = readPhotoCaptureDate(j.files, temp)
		pending.captureSource = "exif"
		if err != nil {
			if j.usePhotoCreationDate {
				item.CreationDateWarning = fmt.Sprintf(i18n.Text("未能设置照片创建日期：%v"), err)
			}
			if j.archivePhotosByMonth {
				item.ArchiveDateWarning = fmt.Sprintf(i18n.Text("未能读取拍摄时间，已使用后备日期归档：%v"), err)
			}
		}
	}
	if j.archiveVideosByMonth && MediaKind(item.Entry) == "video" {
		pending.capture, pending.captureSource, err = readVideoCaptureDate(ctx, j.files, temp, item.Entry.Name)
		if err != nil {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			item.ArchiveDateWarning = fmt.Sprintf(i18n.Text("未能读取视频日期，已使用后备日期归档：%v"), err)
		}
	}
	return nil
}

func (j *DownloadJob) fileConflict(item *Item, info os.FileInfo) error {
	j.conflictInfo = info
	j.conflict = &DownloadConflict{
		ID: rand.Text(), Kind: "file", TargetPath: filepath.Join(j.files.Name(), j.pending.target),
		Name: filepath.Base(j.pending.target), ExistingSize: info.Size(), ExistingModified: info.ModTime().Unix(),
		IncomingSize: item.Entry.Size, IncomingModified: item.Entry.Modified, CanReplace: info.Mode().IsRegular(),
	}
	return errAwaitingDecision
}

func (j *DownloadJob) publishPending(ctx context.Context, item *Item) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if j.conflict != nil {
		return errAwaitingDecision
	}
	pending := j.pending
	if !pending.targetReady {
		if archiveMedia(item.Entry, j.archivePhotosByMonth, j.archiveVideosByMonth) {
			target, err := j.archiveMediaPath(item, pending.capture, pending.captureSource)
			if err != nil {
				return err
			}
			pending.target = target
		}
		pending.targetReady = true
	}
	choice := j.fileChoice
	if choice == "" {
		choice = j.filePolicy
	}
	info, statErr := j.files.Lstat(pending.target)
	if statErr != nil && !os.IsNotExist(statErr) {
		return statErr
	}
	if j.promptConflicts && statErr == nil {
		if choice == "replace" && pending.replaceInfo != nil &&
			(!os.SameFile(pending.replaceInfo, info) || info.Size() != pending.replaceInfo.Size() ||
				!info.ModTime().Equal(pending.replaceInfo.ModTime())) {
			return j.fileConflict(item, info)
		}
		if choice == "" || choice == "replace" && !info.Mode().IsRegular() {
			return j.fileConflict(item, info)
		}
	}
	item.State = "completed"
	path := pending.target
	var err error
	if j.promptConflicts && choice == "skip" && (statErr == nil || j.fileChoice == "skip") {
		item.State, item.ConflictAction = "skipped", "skip"
	} else if j.promptConflicts && choice == "replace" && statErr == nil {
		if err = ctx.Err(); err != nil {
			return err
		}
		// The complete, synced and validated temporary file is on the same
		// volume. Never delete/truncate the old file before this atomic rename.
		err = j.files.Rename(pending.temp, pending.target)
		if err == nil {
			item.ConflictAction = "replace"
		}
	} else {
		keepBoth := j.keepBoth && !j.promptConflicts || choice == "keepBoth"
		path, err = j.engine.publishFile(ctx, j.files, j.Output, *item, pending.temp, pending.hash, pending.target, j.copyCommit, keepBoth)
		if err == nil && path != pending.target {
			item.ConflictAction = "keepBoth"
		}
		if j.promptConflicts && errors.Is(err, os.ErrExist) {
			if latest, statErr := j.files.Lstat(pending.target); statErr == nil {
				return j.fileConflict(item, latest)
			}
		}
	}
	if err != nil {
		return err
	}
	item.Path, item.SHA256 = path, pending.hash
	if j.RecoveryPath != "" {
		item.RecoveryTarget = path
	}
	if item.State == "completed" && j.usePhotoCreationDate && MediaKind(item.Entry) == "image" && !pending.capture.IsZero() {
		date, err := setPhotoCreationDate(j.files, path, pending.capture)
		if err != nil {
			item.CreationDateWarning = fmt.Sprintf(i18n.Text("未能设置照片创建日期：%v"), err)
		} else {
			item.PhotoCreationTime = date.Unix()
		}
	}
	if pending.temp != "" {
		if err := j.files.Remove(pending.temp); err != nil && !os.IsNotExist(err) {
			return err
		}
	}
	if item.State == "skipped" {
		j.skipped++
	}
	j.pending, j.conflict, j.conflictInfo = nil, nil, nil
	j.fileChoice = ""
	return nil
}
