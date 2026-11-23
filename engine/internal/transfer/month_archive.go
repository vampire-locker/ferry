package transfer

import (
	"crypto/rand"
	"ferry.local/engine/internal/i18n"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Structural directory names stay stable when the application's language changes.
const unknownDateDirectory = "日期未知"

func archiveMedia(entry Entry, photos, videos bool) bool {
	kind := MediaKind(entry)
	return photos && kind == "image" || videos && kind == "video"
}

// Selected media are grouped at the output root. Keep source directories for
// unarchived files and genuine empty directories, independently of media type.
func monthArchivePlan(items []Item, photos, videos bool) []Item {
	needed := make(map[string]bool)
	for index := range items {
		item := &items[index]
		if archiveMedia(item.Entry, photos, videos) {
			item.SourcePath = item.Path
			continue
		}
		emptyDirectory := item.Entry.IsDirectory &&
			(index+1 == len(items) || filepath.Dir(items[index+1].Path) != item.Path)
		if item.Entry.IsDirectory && !emptyDirectory {
			continue
		}
		path := filepath.Dir(item.Path)
		if emptyDirectory {
			path = item.Path
		}
		for path != "." {
			if needed[path] {
				break
			}
			needed[path] = true
			path = filepath.Dir(path)
		}
	}
	result := items[:0]
	for _, item := range items {
		if !item.Entry.IsDirectory || needed[item.Path] {
			result = append(result, item)
		}
	}
	return result
}

// EXIF keeps its recorded local calendar, even with an explicit timezone.
// Modification-time fallback uses the Mac's local calendar, like list filters.
func monthArchiveDate(capture time.Time, modified int64) (time.Time, string) {
	if !capture.IsZero() && capture.Year() >= 1 && capture.Year() <= 9999 {
		return capture, "exif"
	}
	if modified > 0 {
		date := time.Unix(modified, 0).In(time.Local)
		if date.Year() >= 1 && date.Year() <= 9999 {
			return date, "modified"
		}
	}
	return time.Time{}, "unknown"
}

// Only reuse real archive directories. A file or symlink occupying either
// component is a conflict; never rename it, merge through it or replace it.
func ensureArchiveDirectory(root *os.Root, directory string) error {
	parent := "."
	components := strings.Split(filepath.Clean(directory), string(filepath.Separator))
	for _, component := range components {
		parent = filepath.Join(parent, component)
		if err := root.Mkdir(parent, 0700); err != nil && !os.IsExist(err) {
			return err
		}
		info, err := root.Lstat(parent)
		if err != nil {
			return err
		}
		if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf(i18n.Text("归档目录被同名文件或链接占用：%s"), parent)
		}
	}
	return nil
}

func (j *DownloadJob) archiveMediaPath(item *Item, capture time.Time, captureSource string) (string, error) {
	date, source := monthArchiveDate(capture, item.Entry.Modified)
	if source == "exif" && captureSource != "" {
		source = captureSource
	}
	item.ArchiveDateSource = source
	directory := unknownDateDirectory
	if !date.IsZero() {
		item.ArchiveDate = date.Format(time.RFC3339Nano)
		var err error
		directory, err = j.archiveMonthDirectory(date)
		if err != nil {
			return "", err
		}
	}
	if err := ensureArchiveDirectory(j.files, directory); err != nil {
		return "", err
	}
	return filepath.Join(directory, item.Entry.Name), nil
}

func (j *DownloadJob) archiveMonthDirectory(date time.Time) (string, error) {
	year := fmt.Sprintf("%04d", date.Year())
	canonical := filepath.Join(year, fmt.Sprintf("%02d月", date.Month()))
	if j.monthDirectories == nil {
		j.monthDirectories = make(map[string]string)
	}
	if selected, ok := j.monthDirectories[canonical]; ok {
		if err := ensureArchiveDirectory(j.files, selected); err != nil {
			return "", err
		}
		return selected, nil
	}
	if err := ensureArchiveDirectory(j.files, year); err != nil {
		return "", err
	}
	var candidates []string
	seen := make(map[string]bool)
	for _, name := range []string{fmt.Sprintf("%02d月", date.Month()), fmt.Sprintf("%d月", date.Month()), fmt.Sprintf("%02d", date.Month()), fmt.Sprintf("%d", date.Month())} {
		path := filepath.Join(year, name)
		if seen[path] {
			continue
		}
		seen[path] = true
		info, err := j.files.Lstat(path)
		if err != nil && !os.IsNotExist(err) {
			return "", err
		}
		if err == nil && info.IsDir() && info.Mode()&os.ModeSymlink == 0 {
			candidates = append(candidates, path)
		}
	}
	if len(candidates) > 1 && j.promptConflicts {
		j.pending.monthKey = canonical
		j.conflict = &DownloadConflict{ID: rand.Text(), Kind: "monthDirectory", TargetPath: j.files.Name(),
			Name: fmt.Sprintf(i18n.Text("%d 年 %d 月"), date.Year(), date.Month()), Candidates: candidates}
		return "", errAwaitingDecision
	}
	selected := canonical
	if len(candidates) > 0 {
		selected = candidates[0]
	}
	if err := ensureArchiveDirectory(j.files, selected); err != nil {
		return "", err
	}
	j.monthDirectories[canonical] = selected
	return selected, nil
}
