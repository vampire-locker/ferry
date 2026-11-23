# Photo metadata fixtures

`capture.heic` and `capture.tiff` are synthetic 16×16 solid-color images generated
with macOS ImageIO. They contain no user photographs or device data.

EXIF values:

- `DateTimeOriginal`: `2022:02:28 19:31:40`
- `OffsetTimeOriginal`: `+08:00`
- `SubsecTimeOriginal`: `120`

Regenerate on macOS from the repository root:

```sh
swift -module-cache-path .cache/swift-module engine/internal/transfer/testdata/generate.swift engine/internal/transfer/testdata
```
