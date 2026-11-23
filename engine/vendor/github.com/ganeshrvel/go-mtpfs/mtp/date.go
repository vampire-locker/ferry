package mtp

import (
	"fmt"
	"strings"
	"time"
)

// ParseDateTime interprets timezone-less MTP dates in the host's local timezone,
// assuming the phone and host share a timezone. Explicit Z or numeric offsets
// always take precedence. Bulk properties and ObjectInfo must use the same rules.
func ParseDateTime(value string) (time.Time, error) {
	if value == "" {
		return time.Time{}, nil
	}
	// Some devices append dots; fractional seconds are handled by time.ParseInLocation.
	value = strings.TrimRight(value, ".")
	for _, layout := range []string{timeFormat + "Z0700", timeFormat} {
		if date, err := time.ParseInLocation(layout, value, time.Local); err == nil {
			return date, nil
		}
	}
	return time.Time{}, fmt.Errorf("unsupported MTP date")
}
