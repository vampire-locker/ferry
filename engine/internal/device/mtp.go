package device

import (
	"context"
	"crypto/sha256"
	"errors"
	"ferry.local/engine/internal/directory"
	"ferry.local/engine/internal/i18n"
	"fmt"
	"io"
	"log"
	"math"
	"time"

	"ferry.local/engine/internal/transfer"
	"github.com/ganeshrvel/go-mtpfs/mtp"
	"github.com/ganeshrvel/usb"
)

// MTP is confined to a helper process and invoked serially. Closing that process
// releases USB handles even when a third-party library cannot recover a session.
type MTP struct {
	dev                *mtp.Device
	key                string
	recoveryKey        string
	bulkSupported      bool
	thumbnailSupported bool
	Status             directory.Status
	AllowCapture       bool
	Target             *transfer.USBTarget
}

func (m *MTP) Connect(ctx context.Context) (string, []transfer.Storage, error) {
	if err := ctx.Err(); err != nil {
		return "", nil, err
	}
	var dev *mtp.Device
	var err error
	started := time.Now()
	log.Printf("connection phase=select_device state=begin")
	if m.Target != nil {
		t := m.Target
		dev, err = mtp.SelectDeviceByUSBTarget(mtp.USBDeviceTarget{
			BusNumber: t.BusNumber, PortNumbers: t.PortNumbers, VendorID: t.VendorID,
			ProductID: t.ProductID, SerialNumber: t.SerialNumber,
		}, m.AllowCapture)
	} else {
		dev, err = mtp.SelectDeviceWithDriverDetach("", m.AllowCapture)
	}
	log.Printf("connection phase=select_device state=end result=%s elapsed_ms=%d", connectionLogResult(err), time.Since(started).Milliseconds())
	if err != nil {
		if errors.Is(err, mtp.ErrMultipleDevices) {
			return "", nil, errors.New(i18n.Text("检测到多台手机，请先选择要连接的手机。"))
		}
		if errors.Is(err, mtp.ErrUSBTargetNotFound) {
			return "", nil, errors.New(i18n.Text("所选手机已断开或发生变化，请重新选择手机后连接。"))
		}
		return "", nil, fmt.Errorf(i18n.Text("未能连接手机。请解锁手机、选择 USB 文件传输，并退出 OpenMTP 等占用设备的应用：%w"), connectionError(err))
	}
	m.dev = dev
	dev.Timeout = 15000
	if err := ctx.Err(); err != nil {
		return "", nil, err
	}
	started = time.Now()
	log.Printf("connection phase=open_session state=begin")
	err = dev.OpenSession()
	log.Printf("connection phase=open_session state=end result=%s elapsed_ms=%d", connectionLogResult(err), time.Since(started).Milliseconds())
	if err != nil {
		return "", nil, fmt.Errorf(i18n.Text("无法打开 MTP 会话：%w"), connectionError(err))
	}
	var info mtp.DeviceInfo
	if err = dev.GetDeviceInfo(&info); err != nil {
		return "", nil, fmt.Errorf(i18n.Text("读取设备信息失败：%w"), err)
	}
	m.bulkSupported = directory.Supported(&info)
	for _, operation := range info.OperationsSupported {
		if operation == mtp.OC_GetThumb {
			m.thumbnailSupported = true
		}
	}
	var ids mtp.Uint32Array
	if err = dev.GetStorageIDs(&ids); err != nil {
		return "", nil, fmt.Errorf(i18n.Text("读取存储列表失败：%w"), err)
	}
	storages := make([]transfer.Storage, 0, len(ids.Values))
	for _, id := range ids.Values {
		if err := ctx.Err(); err != nil {
			return "", nil, err
		}
		var s mtp.StorageInfo
		if err = dev.GetStorageInfo(id, &s); err != nil {
			return "", nil, fmt.Errorf(i18n.Text("读取存储信息失败：%w"), err)
		}
		name := s.StorageDescription
		if name == "" {
			name = i18n.Text("手机存储")
		}
		storages = append(storages, transfer.Storage{ID: id, Name: name, Capacity: s.MaxCapability, Free: s.FreeSpaceInBytes})
	}
	if len(storages) == 0 {
		return "", nil, errors.New(i18n.Text("手机未开放存储，请在手机上允许文件访问后重试"))
	}
	m.key = fmt.Sprintf("%x", sha256.Sum256([]byte(info.Manufacturer+"\x00"+info.Model+"\x00"+info.SerialNumber)))
	m.recoveryKey = ""
	serial := info.SerialNumber
	if serial == "" && m.Target != nil {
		serial = m.Target.SerialNumber
	}
	if serial != "" {
		m.recoveryKey = fmt.Sprintf("%x", sha256.Sum256([]byte(info.Manufacturer+"\x00"+info.Model+"\x00"+serial)))
	}
	name := info.Manufacturer + " " + info.Model
	return name, storages, nil
}

