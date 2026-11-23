package mtp

import (
	"errors"
	"fmt"

	"github.com/ganeshrvel/usb"
)

var ErrMultipleDevices = errors.New("multiple MTP USB devices; select one before connecting")
var ErrUSBTargetNotFound = errors.New("selected USB device is unavailable or changed")

func verifyUSBTargetSerial(expected string, read func() (string, error)) error {
	if expected == "" {
		return nil
	}
	serial, err := read()
	if err != nil {
		return fmt.Errorf("read selected USB serial: %w", err)
	}
	if serial != expected {
		return ErrUSBTargetNotFound
	}
	return nil
}

// USBDeviceTarget is matched before opening or claiming any USB interface.
// Bus and port topology survive capture's device-address re-enumeration.
type USBDeviceTarget struct {
	BusNumber    uint8
	PortNumbers  []int
	VendorID     uint16
	ProductID    uint16
	SerialNumber string
}

func (t USBDeviceTarget) matches(bus uint8, ports []uint8, vendor, product uint16) bool {
	if len(t.PortNumbers) == 0 || len(t.PortNumbers) != len(ports) || t.BusNumber != bus || t.VendorID != vendor || t.ProductID != product {
		return false
	}
	for i, port := range ports {
		if int(port) != t.PortNumbers[i] {
			return false
		}
	}
	return true
}

// SelectDeviceByUSBTarget opens only the unique selected physical device. It
// never falls back to another phone when the target disappears.
func SelectDeviceByUSBTarget(target USBDeviceTarget, allow bool) (*Device, error) {
	c := usb.NewContext()
	devs, err := FindDevices(c)
	if err != nil {
		return nil, err
	}
	return selectUSBTarget(devs, target, func(d *Device) bool {
		ports, err := d.dev.GetPortNumbers()
		return err == nil && target.matches(d.dev.GetBusNumber(), ports, d.devDescr.IdVendor, d.devDescr.IdProduct)
	}, func(d *Device) error {
		d.AllowDriverDetach = allow
		d.expectedSerial = target.SerialNumber
		return d.Open()
	}, func(d *Device) { d.Close(); d.Done() })
}

// Injectable operations keep target isolation tests independent of real USB.
func selectUSBTarget(devs []*Device, target USBDeviceTarget, matches func(*Device) bool, open func(*Device) error, release func(*Device)) (*Device, error) {
	var selected *Device
	defer func() {
		for _, d := range devs {
			if d != selected {
				release(d)
			}
		}
	}()
	var found []*Device
	for _, d := range devs {
		if matches(d) {
			found = append(found, d)
		}
	}
	if len(target.PortNumbers) == 0 || len(found) != 1 {
		return nil, ErrUSBTargetNotFound
	}
	if err := open(found[0]); err != nil {
		return nil, err
	}
	selected = found[0]
	return selected, nil
}
