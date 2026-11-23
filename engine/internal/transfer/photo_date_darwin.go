package transfer

/*
#cgo LDFLAGS: -framework ImageIO -framework CoreGraphics -framework CoreFoundation
#include <ImageIO/ImageIO.h>
#include <CoreGraphics/CoreGraphics.h>
#include <sys/attr.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>
#include <stdint.h>

// ImageIO reads metadata through pread, without loading or decoding the image.
// The descriptor is opened by os.Root and remains owned by Go.
static size_t ferry_image_read(void *info, void *buffer, off_t position, size_t count) {
    ssize_t result;
    do { result = pread((int)(intptr_t)info, buffer, count, position); }
    while (result < 0 && errno == EINTR);
    return result > 0 ? (size_t)result : 0;
}

typedef struct {
    char original[64];
    char offset[32];
    char subsecond[64];
} ferry_photo_date;

static int ferry_exif_string(CFDictionaryRef exif, CFStringRef key, char *buffer, size_t size) {
    CFTypeRef value = CFDictionaryGetValue(exif, key);
    if (!value) return 0;
    if (CFGetTypeID(value) != CFStringGetTypeID()) return -1;
    if (!CFStringGetCString((CFStringRef)value, buffer, size, kCFStringEncodingUTF8)) return -1;
    return 1;
}

static ferry_photo_date ferry_read_photo_date(int fd) {
    ferry_photo_date date = {0};
    struct stat status;
    if (fstat(fd, &status) != 0 || !S_ISREG(status.st_mode) || status.st_size <= 0) return date;
    CGDataProviderDirectCallbacks callbacks = {0, NULL, NULL, ferry_image_read, NULL};
    CGDataProviderRef provider = CGDataProviderCreateDirect((void *)(intptr_t)fd, status.st_size, &callbacks);
    if (!provider) return date;
    const void *keys[] = {kCGImageSourceShouldCache};
    const void *values[] = {kCFBooleanFalse};
    CFDictionaryRef options = CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CGImageSourceRef source = CGImageSourceCreateWithDataProvider(provider, options);
    if (source) {
        CFDictionaryRef properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options);
        if (properties) {
            CFTypeRef exif = CFDictionaryGetValue(properties, kCGImagePropertyExifDictionary);
            if (exif && CFGetTypeID(exif) == CFDictionaryGetTypeID()) {
                int original = ferry_exif_string((CFDictionaryRef)exif, kCGImagePropertyExifDateTimeOriginal, date.original, sizeof(date.original));
                int offset = ferry_exif_string((CFDictionaryRef)exif, kCGImagePropertyExifOffsetTimeOriginal, date.offset, sizeof(date.offset));
                int subsecond = ferry_exif_string((CFDictionaryRef)exif, kCGImagePropertyExifSubsecTimeOriginal, date.subsecond, sizeof(date.subsecond));
                if (original < 0 || offset < 0 || subsecond < 0) date.original[0] = 0;
            }
            CFRelease(properties);
        }
        CFRelease(source);
    }
    if (options) CFRelease(options);
    CGDataProviderRelease(provider);
    return date;
}

static int ferry_set_birth_date(int fd, int64_t seconds, long nanoseconds) {
    struct attrlist attributes = {0};
    attributes.bitmapcount = ATTR_BIT_MAP_COUNT;
    attributes.commonattr = ATTR_CMN_CRTIME;
    struct timespec value = {(time_t)seconds, nanoseconds};
    return fsetattrlist(fd, &attributes, &value, sizeof(value), 0);
}
*/
import "C"

import (
	"os"
	"strconv"
	"strings"
	"time"
)

// EXIF without OffsetTimeOriginal is a wall-clock value. Interpret it in the
// Mac's local timezone, never assume UTC or infer a date from the filename.
func parsePhotoOriginal(original, offset, subsecond string, location *time.Location) (time.Time, bool) {
	original, offset, subsecond = strings.TrimSpace(original), strings.TrimSpace(offset), strings.TrimSpace(subsecond)
	if len(original) != 19 {
		return time.Time{}, false
	}
	layout := "2006:01:02 15:04:05"
	if subsecond != "" {
		for _, value := range subsecond {
			if value < '0' || value > '9' {
				return time.Time{}, false
			}
		}
		if len(subsecond) > 9 {
			subsecond = subsecond[:9]
		}
		original += "." + subsecond
	}
	if offset != "" {
		if len(offset) != 6 || (offset[0] != '+' && offset[0] != '-') || offset[3] != ':' {
			return time.Time{}, false
		}
		hours, errH := strconv.Atoi(offset[1:3])
		minutes, errM := strconv.Atoi(offset[4:6])
		if errH != nil || errM != nil || hours > 23 || minutes > 59 {
			return time.Time{}, false
		}
		layout += " -07:00"
		original += " " + offset
	}
	date, err := time.ParseInLocation(layout, original, location)
	if err != nil || date.Year() < 1 {
		return time.Time{}, false
	}
	return date, true
}

// Called once for a newly committed photo, never for previews or existing files.
// Missing/invalid EXIF leaves creation time unchanged. Metadata failures are
// nonfatal and are recorded in the transfer report by the caller.
func applyPhotoCreationDate(root *os.Root, path string) (time.Time, error) {
	date, err := readPhotoCaptureDate(root, path)
	if err != nil || date.IsZero() {
		return time.Time{}, err
	}
	return setPhotoCreationDate(root, path, date)
}

func readPhotoCaptureDate(root *os.Root, path string) (time.Time, error) {
	file, err := root.Open(path)
	if err != nil {
		return time.Time{}, err
	}
	defer file.Close()
	metadata := C.ferry_read_photo_date(C.int(file.Fd()))
	date, valid := parsePhotoOriginal(C.GoString(&metadata.original[0]), C.GoString(&metadata.offset[0]), C.GoString(&metadata.subsecond[0]), time.Local)
	if !valid {
		return time.Time{}, nil
	}
	return date, nil
}

func setPhotoCreationDate(root *os.Root, path string, date time.Time) (time.Time, error) {
	file, err := root.OpenFile(path, os.O_RDWR, 0)
	if err != nil {
		return time.Time{}, err
	}
	defer file.Close()
	result, err := C.ferry_set_birth_date(C.int(file.Fd()), C.int64_t(date.Unix()), C.long(date.Nanosecond()))
	if result != 0 {
		return time.Time{}, err
	}
	return date, nil
}
