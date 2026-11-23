package transfer

/*
#include <stdio.h>
#include <stdlib.h>
*/
import "C"

import (
	"os"
	"path/filepath"
	"strings"
	"unsafe"
)

// commitFile publishes a complete file without replacing any existing entry.
// Open both parents through os.Root, then pass only basenames to renameatx_np:
// resolving an absolute path from Root.Name would lose its traversal protection.
// RENAME_EXCL does not require hard links, but is filesystem dependent.
// Unsupported filesystems fail safely; never retry with replacing rename.
func commitFile(root *os.Root, source, destination string) error {
	for _, name := range []string{source, destination} {
		if !filepath.IsLocal(name) || strings.ContainsRune(name, '\x00') ||
			filepath.Base(name) == "." || strings.HasSuffix(name, string(filepath.Separator)) {
			return &os.LinkError{Op: "rename-exclusive", Old: source, New: destination, Err: os.ErrInvalid}
		}
	}
	from, err := root.Open(filepath.Dir(source))
	if err != nil {
		return err
	}
	defer from.Close()
	to, err := root.Open(filepath.Dir(destination))
	if err != nil {
		return err
	}
	defer to.Close()
	oldName := C.CString(filepath.Base(source))
	defer C.free(unsafe.Pointer(oldName))
	newName := C.CString(filepath.Base(destination))
	defer C.free(unsafe.Pointer(newName))
	// Deferred Close keeps both files (and descriptors) alive throughout the call.
	result, callErr := C.renameatx_np(C.int(from.Fd()), oldName, C.int(to.Fd()), newName, C.RENAME_EXCL)
	if result != 0 {
		return &os.LinkError{Op: "rename-exclusive", Old: source, New: destination, Err: callErr}
	}
	return nil
}