func (m *MTP) List(ctx context.Context, storage, parent uint32) ([]transfer.Entry, error) {
	return m.ListForBrowse(ctx, storage, parent, true)
}

func (m *MTP) ListForBrowse(ctx context.Context, storage, parent uint32, includeSizes bool) ([]transfer.Entry, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if parent == 0 {
		parent = mtp.GOH_ROOT_PARENT
	}
	previousTimeout := m.dev.Timeout
	m.dev.Timeout = 120000
	defer func() { m.dev.Timeout = previousTimeout }()
	entries, err := directory.ReadForBrowse(ctx, m.dev, m.bulkSupported, storage, parent, m.Status, includeSizes, func() ([]transfer.Entry, error) {
		var handles mtp.Uint32Array
		if err := m.dev.GetObjectHandles(storage, mtp.GOH_ALL_FORMATS, parent, &handles); err != nil {
			return nil, err
		}
		if len(handles.Values) > 1000000 {
			return nil, errors.New(i18n.Text("目录项目数量超过安全限制"))
		}
		entries := make([]transfer.Entry, 0, len(handles.Values))
		for i, id := range handles.Values {
			if m.Status != nil && (i%250 == 0) {
				m.Status(fmt.Sprintf(i18n.Text("正在读取文件信息（%d / %d）…"), i, len(handles.Values)))
			}
			entry, err := m.Info(ctx, id)
			if err != nil {
				return nil, err
			}
			entries = append(entries, entry)
		}
		return entries, nil
	})
	if err != nil {
		return nil, err
	}

	// The UI applies the user's natural sort once. Download planning does not
	// depend on device enumeration order.
	return entries, nil
}

func (m *MTP) Sizes(ctx context.Context, storage, parent uint32) ([]transfer.ObjectSize, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if m.bulkSupported && parent != 0 && parent != mtp.GOH_ROOT_PARENT {
		previousTimeout := m.dev.Timeout
		m.dev.Timeout = 120000
		defer func() { m.dev.Timeout = previousTimeout }()
		sizes, err := directory.Sizes(ctx, m.dev, parent)
		if err == nil {
			return sizes, nil
		}
		if !errors.Is(err, directory.ErrUnsupported) {
			return nil, err
		}
	}
	entries, err := m.List(ctx, storage, parent)
	if err != nil {
		return nil, err
	}
	sizes := make([]transfer.ObjectSize, 0, len(entries))
	for _, entry := range entries {
		sizes = append(sizes, transfer.ObjectSize{ID: entry.ID, Size: entry.Size})
	}
	return sizes, nil
}

func (m *MTP) Info(ctx context.Context, id uint32) (transfer.Entry, error) {
	if err := ctx.Err(); err != nil {
		return transfer.Entry{}, err
	}
	var info mtp.ObjectInfo
	if err := m.dev.GetObjectInfo(id, &info); err != nil {
		return transfer.Entry{}, mediaReadError(i18n.Text("读取文件信息失败"), err)
	}
	directory := info.ObjectFormat == mtp.OFC_Association
	size := int64(info.CompressedSize)
	if !directory && info.CompressedSize == math.MaxUint32 {
		var v mtp.Uint64Value
		if err := m.dev.GetObjectPropValue(id, mtp.OPC_ObjectSize, &v); err != nil {
			return transfer.Entry{}, mediaReadError(i18n.Text("无法读取大文件的真实大小"), err)
		}
		if v.Value > math.MaxInt64 {
			return transfer.Entry{}, errors.New(i18n.Text("文件大小超出支持范围"))
		}
		size = int64(v.Value)
	}
	modified := int64(0)
	if !info.ModificationDate.IsZero() {
		modified = info.ModificationDate.Unix()
	}
	return transfer.Entry{ID: id, StorageID: info.StorageID, Name: info.Filename, IsDirectory: directory, Size: size, Modified: modified}, nil
}

