package transfer

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"ferry.local/engine/internal/i18n"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
)

func numberedPath(path string, number int, directory bool) string {
	if number == 0 {
		return path
	}
	name := filepath.Base(path)
	ext := ""
	if !directory {
		ext = filepath.Ext(name)
		if ext == name {
			ext = ""
		}
	}
	return filepath.Join(filepath.Dir(path), fmt.Sprintf("%s (%d)%s", strings.TrimSuffix(name, ext), number, ext))
}

// exFAT lacks exclusive rename. The original file is already validated; create
// the final name exclusively and check the second copy before reporting success.
// This opt-in compatibility path is not atomically visible during the local copy.
func (e *Engine) copyExclusive(ctx context.Context, root *os.Root, output, source, destination string, entry Entry, expectedHash string) (resultErr error) {
	if err := e.checkSpace(output, entry.Size); err != nil {
		return err
	}
	input, err := root.Open(source)
	if err != nil {
		return err
	}
	defer input.Close()
	file, err := root.OpenFile(destination, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	complete := false
	defer func() {
		file.Close()
		if !complete {
			resultErr = errors.Join(resultErr, root.Remove(destination))
		}
	}()
	hash := sha256.New()
	writer := &guardedWriter{ctx: ctx, writer: io.MultiWriter(file, hash), expected: entry.Size, progress: func(int64) {},
		check: func(needed int64) error { return e.checkSpace(output, needed) }}
	if _, err := io.Copy(writer, input); err != nil {
		return err
	}
	if writer.written != entry.Size || hex.EncodeToString(hash.Sum(nil)) != expectedHash {
		return errors.New(i18n.Text("本地文件复制校验失败"))
	}
	if err := file.Sync(); err != nil {
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	if entry.Modified > 0 {
		date := time.Unix(entry.Modified, 0)
		if err := root.Chtimes(destination, date, date); err != nil {
			return err
		}
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	complete = true
	return nil
}

// Check the actual destination before reading file contents from the phone.
// The caller owns a newly created private task directory. Only remove probe
// names we created; an unexpected existing entry must remain untouched.
func checkCommitSupport(root *os.Root) error {
	const source = ".ferry-commit-check.part"
	const destination = ".ferry-commit-check.done"
	f, err := root.OpenFile(source, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	defer root.Remove(source)
	if err := f.Close(); err != nil {
		return err
	}
	if err := commitFile(root, source, destination); err != nil {
		return err
	}
	return root.Remove(destination)
}
