package transfer

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"syscall"
	"time"

	"ferry.local/engine/internal/i18n"
)

const recoveryFileName = "恢复记录.json"
const maxRecoveryBytes = 128 << 20
const maxJournalBytes = 512 << 20

type recoveryIdentity struct {
	Device uint64 `json:"device"`
	Inode  uint64 `json:"inode"`
}

func fileIdentity(info os.FileInfo) recoveryIdentity {
	if info == nil {
		return recoveryIdentity{}
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return recoveryIdentity{}
	}
	return recoveryIdentity{Device: uint64(stat.Dev), Inode: uint64(stat.Ino)}
}

func (id recoveryIdentity) matches(info os.FileInfo) bool {
	return id.Inode != 0 && id == fileIdentity(info)
}

type recoveryManifest struct {
	Started         string           `json:"started"`
	Version         int              `json:"version"`
	Identity        string           `json:"identity"`
	Request         Request          `json:"request"`
	Storage         Storage          `json:"storage"`
	Output          string           `json:"output"`
	FilesPath       string           `json:"filesPath"`
	ReportPath      string           `json:"reportPath"`
	FilesIdentity   recoveryIdentity `json:"filesIdentity"`
	ReportIdentity  recoveryIdentity `json:"reportIdentity"`
	JournalIdentity recoveryIdentity `json:"journalIdentity"`
	CopyCommit      bool             `json:"copyCommit"`
	KeepBoth        bool             `json:"keepBoth"`
	Items           []Item           `json:"items"`
	Sources         [][]string       `json:"sources"`
}

func lockDownloadJournal(file *os.File) error {
	if err := syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		return errors.New(i18n.Text("此下载任务正在被另一个进程使用。"))
	}
	return nil
}

func (e *Engine) recoveryIdentity() string {
	return RecoveryIdentity(e.Device)
}

func RecoveryIdentity(source Device) string {
	if device, ok := source.(interface{ RecoveryIdentity() string }); ok {
		return device.RecoveryIdentity()
	}
	return source.Identity()
}

func safeRecoveryPath(path string) bool {
	if !filepath.IsLocal(path) || filepath.Clean(path) != path || path == "." {
		return false
	}
	parts := strings.Split(path, string(filepath.Separator))
	if len(parts) > 256 {
		return false
	}
	for _, part := range parts {
		if ValidName(part) != nil {
			return false
		}
	}
	return true
}

func validateSourceParts(parts []string) error {
	if len(parts) > 256 {
		return errors.New(i18n.Text("恢复记录无效或已损坏。"))
	}
	for _, part := range parts {
		if part == "" || part == "." || part == ".." || len(part) > 4096 || strings.ContainsAny(part, "/\x00") {
			return errors.New(i18n.Text("恢复记录无效或已损坏。"))
		}
	}
	return nil
}

// A directory is listed once per recovery attempt. Exact-name ambiguity is
// rejected, and the search stays inside the selected phone and storage.
func (e *Engine) resolveSource(ctx context.Context, storage uint32, parts []string, cache map[string][]Entry) (Entry, error) {
	if err := validateSourceParts(parts); err != nil {
		return Entry{}, err
	}
	var parent uint32
	var found Entry
	for index, part := range parts {
		if err := ctx.Err(); err != nil {
			return Entry{}, err
		}
		key := strings.Join(parts[:index], "/")
		entries, ok := cache[key]
		if !ok {
			var err error
			entries, err = e.Device.List(ctx, storage, parent)
			if err != nil {
				return Entry{}, err
			}
			if len(entries) > maxEntries {
				return Entry{}, errors.New(i18n.Text("目录层级或文件数量超过安全限制"))
			}
			cached := len(entries)
			for _, values := range cache {
				cached += len(values)
			}
			if cached > maxEntries || len(cache) >= 256 {
				clear(cache)
			}
			cache[key] = entries
		}
		matches := 0
		for _, entry := range entries {
			if entry.Name == part && entry.StorageID == storage {
				found = entry
				matches++
			}
		}
		if matches != 1 || index < len(parts)-1 && !found.IsDirectory {
			return Entry{}, fmt.Errorf(i18n.Text("无法唯一定位原手机文件：%s"), strings.Join(parts, "/"))
		}
		parent = found.ID
	}
	return found, nil
}

