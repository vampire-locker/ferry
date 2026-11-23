package mtp

import (
	"errors"
	"fmt"
	"regexp"

	"github.com/ganeshrvel/usb"
)

func candidateFromDeviceDescriptor(d *usb.Device) *Device {
	dd, err := d.GetDeviceDescriptor()
	if err != nil {
		return nil
	}
	// Ferry only uses the active configuration. Choosing endpoints from an
	// inactive configuration can leave macOS with no matching endpoint pipes.
	cdecs, err := d.GetActiveConfigDescriptor()
	if err != nil {
		return nil
	}
	// Prefer the standard MTP/PTP interface before vendor-specific fallbacks.
	for _, standard := range []bool{true, false} {
		for _, iface := range cdecs.Interfaces {
			for _, a := range iface.AltSetting {
				isStandard := a.InterfaceClass == 6 && a.InterfaceSubClass == 1 && a.InterfaceProtocol == 1
				if standard != isStandard {
					continue
				}
				if len(a.EndPoints) != 3 {
					continue
				}
				m := Device{}
				for _, s := range a.EndPoints {
					switch {
					case s.Direction() == usb.ENDPOINT_IN && s.TransferType() == usb.TRANSFER_TYPE_INTERRUPT:
						m.eventEP = s.EndpointAddress
					case s.Direction() == usb.ENDPOINT_IN && s.TransferType() == usb.TRANSFER_TYPE_BULK:
						m.fetchEP = s.EndpointAddress
					case s.Direction() == usb.ENDPOINT_OUT && s.TransferType() == usb.TRANSFER_TYPE_BULK:
						m.sendEP = s.EndpointAddress
					}
				}
				if m.sendEP > 0 && m.fetchEP > 0 && m.eventEP > 0 {
					m.devDescr = *dd
					m.ifaceDescr = a
					m.dev = d.Ref()
					m.configValue = cdecs.ConfigurationValue
					return &m
				}
			}
		}
	}

	return nil
}

// FindDevices finds likely MTP devices without opening them.
func FindDevices(c *usb.Context) ([]*Device, error) {
	l, err := c.GetDeviceList()
	if err != nil {
		return nil, err
	}

	var cands []*Device
	for _, d := range l {
		cand := candidateFromDeviceDescriptor(d)
		if cand != nil {
			cands = append(cands, cand)
		}
	}

	if len(l) > 0 {
		l.Done()
	}

	return cands, nil
}

// selectDevice finds a device that matches given pattern
func selectDevice(cands []*Device, pattern string) (*Device, error) {
	var selected *Device
	defer func() {
		for _, cand := range cands {
			if cand != selected {
				cand.Close()
				cand.Done()
			}
		}
	}()
	if pattern == "" && len(cands) > 1 {
		for _, cand := range cands {
			if cand.AllowDriverDetach {
				return nil, ErrMultipleDevices
			}
		}
	}
	re, err := regexp.Compile(pattern)
	if err != nil {
		return nil, err
	}

	var found []*Device
	var openErrors []error
	for _, cand := range cands {
		if err := cand.Open(); err != nil {
			openErrors = append(openErrors, err)
			continue
		}
		if pattern == "" {
			found = append(found, cand)
			continue
		}
		id, err := cand.ID()
		if err != nil {
			return nil, fmt.Errorf("read MTP USB identity: %w", err)
		}
		if re.FindString(id) != "" {
			found = append(found, cand)
		}
	}

	if len(found) == 0 {
		if len(openErrors) > 0 {
			return nil, fmt.Errorf("open MTP USB interface: %w", errors.Join(openErrors...))
		}
		return nil, fmt.Errorf("no device matched")
	}

	if len(found) > 1 {
		return nil, ErrMultipleDevices
	}

	selected = found[0]
	return selected, nil
}

// SelectDevice returns opened MTP device that matches the given pattern.
func SelectDevice(pattern string) (*Device, error) {
	return SelectDeviceWithDriverDetach(pattern, false)
}

// SelectDeviceWithDriverDetach opts into the platform's user-authorized device
// capture path. The default SelectDevice API retains its previous behavior.
func SelectDeviceWithDriverDetach(pattern string, allow bool) (*Device, error) {
	c := usb.NewContext()

	devs, err := FindDevices(c)
	if err != nil {
		return nil, err
	}
	if len(devs) == 0 {
		return nil, fmt.Errorf("no MTP devices found")
	}
	for _, dev := range devs {
		dev.AllowDriverDetach = allow
	}

	return selectDevice(devs, pattern)
}

// SelectDeviceForDebugging returns opened MTP device that matches the given pattern and debug information are set true
func SelectDeviceWithDebugging(pattern string, allowDebugging bool) (*Device, error) {
	c := usb.NewContext()

	devs, err := FindDevices(c)
	if err != nil {
		return nil, err
	}
	if len(devs) == 0 {
		return nil, fmt.Errorf("no MTP devices found")
	}

	if allowDebugging {
		for _, _dev := range devs {
			_dev.USBDebug = allowDebugging
			_dev.DataDebug = allowDebugging
			_dev.MTPDebug = allowDebugging
		}
	}

	return selectDevice(devs, pattern)
}
