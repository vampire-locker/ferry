// Adapted from OpenMTP (MIT). See ThirdPartyNotices/OpenMTP-MIT.txt.
package directory

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"ferry.local/engine/internal/transfer"
	"fmt"
	"github.com/ganeshrvel/go-mtpfs/mtp"
	"testing"
	"time"
	"unicode/utf16"
)

type fakeDevice struct {
	count       int
	calls       int
	failure     error
	omitSize    bool
	sizeFailure error
	properties  []uint16
	folderFirst bool
	modified    string
}

func encodeProperty(buf *bytes.Buffer, property uint16, handle uint32, value propertyValue) {
	binary.Write(buf, binary.LittleEndian, handle)
	binary.Write(buf, binary.LittleEndian, property)
	switch property {
	case propertyName, propertyModified:
		binary.Write(buf, binary.LittleEndian, uint16(0xffff))
		units := append(utf16.Encode([]rune(value.text)), 0)
		binary.Write(buf, binary.LittleEndian, uint8(len(units)))
		binary.Write(buf, binary.LittleEndian, units)
	case propertyFormat:
		binary.Write(buf, binary.LittleEndian, uint16(4))
		binary.Write(buf, binary.LittleEndian, uint16(value.number))
	case propertyParent:
		binary.Write(buf, binary.LittleEndian, uint16(6))
		binary.Write(buf, binary.LittleEndian, uint32(value.number))
	case propertySize:
		binary.Write(buf, binary.LittleEndian, uint16(8))
		binary.Write(buf, binary.LittleEndian, value.number)
	}
}

func (d *fakeDevice) GetData(request *mtp.Container, target interface{}) error {
	d.calls++
	if d.failure != nil {
		return d.failure
	}
	if request.Code != mtp.OC_MTP_GetObjPropList || len(request.Param) != 5 || request.Param[4] != 1 || request.Param[2] == 0xffffffff {
		return fmt.Errorf("invalid request")
	}
	property := uint16(request.Param[2])
	d.properties = append(d.properties, property)
	if property == propertySize && d.sizeFailure != nil {
		return d.sizeFailure
	}
	count := d.count + 1
	if d.omitSize && property == propertySize {
		count--
	}
	var buf bytes.Buffer
	binary.Write(&buf, binary.LittleEndian, uint32(count))
	// Deliberately reverse property order to test joining by handle, not index.
	for position := count; position > 0; position-- {
		i := position
		if property == propertySize {
			i = count - position + 1
		}
		value := propertyValue{}
		switch property {
		case propertyParent:
			value.number = 1
			if i == 1 {
				value.number = 0
			}
		case propertyName:
			value.text = fmt.Sprintf("图片😀%d.jpg", i)
			if i == 2 {
				value.text = ".hidden"
			}
		case propertyFormat:
			value.number = 0x3801
			if d.folderFirst && i == 2 {
				value.number = mtp.OFC_Association
			}
		case propertySize:
			value.number = uint64(i) * 5 * 1024 * 1024 * 1024
		case propertyModified:
			value.text = "20261022T093000Z"
			if d.modified != "" {
				value.text = d.modified
			}
		}
		encodeProperty(&buf, property, uint32(i), value)
	}
	return target.(mtp.Decoder).Decode(&buf)
}

func TestBulkDirectorySizes(t *testing.T) {
	for _, count := range []int{0, 7, 10000, 50000} {
		t.Run(fmt.Sprint(count), func(t *testing.T) {
			dev := &fakeDevice{count: count}
			phases := 0
			entries, err := List(context.Background(), dev, 65537, 1, func(string) { phases++ })
			if err != nil {
				t.Fatal(err)
			}
			if len(entries) != count || dev.calls != 5 || phases != 5 {
				t.Fatalf("entries=%d calls=%d phases=%d", len(entries), dev.calls, phases)
			}
			for _, entry := range entries {
				if entry.Size != int64(entry.ID)*5*1024*1024*1024 || entry.StorageID != 65537 || entry.Modified <= 0 {
					t.Fatalf("bad metadata: %+v", entry)
				}
			}
		})
	}
}