func (j *DownloadJob) prepareRecovery(ctx context.Context, req Request) error {
	identity := j.engine.recoveryIdentity()
	if identity == "" {
		j.engine.Emit(Event{Type: "status", State: "session_only", Message: i18n.Text("手机未提供稳定标识，本任务仅支持当前连接内继续。")})
		return nil
	}
	if req.RecoveryIdentity != identity {
		return errors.New(i18n.Text("手机或下载设置不匹配，无法恢复此任务。"))
	}
	if len(req.SourceSelection) == 0 || len(req.SourceSelection) != len(req.ObjectIDs) {
		return errors.New(i18n.Text("恢复记录缺少原始选择信息。"))
	}
	if err := validateSourceParts(req.SourceDirectory); err != nil {
		return err
	}
	cache := make(map[string][]Entry)
	var parent uint32
	if len(req.SourceDirectory) > 0 {
		entry, err := j.engine.resolveSource(ctx, req.StorageID, req.SourceDirectory, cache)
		if err != nil {
			return err
		}
		if !entry.IsDirectory {
			return errors.New(i18n.Text("恢复记录缺少原始选择信息。"))
		}
		parent = entry.ID
	}
	if parent != req.ParentID {
		return errors.New(i18n.Text("恢复记录缺少原始选择信息。"))
	}
	for index, selected := range req.SourceSelection {
		if selected.ID != req.ObjectIDs[index] {
			return errors.New(i18n.Text("恢复记录缺少原始选择信息。"))
		}
		parts := append(append([]string{}, req.SourceDirectory...), selected.Name)
		current, err := j.engine.resolveSource(ctx, req.StorageID, parts, cache)
		if err != nil {
			return err
		}
		if current.ID != selected.ID || current.IsDirectory != selected.IsDirectory {
			return errors.New(i18n.Text("恢复记录缺少原始选择信息。"))
		}
	}
	var storage Storage
	for _, value := range j.engine.Storages {
		if value.ID == req.StorageID {
			storage = value
		}
	}
	if storage.ID == 0 {
		return errors.New(i18n.Text("存储已变化，请重新连接手机"))
	}
	filesInfo, err := j.files.Stat(".")
	if err != nil {
		return err
	}
	reportInfo, err := j.root.Stat(".")
	if err != nil {
		return err
	}
	journalInfo, err := j.journal.Stat()
	if err != nil {
		return err
	}
	sources := make([][]string, len(j.report.Items))
	for index := range j.report.Items {
		item := &j.report.Items[index]
		item.RecoveryIndex = index + 1
		sources[index] = append(append([]string{}, req.SourceDirectory...), strings.Split(item.Path, string(filepath.Separator))...)
		if err := validateSourceParts(sources[index]); err != nil {
			return err
		}
	}
	manifest := recoveryManifest{Version: 1, Started: j.report.Started, Identity: identity, Request: req, Storage: storage,
		Output: j.Output, FilesPath: j.files.Name(), ReportPath: j.ReportPath,
		FilesIdentity: fileIdentity(filesInfo), ReportIdentity: fileIdentity(reportInfo), JournalIdentity: fileIdentity(journalInfo),
		CopyCommit: j.copyCommit, KeepBoth: j.keepBoth, Items: j.report.Items, Sources: sources}
	data, err := json.Marshal(manifest)
	if err != nil {
		return err
	}
	if len(data) > maxRecoveryBytes {
		return errors.New(i18n.Text("恢复记录超过安全大小限制，请分批下载。"))
	}
	file, err := j.root.OpenFile("recovery.tmp", os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	defer j.root.Remove("recovery.tmp")
	_, writeErr := file.Write(data)
	err = errors.Join(writeErr, file.Sync(), file.Close())
	if err != nil {
		j.root.Remove("recovery.tmp")
		return err
	}
	if err := j.root.Rename("recovery.tmp", recoveryFileName); err != nil {
		return err
	}
	j.RecoveryPath = filepath.Join(j.root.Name(), recoveryFileName)
	j.engine.Emit(Event{Type: "status", RecoveryPath: j.RecoveryPath, ReportPath: j.ReportPath, Output: j.Output})
	return nil
}

func durableBinding(req Request) Request {
	req.DownloadAction, req.ResumeToken, req.RecoveryPath = "", "", ""
	req.USBTarget, req.ConflictDecision = nil, nil
	req.StorageID, req.ParentID = 0, 0
	req.ObjectIDs = nil
	if len(req.SourceDirectory) == 0 {
		req.SourceDirectory = nil
	}
	req.SourceSelection = slices.Clone(req.SourceSelection)
	for index := range req.SourceSelection {
		req.SourceSelection[index].ID, req.SourceSelection[index].StorageID = 0, 0
	}
	return req
}

// RecoverDownload reads a dedicated versioned manifest, never the human report.
// All paths, metadata and destination identities are validated before reuse.
func (e *Engine) RecoverDownload(ctx context.Context, req Request, deviceName string) (*DownloadJob, string, error) {
	if !req.DurableRecovery {
		return nil, "", errors.New(i18n.Text("恢复记录无效或已损坏。"))
	}
	if req.RecoveryPath == "" {
		if req.RecoveryIdentity == "" || req.RecoveryIdentity != e.recoveryIdentity() {
			return nil, "", errors.New(i18n.Text("手机或下载设置不匹配，无法恢复此任务。"))
		}
		if req.SourceStorage == nil || !recoveryStorageMatches(*req.SourceStorage, req.StorageID, e.Storages) {
			return nil, "", errors.New(i18n.Text("原手机存储不匹配或无法唯一识别。"))
		}
		req.SourceSelection = slices.Clone(req.SourceSelection)
		cache := make(map[string][]Entry)
		if len(req.SourceSelection) == 0 {
			return nil, "", errors.New(i18n.Text("恢复记录缺少原始选择信息。"))
		}
		ids := make([]uint32, len(req.SourceSelection))
		for index, old := range req.SourceSelection {
			parts := append(append([]string{}, req.SourceDirectory...), old.Name)
			current, err := e.resolveSource(ctx, req.StorageID, parts, cache)
			if err != nil {
				return nil, "", err
			}
			if !sameSource(old, current) {
				return nil, "", fmt.Errorf(i18n.Text("手机文件已变化，无法继续原任务：%s"), old.Name)
			}
			ids[index] = current.ID
			req.SourceSelection[index].ID, req.SourceSelection[index].StorageID = current.ID, current.StorageID
		}
		req.ObjectIDs = ids
		req.ParentID = 0
		if len(req.SourceDirectory) > 0 {
			parent, err := e.resolveSource(ctx, req.StorageID, req.SourceDirectory, cache)
			if err != nil {
				return nil, "", err
			}
			req.ParentID = parent.ID
		}
		return e.PrepareDownload(ctx, req, deviceName)
	}
	invalid := errors.New(i18n.Text("恢复记录无效或已损坏。"))
	if filepath.Base(req.RecoveryPath) != recoveryFileName {
		return nil, "", invalid
	}
	root, err := os.OpenRoot(filepath.Dir(req.RecoveryPath))
	if err != nil {
		return nil, "", err
	}
	defer root.Close()
	info, err := root.Lstat(recoveryFileName)
	if err != nil || !info.Mode().IsRegular() || info.Size() > maxRecoveryBytes {
		return nil, "", invalid
	}
	file, err := root.Open(recoveryFileName)
	if err != nil {
		return nil, "", err
	}
	var manifest recoveryManifest
	decodeErr := json.NewDecoder(io.LimitReader(file, maxRecoveryBytes+1)).Decode(&manifest)
	file.Close()
	if decodeErr != nil || manifest.Version != 1 || len(manifest.Items) == 0 || len(manifest.Items) > maxEntries || len(manifest.Sources) != len(manifest.Items) {
		return nil, "", invalid
	}
	if manifest.Identity == "" || manifest.Identity != e.recoveryIdentity() || manifest.Identity != req.RecoveryIdentity || manifest.Request.DeviceKey != e.Device.Identity() || !reflect.DeepEqual(durableBinding(manifest.Request), durableBinding(req)) {
		return nil, "", errors.New(i18n.Text("手机或下载设置不匹配，无法恢复此任务。"))
	}
	storageMatches := 0
	for _, storage := range e.Storages {
		if storage.Name == manifest.Storage.Name && storage.Capacity == manifest.Storage.Capacity {
			storageMatches++
			if storage.ID != req.StorageID {
				return nil, "", errors.New(i18n.Text("原手机存储不匹配或无法唯一识别。"))
			}
		}
	}
	if storageMatches != 1 {
		return nil, "", errors.New(i18n.Text("原手机存储不匹配或无法唯一识别。"))
	}
	reportInfo, err := root.Stat(".")
	if err != nil || filepath.Clean(manifest.ReportPath) != filepath.Join(root.Name(), "传输报告.json") || !manifest.ReportIdentity.matches(reportInfo) {
		return nil, "", invalid
	}
	destination, err := filepath.Abs(req.Destination)
	if err != nil {
		return nil, "", invalid
	}
	if req.DownloadLayout == "direct" {
		if manifest.Output != destination {
			return nil, "", invalid
		}
	} else if filepath.Dir(manifest.Output) != destination || !strings.HasPrefix(filepath.Base(manifest.Output), "渡舟-") {
		return nil, "", invalid
	}
	filesPath := manifest.Output
	if req.DownloadLayout == "" {
		filesPath = filepath.Join(filesPath, "files")
	}
	if manifest.FilesPath != filesPath {
		return nil, "", invalid
	}
	filesRoot, err := os.OpenRoot(manifest.FilesPath)
	if err != nil {
		return nil, "", err
	}
	filesInfo, statErr := filesRoot.Stat(".")
	filesRoot.Close()
	if statErr != nil || !manifest.FilesIdentity.matches(filesInfo) {
		return nil, "", errors.New(i18n.Text("原保存目录已变化，请重新选择文件并新建下载任务。"))
	}
	journalInfo, err := root.Lstat("任务记录.ndjson")
	if err != nil || !journalInfo.Mode().IsRegular() || !manifest.JournalIdentity.matches(journalInfo) {
		return nil, "", invalid
	}
	j := DownloadJob{Output: manifest.Output, ReportPath: manifest.ReportPath, RecoveryPath: req.RecoveryPath, StorageID: req.StorageID,
		engine: e, keepBoth: manifest.KeepBoth, copyCommit: manifest.CopyCommit,
		usePhotoCreationDate: req.UsePhotoCreationDate, archivePhotosByMonth: req.ArchivePhotosByMonth, archiveVideosByMonth: req.ArchiveVideosByMonth,
		promptConflicts: req.PromptConflicts, recovering: true, replayJournal: true, recoverySources: manifest.Sources,
		monthDirectories: make(map[string]string), report: Report{Version: 1, Started: manifest.Started, Device: deviceName, Output: manifest.Output, Items: manifest.Items}}
	selectedRoots := make(map[string]bool)
	for _, entry := range req.SourceSelection {
		if ValidName(entry.Name) != nil {
			return nil, "", invalid
		}
		selectedRoots[entry.Name] = entry.IsDirectory
	}
	for index, item := range j.report.Items {
		if item.RecoveryIndex != index+1 || !safeRecoveryPath(item.Path) || item.State != "pending" || item.SHA256 != "" || item.RecoveryTarget != "" || item.Entry.Size < 0 || ValidName(item.Entry.Name) != nil || len(manifest.Sources[index]) == 0 || validateSourceParts(manifest.Sources[index]) != nil || manifest.Sources[index][len(manifest.Sources[index])-1] != item.Entry.Name {
			return nil, "", invalid
		}
		expected := append(append([]string{}, req.SourceDirectory...), strings.Split(item.Path, string(filepath.Separator))...)
		if !reflect.DeepEqual(expected, manifest.Sources[index]) {
			return nil, "", invalid
		}
		parts := strings.Split(item.Path, string(filepath.Separator))
		directory, selected := selectedRoots[parts[0]]
		if !selected || !directory && len(parts) != 1 {
			return nil, "", invalid
		}
		if !item.Entry.IsDirectory {
			if item.Entry.Size > math.MaxInt64-j.total {
				return nil, "", invalid
			}
			j.total += item.Entry.Size
			j.count++
		}
	}
	checkpoint := DownloadCheckpoint{job: j, filesPath: manifest.FilesPath, reportPath: root.Name(), filesInfo: filesInfo,
		reportInfo: reportInfo, journalInfo: journalInfo}
	job, err := checkpoint.Resume(ctx, e)
	return job, manifest.Output, err
}

func recoveryStorageMatches(expected Storage, selected uint32, storages []Storage) bool {
	matches := 0
	for _, storage := range storages {
		if storage.Name == expected.Name && storage.Capacity == expected.Capacity {
			matches++
			if storage.ID != selected {
				return false
			}
		}
	}
	return matches == 1
}

func sameSource(old, current Entry) bool {
	return old.Name == current.Name && old.IsDirectory == current.IsDirectory &&
		(old.IsDirectory || (old.Size < 0 || old.Size == current.Size) && old.Modified == current.Modified)
}

func (j *DownloadJob) relinkSource(ctx context.Context, index int) error {
	if j.recoveryResolved[index] {
		return nil
	}
	item := &j.report.Items[index]
	current, err := j.engine.resolveSource(ctx, j.StorageID, j.recoverySources[index], j.recoveryListings)
	if err != nil {
		return err
	}
	current, err = j.engine.Device.Info(ctx, current.ID)
	if err != nil {
		return err
	}
	if current.StorageID != j.StorageID || !sameSource(item.Entry, current) {
		return fmt.Errorf(i18n.Text("手机文件已变化，无法继续原任务：%s"), item.Entry.Name)
	}
	item.Entry = current
	if target, ok := j.recoveryTargets[index]; ok {
		j.resumeTargets[current.ID] = target
	}
	j.recoveryResolved[index] = true
	return nil
}

func (j *DownloadJob) restoreJournal(ctx context.Context) error {
	info, err := j.journal.Stat()
	if err != nil {
		return err
	}
	if info.Size() > maxJournalBytes {
		return errors.New(i18n.Text("恢复记录超过安全大小限制，请分批下载。"))
	}
	reader := bufio.NewReaderSize(io.NewSectionReader(j.journal, 0, info.Size()), 256<<10)
	var validBytes int64
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		line, err := reader.ReadSlice('\n')
		if errors.Is(err, io.EOF) {
			// A crash can leave one partial append. Remove only that incomplete
			// tail under the journal lock before any new durable records append.
			if len(line) > 0 {
				if err := j.journal.Truncate(validBytes); err != nil {
					return err
				}
			}
			break
		}
		if err != nil {
			return err
		}
		if len(line) > 256<<10 {
			return errors.New(i18n.Text("恢复记录无效或已损坏。"))
		}
		var item Item
		if json.Unmarshal(line, &item) != nil || item.RecoveryIndex < 1 || item.RecoveryIndex > len(j.report.Items) || !safeRecoveryPath(item.Path) || item.RecoveryTarget != "" && !safeRecoveryPath(item.RecoveryTarget) {
			return errors.New(i18n.Text("恢复记录无效或已损坏。"))
		}
		index := item.RecoveryIndex - 1
		original := j.report.Items[index]
		if !sameSource(original.Entry, item.Entry) {
			return errors.New(i18n.Text("恢复记录无效或已损坏。"))
		}
		if item.Entry.IsDirectory && original.Path != item.Path {
			for child := index + 1; child < len(j.report.Items); child++ {
				path := j.report.Items[child].Path
				if !strings.HasPrefix(path, original.Path+string(filepath.Separator)) {
					break
				}
				j.report.Items[child].Path = item.Path + strings.TrimPrefix(path, original.Path)
			}
		}
		if item.State != "completed" && item.State != "skipped" {
			item.State, item.Error = "pending", ""
		}
		j.report.Items[index] = item
		if item.ArchiveDate != "" && archiveMedia(item.Entry, j.archivePhotosByMonth, j.archiveVideosByMonth) {
			target := item.Path
			if item.RecoveryTarget != "" {
				target = item.RecoveryTarget
			}
			parent := filepath.Dir(target)
			parts := strings.Split(parent, string(filepath.Separator))
			date, parseErr := time.Parse(time.RFC3339Nano, item.ArchiveDate)
			if len(parts) == 2 && parseErr == nil {
				j.monthDirectories[filepath.Join(parts[0], fmt.Sprintf("%02d月", date.Month()))] = parent
			}
		}
		validBytes += int64(len(line))
	}
	return nil
}