func (m *MTP) Read(ctx context.Context, id uint32, w io.Writer) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if err := m.dev.GetObject(id, w, func(_ int64) error { return ctx.Err() }); err != nil {
		return mediaReadError(i18n.Text("读取文件内容失败"), err)
	}
	return nil
}

func (m *MTP) Thumbnail(ctx context.Context, id uint32, w io.Writer) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if !m.thumbnailSupported {
		return transfer.ErrThumbnailUnavailable
	}
	req := mtp.Container{Code: mtp.OC_GetThumb, Param: []uint32{id}}
	var rep mtp.Container
	err := m.dev.RunTransaction(&req, &rep, w, nil, 0, func(_ int64) error { return ctx.Err() })
	var code mtp.RCError
	if errors.As(err, &code) {
		switch uint16(code) {
		case mtp.RC_OperationNotSupported, mtp.RC_NoThumbnailPresent, mtp.RC_GeneralError:
			// Treat a complete GetThumb rejection as an unavailable thumbnail.
			// RunTransaction consumed the response; bounded image fallback is
			// safe here, unlike after USB/synchronization failures.
			return fmt.Errorf(i18n.Text("%w：%w"), transfer.ErrThumbnailUnavailable, err)
		}
	}
	if err != nil {
		return mediaReadError(i18n.Text("读取设备缩略图失败"), err)
	}
	return nil
}

func mediaReadError(operation string, err error) error {
	var code mtp.RCError
	if errors.As(err, &code) {
		switch uint16(code) {
		case mtp.RC_GeneralError, mtp.RC_InvalidObjectHandle, mtp.RC_AccessDenied:
			return fmt.Errorf(i18n.Text("%s：%w：%w"), operation, transfer.ErrMediaObjectUnavailable, err)
		}
	}
	return fmt.Errorf(i18n.Text("%s：%w"), operation, err)
}
func (m *MTP) Close() {
	if m.dev != nil {
		started := time.Now()
		log.Printf("connection phase=release_device state=begin")
		err := m.dev.Close()
		m.dev.Done()
		m.dev = nil
		log.Printf("connection phase=release_device state=end result=%s elapsed_ms=%d", connectionLogResult(err), time.Since(started).Milliseconds())
	}
}

func (m *MTP) Identity() string         { return m.key }
func (m *MTP) RecoveryIdentity() string { return m.recoveryKey }

func connectionError(err error) error {
	var authorization *mtp.DriverAuthorizationError
	if errors.As(err, &authorization) {
		return fmt.Errorf(i18n.Text("macOS 未允许临时接管 USB 设备，请在系统授权提示中允许访问后手动重新连接：%w"), err)
	}
	var code usb.Error
	if !errors.As(err, &code) {
		return err
	}
	switch code {
	case usb.ERROR_TIMEOUT:
		return fmt.Errorf(i18n.Text("手机 USB/MTP 连接超时。请保持手机解锁，重新插拔手机数据线并选择“文件传输”后再连接：%w"), err)
	case usb.ERROR_BUSY:
		return fmt.Errorf(i18n.Text("手机 USB 接口正被占用，请退出其他传输程序、照片导入程序及多余的渡舟实例后重试：%w"), err)
	case usb.ERROR_ACCESS:
		return fmt.Errorf(i18n.Text("USB 访问被拒绝，请解锁手机、检查 macOS 配件连接授权并退出其他传输程序后重试：%w"), err)
	case usb.ERROR_NOT_FOUND:
		return fmt.Errorf(i18n.Text("MTP USB 接口或端点暂不可用，请重新插拔数据线并重新选择文件传输后重试：%w"), err)
	case usb.ERROR_NO_DEVICE:
		return fmt.Errorf(i18n.Text("手机已断开或 USB 接口正在重新识别，请等待系统识别完成后重试：%w"), err)
	}
	return err
}

// Only fixed tags may be forwarded to the app's public diagnostic log.
func connectionLogResult(err error) string {
	if err == nil {
		return "ok"
	}
	if errors.Is(err, context.Canceled) {
		return "cancelled"
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return "timeout"
	}
	var code usb.Error
	if errors.As(err, &code) {
		switch code {
		case usb.ERROR_TIMEOUT:
			return "timeout"
		case usb.ERROR_NO_DEVICE:
			return "no_device"
		case usb.ERROR_ACCESS:
			return "access"
		case usb.ERROR_BUSY:
			return "busy"
		}
		return "usb_error"
	}
	return "error"
}
