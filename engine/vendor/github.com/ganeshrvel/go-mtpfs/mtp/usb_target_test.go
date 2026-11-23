package mtp

import (
	"errors"
	"testing"

	"github.com/ganeshrvel/usb"
)

func TestTargetSerialRejectsReplacementAndPreservesReadFailure(t *testing.T) {
	reads := 0
	if err := verifyUSBTargetSerial("", func() (string, error) { reads++; return "", nil }); err != nil || reads != 0 {
		t.Fatal("legacy selection read a serial")
	}
	if err := verifyUSBTargetSerial("phone", func() (string, error) { return "phone", nil }); err != nil {
		t.Fatal(err)
	}
	if err := verifyUSBTargetSerial("phone", func() (string, error) { return "other", nil }); !errors.Is(err, ErrUSBTargetNotFound) {
		t.Fatal(err)
	}
	if err := verifyUSBTargetSerial("phone", func() (string, error) { return "", usb.ERROR_TIMEOUT }); !errors.Is(err, usb.ERROR_TIMEOUT) {
		t.Fatal(err)
	}
}

func TestUSBTargetMatchesPhysicalRouteAndDescriptor(t *testing.T) {
	target := USBDeviceTarget{BusNumber: 2, PortNumbers: []int{1, 3}, VendorID: 10, ProductID: 20}
	for _, tc := range []struct {
		bus             uint8
		ports           []uint8
		vendor, product uint16
		want            bool
	}{
		{2, []uint8{1, 3}, 10, 20, true},
		{3, []uint8{1, 3}, 10, 20, false},
		{2, []uint8{1, 4}, 10, 20, false},
		{2, []uint8{1, 3, 1}, 10, 20, false},
		{2, []uint8{1, 3}, 11, 20, false},
		{2, []uint8{1, 3}, 10, 21, false},
	} {
		if got := target.matches(tc.bus, tc.ports, tc.vendor, tc.product); got != tc.want {
			t.Fatalf("%+v: %v", tc, got)
		}
	}
}

func TestUSBSelectionNeverOpensOtherPhonesOrFallsBack(t *testing.T) {
	for _, scenario := range []string{"selected", "missing", "ambiguous", "open failure"} {
		t.Run(scenario, func(t *testing.T) {
			phones := []*Device{{}, {}, {}}
			opened, released := map[*Device]int{}, map[*Device]int{}
			target := USBDeviceTarget{PortNumbers: []int{1}}
			selected, err := selectUSBTarget(phones, target, func(d *Device) bool {
				if scenario == "missing" {
					return false
				}
				return d == phones[1] || scenario == "ambiguous"
			}, func(d *Device) error {
				opened[d]++
				if scenario == "open failure" {
					return usb.ERROR_ACCESS
				}
				return nil
			}, func(d *Device) { released[d]++ })
			if opened[phones[0]] != 0 || opened[phones[2]] != 0 {
				t.Fatal("opened an unselected phone")
			}
			if scenario == "selected" {
				if err != nil || selected != phones[1] || opened[phones[1]] != 1 || released[phones[1]] != 0 {
					t.Fatalf("%v %v", selected, err)
				}
			} else {
				if selected != nil || err == nil || len(released) != 3 {
					t.Fatalf("failed selection leaked device: %v %v %v", selected, err, released)
				}
				if scenario == "open failure" && !errors.Is(err, usb.ERROR_ACCESS) {
					t.Fatal(err)
				}
				if scenario != "open failure" && len(opened) != 0 {
					t.Fatal("opened a phone before resolving selection")
				}
			}
			if released[phones[0]] != 1 || released[phones[2]] != 1 {
				t.Fatal("unselected references leaked")
			}
		})
	}
}
