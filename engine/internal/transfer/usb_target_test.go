package transfer

import (
	"encoding/json"
	"reflect"
	"testing"
)

func TestRequestUSBTargetProtocol(t *testing.T) {
	var req Request
	if err := json.Unmarshal([]byte(`{"operation":"connect","usbTarget":{"busNumber":2,"portNumbers":[1,3],"vendorID":10,"productID":20,"serialNumber":"phone"}}`), &req); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(req.USBTarget, &USBTarget{BusNumber: 2, PortNumbers: []int{1, 3}, VendorID: 10, ProductID: 20, SerialNumber: "phone"}) {
		t.Fatalf("%+v", req.USBTarget)
	}
	encoded, err := json.Marshal(req)
	if err != nil {
		t.Fatal(err)
	}
	var roundtrip Request
	if err := json.Unmarshal(encoded, &roundtrip); err != nil || !reflect.DeepEqual(req, roundtrip) {
		t.Fatalf("%s %v", encoded, err)
	}
	var legacy Request
	if err := json.Unmarshal([]byte(`{"operation":"connect"}`), &legacy); err != nil || legacy.USBTarget != nil {
		t.Fatalf("legacy request: %+v %v", legacy, err)
	}
}
