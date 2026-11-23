package mtp

import "fmt"

// SET_INTERFACE even to the current alternate setting resets endpoint state.
// In particular, Android may stop accepting MTP commands after that reset.
func activateAlternateSetting(wanted byte, get func() (byte, error), set func(byte) error) error {
	active, err := get()
	if err != nil {
		return fmt.Errorf("read active alternate setting: %w", err)
	}
	if active == wanted {
		return nil
	}
	return set(wanted)
}

// Only a captured device with a complete MTP response permits session recovery.
// USB/synchronization errors never trigger more traffic or a device reset.
func openSessionWithRecovery(captured bool, open, close func() error) error {
	err := open()
	if !captured || err != RCError(RC_SessionAlreadyOpened) {
		return err
	}
	if err := close(); err != nil {
		return fmt.Errorf("close previous MTP session: %w", err)
	}
	return open()
}
