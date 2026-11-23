package mtp

import (
	"errors"
	"testing"

	"github.com/ganeshrvel/usb"
)

func TestAlternateSettingDoesNotResetActiveEndpoints(t *testing.T) {
	for _, tc := range []struct {
		active, wanted byte
		readErr        error
		sets           int
	}{
		{0, 0, nil, 0}, {2, 2, nil, 0}, {0, 1, nil, 1}, {0, 0, usb.ERROR_TIMEOUT, 0},
	} {
		sets := 0
		err := activateAlternateSetting(tc.wanted, func() (byte, error) { return tc.active, tc.readErr }, func(alt byte) error {
			sets++
			if alt != tc.wanted {
				t.Errorf("alternate=%d", alt)
			}
			return nil
		})
		if !errors.Is(err, tc.readErr) || sets != tc.sets {
			t.Fatalf("case %+v: err=%v sets=%d", tc, err, sets)
		}
	}
	if err := activateAlternateSetting(1, func() (byte, error) { return 0, nil }, func(byte) error { return usb.ERROR_PIPE }); err != usb.ERROR_PIPE {
		t.Fatal(err)
	}
}

func TestSessionRecoveryRequiresCaptureAndCompleteResponse(t *testing.T) {
	already := RCError(RC_SessionAlreadyOpened)
	for _, tc := range []struct {
		name                    string
		captured                bool
		first, closeErr, second error
		opens, closes           int
		want                    error
	}{
		{"normal", true, nil, nil, nil, 1, 0, nil},
		{"uncaptured", false, already, nil, nil, 1, 0, already},
		{"timeout", true, usb.ERROR_TIMEOUT, nil, nil, 1, 0, usb.ERROR_TIMEOUT},
		{"sync", true, SyncError("bad packet"), nil, nil, 1, 0, SyncError("bad packet")},
		{"recover", true, already, nil, nil, 2, 1, nil},
		{"close fails", true, already, usb.ERROR_TIMEOUT, nil, 1, 1, usb.ERROR_TIMEOUT},
		{"bounded retry", true, already, nil, already, 2, 1, already},
	} {
		t.Run(tc.name, func(t *testing.T) {
			opens, closes := 0, 0
			err := openSessionWithRecovery(tc.captured, func() error {
				opens++
				if opens == 1 {
					return tc.first
				}
				return tc.second
			}, func() error { closes++; return tc.closeErr })
			if !errors.Is(err, tc.want) || opens != tc.opens || closes != tc.closes {
				t.Fatalf("err=%v opens=%d closes=%d", err, opens, closes)
			}
		})
	}
}