func TestFallbackPolicy(t *testing.T) {
	for _, code := range []mtp.RCError{0x2005, 0x2006, 0x201d, 0xa801, 0xa802, 0xa807, 0xa808, 0xa80a} {
		calls := 0
		dev := &fakeDevice{failure: code}
		_, err := Read(context.Background(), dev, true, 1, 1, nil, func() ([]transfer.Entry, error) { calls++; return []transfer.Entry{}, nil })
		if err != nil || calls != 1 || dev.calls != 1 {
			t.Fatalf("code=%v fallback=%d requests=%d err=%v", code, calls, dev.calls, err)
		}
	}
	for _, err := range []error{errors.New("LIBUSB_ERROR_TIMEOUT"), errors.New("device disconnected"), mtp.RCError(0x200f)} {
		calls := 0
		entries, got := Read(context.Background(), &fakeDevice{failure: err}, true, 1, 1, nil, func() ([]transfer.Entry, error) { calls++; return nil, nil })
		if !errors.Is(got, err) || calls != 0 || entries != nil {
			t.Fatalf("transport fell back: %v", got)
		}
	}
	calls := 0
	_, err := Read(context.Background(), &fakeDevice{count: 7, omitSize: true}, true, 1, 1, nil, func() ([]transfer.Entry, error) { calls++; return nil, nil })
	if err != nil || calls != 1 {
		t.Fatalf("invalid complete dataset did not fall back: %v", err)
	}
}

func TestRootAndCapabilityUseCompatibility(t *testing.T) {
	for _, item := range []struct {
		supported bool
		parent    uint32
	}{{true, 0}, {true, mtp.GOH_ROOT_PARENT}, {false, 1}} {
		dev := &fakeDevice{}
		calls := 0
		_, err := Read(context.Background(), dev, item.supported, 1, item.parent, nil, func() ([]transfer.Entry, error) { calls++; return nil, nil })
		if err != nil || dev.calls != 0 || calls != 1 {
			t.Fatal("incorrect compatibility route")
		}
	}
	if Supported(nil) || !Supported(&mtp.DeviceInfo{OperationsSupported: []uint16{mtp.OC_MTP_GetObjPropList}}) {
		t.Fatal("capability detection")
	}
}

func TestCancelBetweenProperties(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	dev := &fakeDevice{count: 7}
	stages := 0
	fallbacks := 0
	entries, err := Read(ctx, dev, true, 1, 1, func(string) {
		stages++
		if stages == 2 {
			cancel()
		}
	}, func() ([]transfer.Entry, error) { fallbacks++; return nil, nil })
	if !errors.Is(err, context.Canceled) || entries != nil || dev.calls != 1 || fallbacks != 0 {
		t.Fatalf("cancel: requests=%d err=%v", dev.calls, err)
	}
}

func TestRejectMalformedProperties(t *testing.T) {
	var valid bytes.Buffer
	binary.Write(&valid, binary.LittleEndian, uint32(1))
	encodeProperty(&valid, propertyName, 42, propertyValue{text: "中文😀.jpg"})
	data := valid.Bytes()
	for length := 0; length < len(data); length++ {
		list := &propertyList{property: propertyName}
		if err := list.Decode(bytes.NewReader(data[:length])); !errors.Is(err, ErrUnsupported) {
			t.Fatalf("accepted truncation at %d", length)
		}
	}
	for _, mutate := range []func([]byte) []byte{
		func(b []byte) []byte { return append(b, 1) },
		func(b []byte) []byte { b[8] = 4; return b },
		func(b []byte) []byte { b[10] = 8; return b },
		func(b []byte) []byte { b[len(b)-1] = 1; return b },
		func(b []byte) []byte { b[0] = 2; return append(b, b[4:]...) },
	} {
		list := &propertyList{property: propertyName}
		if err := list.Decode(bytes.NewReader(mutate(append([]byte(nil), data...)))); err == nil {
			t.Fatal("accepted malformed data")
		}
	}
	list := &propertyList{property: propertyName}
	if err := list.Decode(bytes.NewReader(data)); err != nil || list.values[42].text != "中文😀.jpg" {
		t.Fatalf("UTF-16: %v", err)
	}
}

