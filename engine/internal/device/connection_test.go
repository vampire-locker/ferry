package device

import (
	"context"
	"errors"
	"fmt"
	"github.com/ganeshrvel/usb"
	"strings"
	"testing"
)

func TestConnectionTimeoutKeepsErrorIdentityAndExplainsRecovery(t *testing.T) {
	err := connectionError(fmt.Errorf("open: %w", usb.ERROR_TIMEOUT))
	if !errors.Is(err, usb.ERROR_TIMEOUT) || !strings.Contains(err.Error(), "手机数据线") {
		t.Fatalf("%v", err)
	}
}

func TestConnectionLogResultsContainOnlyFixedTags(t *testing.T) {
	for _, tc := range []struct {
		err error
		tag string
	}{
		{nil, "ok"}, {context.Canceled, "cancelled"}, {context.DeadlineExceeded, "timeout"},
		{usb.ERROR_TIMEOUT, "timeout"}, {usb.ERROR_NO_DEVICE, "no_device"}, {usb.ERROR_ACCESS, "access"},
		{usb.ERROR_BUSY, "busy"}, {usb.ERROR_IO, "usb_error"},
		{fmt.Errorf("private path /Users/example/photo.jpg: %w", usb.ERROR_TIMEOUT), "timeout"},
		{errors.New("private device serial and file name"), "error"},
	} {
		if got := connectionLogResult(tc.err); got != tc.tag {
			t.Fatalf("got=%q want=%q", got, tc.tag)
		}
	}
}
