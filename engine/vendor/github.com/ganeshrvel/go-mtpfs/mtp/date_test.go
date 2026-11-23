package mtp

import (
	"bytes"
	"reflect"
	"testing"
	"time"
)

func TestDecodeTimeZonesAndBoundaries(t *testing.T) {
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
		{"20260228T193140.123Z", "2026-02-28T19:31:40.123Z"},
		{"20260228T193140+0800", "2026-02-28T19:31:40+08:00"},
		{"20260228T193140-0500", "2026-02-28T19:31:40-05:00"},
	} {
		t.Run(tc.value, func(t *testing.T) {
			encoded, err := encodeStr(make([]byte, 2*len(tc.value)+3), tc.value)
			if err != nil {
				t.Fatal(err)
			}
			var got time.Time
			if err := decodeTime(bytes.NewReader(encoded), reflect.ValueOf(&got).Elem()); err != nil {
				t.Fatal(err)
			}
			want, err := time.Parse(time.RFC3339Nano, tc.want)
			if err != nil {
				t.Fatal(err)
			}
			if !got.Equal(want) {
				t.Fatalf("decoded %s, want %s", got.Format(time.RFC3339Nano), tc.want)
			}
		})
	}
}

func TestParseDateTimeLocalZones(t *testing.T) {
	previous := time.Local
	t.Cleanup(func() { time.Local = previous })
	for _, tc := range []struct {
		zone  string
		value string
		want  string
	}{
		{"Asia/Shanghai", "20240229T235959", "2024-02-29T23:59:59+08:00"},
		{"America/New_York", "20260228T003000", "2026-02-28T00:30:00-05:00"},
		{"America/New_York", "20260630T233000", "2026-06-30T23:30:00-04:00"},
		{"UTC", "20261231T235959", "2026-12-31T23:59:59Z"},
	} {
		t.Run(tc.zone+"/"+tc.value, func(t *testing.T) {
			location, err := time.LoadLocation(tc.zone)
			if err != nil {
				t.Fatal(err)
			}
			time.Local = location
			got, err := ParseDateTime(tc.value)
			if err != nil {
				t.Fatal(err)
			}
			if got.Format(time.RFC3339Nano) != tc.want {
				t.Fatalf("decoded %s, want %s", got.Format(time.RFC3339Nano), tc.want)
			}
		})
	}
}

func TestParseDateTimeMissingAndInvalid(t *testing.T) {
	if date, err := ParseDateTime(""); err != nil || !date.IsZero() {
		t.Fatalf("missing date=%v, error=%v", date, err)
	}
	for _, value := range []string{"bad date", ".", "20260229T120000", "20260228T193140BAD"} {
		if _, err := ParseDateTime(value); err == nil {
			t.Fatalf("accepted invalid date %q", value)
		}
	}
}