func TestBulkDirectoryDateZonesAndBoundaries(t *testing.T) {
	previous := time.Local
	t.Cleanup(func() { time.Local = previous })
	time.Local = time.FixedZone("UTC+8", 8*60*60)
	for _, tc := range []struct {
		value string
		want  string
	}{
		{"20260228T193140", "2026-02-28T19:31:40+08:00"},
		{"20261231T235959", "2026-12-31T23:59:59+08:00"},
		{"20260301T000000.", "2026-03-01T00:00:00+08:00"},
		{"20260228T193140.123", "2026-02-28T19:31:40.123+08:00"},
		{"20260228T193140Z", "2026-02-28T19:31:40Z"},
		{"20260228T193140+0800", "2026-02-28T19:31:40+08:00"},
		{"20260228T193140-0500", "2026-02-28T19:31:40-05:00"},
	} {
		t.Run(tc.value, func(t *testing.T) {
			dev := &fakeDevice{count: 2, modified: tc.value}
			entries, err := List(context.Background(), dev, 65537, 1, nil)
			if err != nil {
				t.Fatal(err)
			}
			want, err := time.Parse(time.RFC3339Nano, tc.want)
			if err != nil {
				t.Fatal(err)
			}
			if len(entries) != 2 {
				t.Fatalf("entries=%+v, want two entries", entries)
			}
			for _, entry := range entries {
				if entry.Modified == want.Unix() {
					continue
				}
				t.Fatalf("entries=%+v, want modified=%d", entries, want.Unix())
			}
		})
	}
}

func TestFastDirectorySkipsSizeForFiftyThousandObjects(t *testing.T) {
	dev := &fakeDevice{count: 50000, folderFirst: true, sizeFailure: errors.New("size must not be read")}
	entries, err := ReadForBrowse(context.Background(), dev, true, 65537, 1, nil, false,
		func() ([]transfer.Entry, error) { t.Fatal("unexpected fallback"); return nil, nil })
	if err != nil || len(entries) != 50000 || dev.calls != 4 {
		t.Fatalf("entries=%d calls=%d err=%v", len(entries), dev.calls, err)
	}
	for _, code := range dev.properties {
		if code == propertySize {
			t.Fatal("read expensive size property")
		}
	}
	for _, e := range entries {
		if e.Modified <= 0 || e.Name == "" || e.StorageID != 65537 {
			t.Fatalf("missing browsing metadata: %+v", e)
		}
		if e.IsDirectory && e.Size != 0 || !e.IsDirectory && e.Size != -1 {
			t.Fatalf("wrong size state: %+v", e)
		}
	}
}

func TestOnDemandSizesUseOneRequestAndPreserve64Bits(t *testing.T) {
	dev := &fakeDevice{count: 50000}
	sizes, err := Sizes(context.Background(), dev, 1)
	if err != nil || len(sizes) != 50001 || dev.calls != 1 || dev.properties[0] != propertySize {
		t.Fatalf("sizes=%d calls=%d err=%v", len(sizes), dev.calls, err)
	}
	for _, value := range sizes {
		if value.Size != int64(value.ID)*5*1024*1024*1024 {
			t.Fatal("size truncated")
		}
	}
}

func TestFastDirectoryTransportFailureDoesNotFallBack(t *testing.T) {
	failure := errors.New("USB timeout")
	fallback := false
	entries, err := ReadForBrowse(context.Background(), &fakeDevice{failure: failure}, true, 1, 1, nil, false,
		func() ([]transfer.Entry, error) { fallback = true; return nil, nil })
	if !errors.Is(err, failure) || entries != nil || fallback {
		t.Fatalf("%v fallback=%v", err, fallback)
	}
	_, err = Sizes(context.Background(), &fakeDevice{failure: failure}, 1)
	if !errors.Is(err, failure) || errors.Is(err, ErrUnsupported) {
		t.Fatal(err)
	}
}
