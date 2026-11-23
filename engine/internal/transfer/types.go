package transfer

import (
	"context"
	"io"
)

// Device exposes read-only operations. No phone mutation is part of this API.
type Device interface {
	Connect(context.Context) (string, []Storage, error)
	List(context.Context, uint32, uint32) ([]Entry, error)
	Info(context.Context, uint32) (Entry, error)
	Read(context.Context, uint32, io.Writer) error
	Identity() string
	Close()
}

// ThumbnailDevice is optional; devices without it use the bounded image fallback.
type ThumbnailDevice interface {
	Thumbnail(context.Context, uint32, io.Writer) error
}

// Optional browsing optimizations. Device.List and Info retain full metadata
// for download planning, preflight space checks and content validation.
type BrowsingDevice interface {
	ListForBrowse(context.Context, uint32, uint32, bool) ([]Entry, error)
	Sizes(context.Context, uint32, uint32) ([]ObjectSize, error)
}

type ObjectSize struct {
	ID   uint32 `json:"id"`
	Size int64  `json:"size"`
}

type Storage struct {
	ID       uint32 `json:"id"`
	Name     string `json:"name"`
	Capacity uint64 `json:"capacity"`
	Free     uint64 `json:"free"`
}

type Entry struct {
	ID          uint32 `json:"id"`
	StorageID   uint32 `json:"storageID"`
	Name        string `json:"name"`
	IsDirectory bool   `json:"isDirectory"`
	Size        int64  `json:"size"`
	Modified    int64  `json:"modified"`
}

// USBTarget routes every request, including helper restarts, to one phone.
type USBTarget struct {
	BusNumber    uint8  `json:"busNumber"`
	PortNumbers  []int  `json:"portNumbers"`
	VendorID     uint16 `json:"vendorID"`
	ProductID    uint16 `json:"productID"`
	SerialNumber string `json:"serialNumber"`
}

type Request struct {
	// Optional cooperative download requests share one in-memory task and yield
	// between files. Omitted action keeps the legacy one-request download API.
	DownloadID       string     `json:"downloadID,omitempty"`
	DownloadAction   string     `json:"downloadAction,omitempty"`
	ResumeToken      string     `json:"resumeToken,omitempty"`
	RecoveryPath     string     `json:"recoveryPath,omitempty"`
	RecoveryIdentity string     `json:"recoveryIdentity,omitempty"`
	DurableRecovery  bool       `json:"durableRecovery,omitempty"`
	SourceDirectory  []string   `json:"sourceDirectory,omitempty"`
	SourceSelection  []Entry    `json:"sourceSelection,omitempty"`
	SourceStorage    *Storage   `json:"sourceStorage,omitempty"`
	USBTarget        *USBTarget `json:"usbTarget,omitempty"`
	DeviceKey        string     `json:"deviceKey"`
	Operation        string     `json:"operation"`
	StorageID        uint32     `json:"storageID"`
	ParentID         uint32     `json:"parentID"`
	ObjectIDs        []uint32   `json:"objectIDs"`
	Destination      string     `json:"destination"`
	// Empty preserves the legacy task-folder layout for older CLI clients.
	DownloadLayout       string            `json:"downloadLayout,omitempty"`
	ReportDirectory      string            `json:"reportDirectory,omitempty"`
	UsePhotoCreationDate bool              `json:"usePhotoCreationDate,omitempty"`
	ArchivePhotosByMonth bool              `json:"archivePhotosByMonth,omitempty"`
	ArchiveVideosByMonth bool              `json:"archiveVideosByMonth,omitempty"`
	PromptConflicts      bool              `json:"promptConflicts,omitempty"`
	ConflictDecision     *ConflictDecision `json:"conflictDecision,omitempty"`
	ShowHiddenFiles      bool              `json:"showHiddenFiles"`
	// Omitted preserves the full-metadata behavior of existing CLI clients.
	IncludeSizes *bool `json:"includeSizes,omitempty"`
}

type Event struct {
	// --serve adds ready after successful completion; authorization_denied is
	// an error state requiring explicit user action rather than auto retry.
	// diagnostic carries helper logs in Message; it is never a terminal event.
	// yielded ends a cooperative download request at a file boundary; ready
	// still follows before another request may use the serial session.
	ObjectID         uint32            `json:"objectID,omitempty"`
	DeviceKey        string            `json:"deviceKey,omitempty"`
	Type             string            `json:"type"`
	Message          string            `json:"message,omitempty"`
	DeviceName       string            `json:"deviceName,omitempty"`
	Storages         []Storage         `json:"storages,omitempty"`
	Entries          []Entry           `json:"entries,omitempty"`
	Sizes            []ObjectSize      `json:"sizes,omitempty"`
	CurrentFile      string            `json:"currentFile,omitempty"`
	Completed        int               `json:"completed,omitempty"`
	Total            int               `json:"total,omitempty"`
	Bytes            int64             `json:"bytes,omitempty"`
	TotalBytes       int64             `json:"totalBytes,omitempty"`
	Output           string            `json:"output,omitempty"`
	ReportPath       string            `json:"reportPath,omitempty"`
	State            string            `json:"state,omitempty"`
	Conflict         *DownloadConflict `json:"conflict,omitempty"`
	Skipped          int               `json:"skipped,omitempty"`
	ResumeToken      string            `json:"resumeToken,omitempty"`
	RecoveryPath     string            `json:"recoveryPath,omitempty"`
	RecoveryIdentity string            `json:"recoveryIdentity,omitempty"`
	// Logical progress without a new device read: recovery reuse or an early skip.
	ReusedBytes int64 `json:"reusedBytes,omitempty"`
}

type DownloadConflict struct {
	ID               string   `json:"id"`
	Kind             string   `json:"kind"`
	TargetPath       string   `json:"targetPath"`
	Name             string   `json:"name"`
	ExistingSize     int64    `json:"existingSize"`
	ExistingModified int64    `json:"existingModified"`
	IncomingSize     int64    `json:"incomingSize"`
	IncomingModified int64    `json:"incomingModified"`
	CanReplace       bool     `json:"canReplace"`
	Candidates       []string `json:"candidates,omitempty"`
}

type ConflictDecision struct {
	ID         string `json:"id"`
	Choice     string `json:"choice"`
	ApplyToAll bool   `json:"applyToAll,omitempty"`
	Directory  string `json:"directory,omitempty"`
}

type Item struct {
	RecoveryIndex       int    `json:"recoveryIndex,omitempty"`
	RecoveryTarget      string `json:"recoveryTarget,omitempty"`
	SourcePath          string `json:"sourcePath,omitempty"`
	ArchiveDate         string `json:"archiveDate,omitempty"`
	ArchiveDateSource   string `json:"archiveDateSource,omitempty"`
	ArchiveDateWarning  string `json:"archiveDateWarning,omitempty"`
	PhotoCreationTime   int64  `json:"photoCreationTime,omitempty"`
	CreationDateWarning string `json:"creationDateWarning,omitempty"`
	Entry               Entry  `json:"entry"`
	Path                string `json:"path"`
	State               string `json:"state"`
	SHA256              string `json:"sha256,omitempty"`
	Error               string `json:"error,omitempty"`
	ConflictAction      string `json:"conflictAction,omitempty"`
}

type Report struct {
	Output   string `json:"output,omitempty"`
	Version  int    `json:"version"`
	Started  string `json:"started"`
	Finished string `json:"finished,omitempty"`
	Device   string `json:"device"`
	State    string `json:"state"`
	Items    []Item `json:"items"`
	Error    string `json:"error,omitempty"`
}
