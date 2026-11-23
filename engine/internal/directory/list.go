// Adapted from OpenMTP's MIT-licensed directory implementation.
// Copyright (c) 2010-present Ganesh Rathinavel. See ThirdPartyNotices/OpenMTP-MIT.txt.
package directory

import (
	"context"
	"errors"
	"ferry.local/engine/internal/i18n"
	"fmt"
	"log"
	"math"
	"strings"
	"time"

	"ferry.local/engine/internal/transfer"
	"github.com/ganeshrvel/go-mtpfs/mtp"
)

// ErrUnsupported means a complete protocol response was received but the
// operation/data is unsupported. Transport errors MUST NOT trigger fallback.
var ErrUnsupported = errors.New("bulk directory properties unavailable")

type Reader interface {
	GetData(*mtp.Container, interface{}) error
}

type Status func(string)

func Supported(info *mtp.DeviceInfo) bool {
	if info == nil {
		return false
	}
	for _, code := range info.OperationsSupported {
		if code == mtp.OC_MTP_GetObjPropList {
			return true
		}
	}
	return false
}

func List(ctx context.Context, dev Reader, storage, parent uint32, status Status) ([]transfer.Entry, error) {
	return list(ctx, dev, storage, parent, status, true)
}

func list(ctx context.Context, dev Reader, storage, parent uint32, status Status, includeSizes bool) ([]transfer.Entry, error) {
	started := time.Now()
	datasets := make(map[uint16]*propertyList)
	properties := []struct {
		code  uint16
		label string
	}{
		{propertyParent, i18n.Text("目录关系")}, {propertyName, i18n.Text("文件名")}, {propertyFormat, i18n.Text("文件类型")},
		{propertySize, i18n.Text("文件大小")}, {propertyModified, i18n.Text("修改时间")},
	}
	if !includeSizes {
		properties = append(properties[:3], properties[4:]...)
	}
	for i, property := range properties {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		if status != nil {
			status(fmt.Sprintf(i18n.Text("正在批量读取%s（%d/%d）…"), property.label, i+1, len(properties)))
		}
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		values, err := readProperty(ctx, dev, parent, property.code, property.label)
		if err != nil {
			return nil, err
		}
		datasets[property.code] = values
	}
	entries, err := joinProperties(datasets, storage, parent, includeSizes)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrUnsupported, err)
	}
	log.Printf("directory bulk completed elapsed=%s entries=%d", time.Since(started), len(entries))
	return entries, nil
}

func joinProperties(data map[uint16]*propertyList, storage, parent uint32, includeSizes bool) ([]transfer.Entry, error) {
	parents := data[propertyParent]
	required := []uint16{propertyName, propertyFormat, propertyModified}
	if includeSizes {
		required = append(required, propertySize)
	}
	for _, property := range required {
		if len(data[property].values) != len(parents.values) {
			return nil, fmt.Errorf("property %04x has inconsistent object count", property)
		}
	}
	entries := make([]transfer.Entry, 0, len(parents.values))
	for _, handle := range parents.handles {
		for _, property := range required {
			if _, ok := data[property].values[handle]; !ok {
				return nil, fmt.Errorf("missing property %04x for object %d", property, handle)
			}
		}
		// Some devices include the parent or unrelated descendants in depth=1.
		if handle == parent || parents.values[handle].number != uint64(parent) {
			continue
		}
		name := data[propertyName].values[handle].text
		if name == "" || name == "." || name == ".." || strings.ContainsAny(name, "/\x00") {
			return nil, fmt.Errorf("invalid filename for object %d", handle)
		}
		isDirectory := data[propertyFormat].values[handle].number == mtp.OFC_Association
		size := int64(-1) // Browsing explicitly requested without file sizes.
		if isDirectory {
			size = 0
		} else if includeSizes {
			value := data[propertySize].values[handle].number
			if value > math.MaxInt64 {
				return nil, fmt.Errorf("invalid file size for object %d", handle)
			}
			size = int64(value)
		}
		modified, err := mtp.ParseDateTime(data[propertyModified].values[handle].text)
		if err != nil {
			return nil, fmt.Errorf("invalid date for object %d: %w", handle, err)
		}
		unix := int64(0)
		if !modified.IsZero() {
			unix = modified.Unix()
		}
		entries = append(entries, transfer.Entry{ID: handle, StorageID: storage, Name: name, IsDirectory: isDirectory, Size: size, Modified: unix})
	}
	return entries, nil
}

// Read selects bulk listing only for supported non-root directories. fallback
// is injected so tests can prove no metadata reads occur after transport failure.
func Read(ctx context.Context, dev Reader, supported bool, storage, parent uint32, status Status,
	fallback func() ([]transfer.Entry, error)) ([]transfer.Entry, error) {
	return ReadForBrowse(ctx, dev, supported, storage, parent, status, true, fallback)
}

// Only browsing may omit sizes. Download traversal always calls Read/List.
func ReadForBrowse(ctx context.Context, dev Reader, supported bool, storage, parent uint32, status Status,
	includeSizes bool, fallback func() ([]transfer.Entry, error)) ([]transfer.Entry, error) {
	if supported && parent != 0 && parent != mtp.GOH_ROOT_PARENT {
		entries, err := list(ctx, dev, storage, parent, status, includeSizes)
		if err == nil {
			return entries, nil
		}
		if !errors.Is(err, ErrUnsupported) {
			return nil, err
		}
		log.Printf("directory compatibility fallback: %v", err)
		if status != nil {
			status(i18n.Text("设备不支持批量属性，正在使用兼容方式读取…"))
		}
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	return fallback()
}

// readProperty consumes a full MTP transaction. Only explicit unsupported
// responses or malformed complete datasets permit compatibility fallback.
func readProperty(ctx context.Context, dev Reader, parent uint32, property uint16, label string) (*propertyList, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	values := &propertyList{property: property}
	request := mtp.Container{Code: mtp.OC_MTP_GetObjPropList, Param: []uint32{parent, 0, uint32(property), 0, 1}}
	started := time.Now()
	err := dev.GetData(&request, values)
	log.Printf("directory property=%04x elapsed=%s entries=%d error=%v", property, time.Since(started), len(values.values), err)
	if stopped := ctx.Err(); stopped != nil {
		return nil, stopped
	}
	if err != nil {
		var code mtp.RCError
		if errors.As(err, &code) {
			switch uint16(code) {
			case 0x2005, 0x2006, 0x201d, 0xa801, 0xa802, 0xa807, 0xa808, 0xa80a:
				return nil, fmt.Errorf("%w: %v", ErrUnsupported, err)
			}
		}
		return nil, fmt.Errorf(i18n.Text("读取%s失败：%w"), label, err)
	}
	return values, nil
}

// Sizes reads only the expensive property, without re-reading names or dates.
// The UI merges by object ID and rejects missing entries before publishing.
func Sizes(ctx context.Context, dev Reader, parent uint32) ([]transfer.ObjectSize, error) {
	values, err := readProperty(ctx, dev, parent, propertySize, i18n.Text("文件大小"))
	if err != nil {
		return nil, err
	}
	result := make([]transfer.ObjectSize, 0, len(values.handles))
	for _, id := range values.handles {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		size := values.values[id].number
		if size > math.MaxInt64 {
			return nil, fmt.Errorf("%w: invalid file size for object %d", ErrUnsupported, id)
		}
		result = append(result, transfer.ObjectSize{ID: id, Size: int64(size)})
	}
	return result, nil
}
