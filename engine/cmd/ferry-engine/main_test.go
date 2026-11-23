package main

import (
	"context"
	"errors"
	"ferry.local/engine/internal/transfer"
	"reflect"
	"testing"
)

type bootstrapDevice struct {
	transfer.Device // Any accidental file operation during bootstrap panics.
	trace           *[]string
	err             error
}

func (d bootstrapDevice) Connect(context.Context) (string, []transfer.Storage, error) {
	*d.trace = append(*d.trace, "connect")
	return "phone", []transfer.Storage{{ID: 1}}, d.err
}

func TestConnectionMustDropPrivilegesBeforeReturningUsableSession(t *testing.T) {
	failure := errors.New("failed")
	for _, tc := range []struct {
		name                string
		connectErr, dropErr error
		trace               []string
	}{
		{"success", nil, nil, []string{"connect", "drop"}},
		{"connection failure", failure, nil, []string{"connect"}},
		{"drop failure", nil, failure, []string{"connect", "drop"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var trace []string
			name, storages, err := initializeConnection(context.Background(), bootstrapDevice{trace: &trace, err: tc.connectErr}, func() error {
				trace = append(trace, "drop")
				return tc.dropErr
			})
			if !reflect.DeepEqual(trace, tc.trace) {
				t.Fatal(trace)
			}
			if tc.connectErr != nil || tc.dropErr != nil {
				if !errors.Is(err, failure) || name != "" || len(storages) != 0 {
					t.Fatalf("usable failed bootstrap: %s %v %v", name, storages, err)
				}
			} else if err != nil || name != "phone" || len(storages) != 1 {
				t.Fatalf("%s %v %v", name, storages, err)
			}
		})
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	var trace []string
	_, _, err := initializeConnection(ctx, bootstrapDevice{trace: &trace}, nil)
	if !errors.Is(err, context.Canceled) || len(trace) != 0 {
		t.Fatal("cancelled bootstrap accessed device")
	}
}

func TestPrivilegedDiagnosticsStayOnTheEventChannel(t *testing.T) {
	var events []transfer.Event
	writer := engineDiagnosticWriter{emit: func(e transfer.Event) { events = append(events, e) }}
	line := []byte("directory property=dc0b elapsed=1s entries=50000 error=<nil>\n")
	n, err := writer.Write(line)
	if err != nil || n != len(line) || len(events) != 1 || events[0].Type != "diagnostic" || events[0].Message != string(line) {
		t.Fatalf("diagnostic=%v bytes=%d error=%v", events, n, err)
	}
}
