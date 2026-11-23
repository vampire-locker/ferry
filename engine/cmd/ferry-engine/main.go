package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"ferry.local/engine/internal/admin"
	"ferry.local/engine/internal/i18n"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"os/signal"
	"reflect"
	"sync"
	"syscall"
	"time"

	"github.com/ganeshrvel/go-mtpfs/mtp"

	"ferry.local/engine/internal/device"
	"ferry.local/engine/internal/transfer"
)

func main() { os.Exit(run()) }
func run() int {
	demo := flag.Bool("demo", false, i18n.Text("使用合成文件，不访问 USB"))
	serve := flag.Bool("serve", false, "Keep a serial device session until EOF or cancellation")
	capture := flag.Bool("usb-capture", false, "Request macOS authorization to temporarily capture the USB device")
	authorize := flag.Bool("authorize", false, "Use a transient macOS administrator authorization for USB capture")
	adminSocket := flag.String("admin-socket", "", "Private authenticated bootstrap socket")
	adminUID := flag.Int("admin-uid", 0, "Expected desktop user for the bootstrap socket")
	flag.Parse()
	var identity admin.Identity
	privileged := *adminSocket != ""
	if privileged {
		if *demo || *authorize || !*capture || !*serve {
			return 1
		}
		file, user, err := admin.Connect(*adminSocket, *adminUID)
		if err != nil {
			return 1
		}
		defer file.Close()
		outputFD, err := syscall.Dup(int(file.Fd()))
		if err != nil {
			return 1
		}
		syscall.CloseOnExec(outputFD)
		output := os.NewFile(uintptr(outputFD), "administrator-output")
		defer output.Close()
		os.Stdin, os.Stdout = file, output
		identity = user
	}
	signalCtx, stopSignals := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stopSignals()
	// EOF/output failure cancels work without unregistering signal handlers:
	// the parent may also send SIGTERM while the driver is being restored.
	ctx, cancel := context.WithCancel(signalCtx)
	defer cancel()
	go func() {
		<-ctx.Done()
		os.Stdin.Close()
		// Give cancellation and driver restoration time to finish, but never
		// leave an orphaned helper indefinitely stuck in a native call.
		grace := 30 * time.Second
		if *authorize {
			grace = 45 * time.Second
		}
		time.AfterFunc(grace, func() { os.Exit(130) })
	}()
	encoder := json.NewEncoder(os.Stdout)
	var outputLock sync.Mutex
	emit := func(event transfer.Event) {
		outputLock.Lock()
		defer outputLock.Unlock()
		if err := encoder.Encode(event); err != nil {
			cancel()
		}
	}
	if privileged {
		// The authorization launcher does not stream stderr while the engine
		// runs. Keep Go diagnostics on the authenticated, drained event channel.
		log.SetFlags(0)
		log.SetOutput(engineDiagnosticWriter{emit: emit})
	}
	if *authorize {
		if *demo || *capture || !*serve || privileged {
			return 1
		}
		executable, err := os.Executable()
		if err != nil {
			return 1
		}
		emit(transfer.Event{Type: "status", Message: i18n.Text("正在等待 macOS 管理员授权…")})
		if err = admin.Relay(ctx, executable, os.Getenv("FERRY_LANGUAGE")); err != nil {
			// Remote engine errors have already been forwarded verbatim. Only
			// failures before a connection are authorization failures.
			if errors.Is(err, admin.ErrAuthorization) {
				emit(transfer.Event{Type: "error", State: "authorization_denied", Message: i18n.Text("管理员授权未完成或引擎未能启动，请手动重新连接。")})
			}
			return 1
		}
		return 0
	}
	downloads := downloadSession{}
	fail := func(err error, output string) int {
		if ctx.Err() != nil {
			err = errors.Join(err, ctx.Err())
		}
		if output == "" && downloads.job != nil {
			output = downloads.job.Output
		}
		err = errors.Join(err, downloads.close(err))
		state := "failed"
		message := err.Error()
		var authorization *mtp.DriverAuthorizationError
		if errors.As(err, &authorization) {
			state = "authorization_denied"
		}
		if errors.Is(err, context.Canceled) || ctx.Err() != nil {
			state = "cancelled"
			message = i18n.Text("已停止下载，已完成的文件保留在目标文件夹中。")
		}
		emit(transfer.Event{Type: "error", Message: message, State: state, Output: output})
		return 1
	}

	var dev transfer.Device = &device.MTP{AllowCapture: *capture, Status: func(message string) { emit(transfer.Event{Type: "status", Message: message}) }}
	if *demo {
		dev = &device.Demo{}
	}
	defer dev.Close()
	defer func() {
		if err := downloads.close(context.Canceled); err != nil {
			log.Printf("download cleanup: %v", err)
		}
	}()
	var name string
	var storages []transfer.Storage
	connected := false
	var selectedTarget *transfer.USBTarget
	handle := func(req transfer.Request) int {
		if req.DownloadAction != "" && (!*serve || req.Operation != "download") {
			return fail(errors.New(i18n.Text("下载调度仅支持常驻会话中的下载请求。")), "")
		}
		if req.DownloadAction == "" && req.DownloadID != "" {
			return fail(errors.New(i18n.Text("下载任务缺少调度操作。")), "")
		}
		// A session may restart after thumbnail cancellation. Every supported
		// request initializes USB first, and no requested work can execute
		// until permanent privilege dropping has succeeded.
		if req.Operation != "connect" && req.Operation != "list" && req.Operation != "sizes" && req.Operation != "download" && req.Operation != "preview" && req.Operation != "thumbnails" {
			return fail(errors.New(i18n.Text("未知操作")), "")
		}
		if !connected {
			selectedTarget = req.USBTarget
			if physical, ok := dev.(*device.MTP); ok {
				physical.Target = selectedTarget
			}
			emit(transfer.Event{Type: "status", Message: i18n.Text("正在连接手机…")})
			var err error
			var drop func() error
			if privileged {
				drop = identity.Drop
			}
			name, storages, err = initializeConnection(ctx, dev, drop)
			if err != nil {
				return fail(err, "")
			}
			privileged = false
			connected = true
		}
		if !reflect.DeepEqual(selectedTarget, req.USBTarget) {
			return fail(errors.New(i18n.Text("所选手机已变化，请重新连接。")), "")
		}
		if req.Operation == "connect" {
			emit(transfer.Event{Type: "connected", DeviceName: name, DeviceKey: dev.Identity(), RecoveryIdentity: transfer.RecoveryIdentity(dev), Storages: storages})
			return 0
		}
		if req.DeviceKey == "" || req.DeviceKey != dev.Identity() {
			return fail(errors.New(i18n.Text("设备已变化，请重新连接后选择文件")), "")
		}
		validStorage := false
		for _, storage := range storages {
			if storage.ID == req.StorageID {
				validStorage = true
			}
		}
		if !validStorage {
			return fail(errors.New(i18n.Text("存储已变化，请重新连接手机")), "")
		}
		if req.Operation == "list" {
			emit(transfer.Event{Type: "status", Message: i18n.Text("正在读取目录，大目录可能需要较长时间…")})
			var entries []transfer.Entry
			var err error
			if browser, ok := dev.(transfer.BrowsingDevice); ok && req.IncludeSizes != nil {
				entries, err = browser.ListForBrowse(ctx, req.StorageID, req.ParentID, *req.IncludeSizes)
			} else {
				entries, err = dev.List(ctx, req.StorageID, req.ParentID)
			}
			if err != nil {
				return fail(err, "")
			}
			emit(transfer.Event{Type: "listed", Entries: entries})
			return 0
		}
		if req.Operation == "sizes" {
			emit(transfer.Event{Type: "status", Message: i18n.Text("正在读取文件大小…")})
			browser, ok := dev.(transfer.BrowsingDevice)
			if !ok {
				return fail(errors.New(i18n.Text("设备不支持单独读取大小，请刷新目录。")), "")
			}
			sizes, err := browser.Sizes(ctx, req.StorageID, req.ParentID)
			if err != nil {
				return fail(err, "")
			}
			emit(transfer.Event{Type: "sized", Sizes: sizes})
			return 0
		}

		engine := transfer.Engine{Device: dev, Emit: emit, Storages: storages}
		if req.Operation == "preview" {
			output, err := engine.Preview(ctx, req)
			if err != nil {
				return fail(err, "")
			}
			emit(transfer.Event{Type: "completed", Output: output, State: "completed"})
			return 0
		}
		if req.Operation == "thumbnails" {
			if err := engine.Thumbnails(ctx, req); err != nil {
				return fail(err, "")
			}
			emit(transfer.Event{Type: "completed", State: "completed"})
			return 0
		}
		if req.DownloadAction != "" {
			event, output, err := downloads.handle(ctx, &engine, req, name)
			if err != nil {
				return fail(err, output)
			}
			emit(event)
			return 0
		}
		if downloads.job != nil {
			return fail(errors.New(i18n.Text("已有下载任务正在执行，请等待其结束。")), downloads.job.Output)
		}
		output, err := engine.Download(ctx, req, name)
		if err != nil {
			return fail(err, output)
		}
		emit(transfer.Event{Type: "completed", Message: i18n.Text("下载完成"), Output: output, State: "completed"})
		return 0
	}
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 64*1024), 4<<20)
	type inputLine struct {
		data []byte
		err  error
	}
	lines := make(chan inputLine, 1)
	go func() {
		defer close(lines)
		for scanner.Scan() {
			line := inputLine{data: append([]byte(nil), scanner.Bytes()...)}
			select {
			case lines <- line:
			case <-ctx.Done():
				return
			}
			if !*serve {
				return
			}
		}
		if err := scanner.Err(); err != nil {
			select {
			case lines <- inputLine{err: err}:
			case <-ctx.Done():
			}
		}
		if *serve {
			cancel()
		}
	}()
	for line := range lines {
		if ctx.Err() != nil {
			return fail(ctx.Err(), "")
		}
		if line.err != nil {
			return fail(line.err, "")
		}
		var req transfer.Request
		decoder := json.NewDecoder(bytes.NewReader(line.data))
		decoder.DisallowUnknownFields()
		if err := decoder.Decode(&req); err != nil {
			return fail(fmt.Errorf(i18n.Text("请求格式无效：%w"), err), "")
		}
		var extra any
		if err := decoder.Decode(&extra); err != io.EOF {
			return fail(errors.New(i18n.Text("未知操作")), "")
		}
		code := handle(req)
		if code != 0 || !*serve {
			return code
		}
		// Terminal events are committed only once request resources are closed.
		// The client may send its next request after this synchronization marker.
		emit(transfer.Event{Type: "ready"})
	}
	return 0
}

// Only connection metadata may be read before dropping privileges. The caller
// must stop on any error, before dispatching list/sizes/preview/download work.
func initializeConnection(ctx context.Context, dev transfer.Device, drop func() error) (string, []transfer.Storage, error) {
	if err := ctx.Err(); err != nil {
		return "", nil, err
	}
	name, storages, err := dev.Connect(ctx)
	if err != nil {
		return "", nil, err
	}
	if err := ctx.Err(); err != nil {
		return "", nil, err
	}
	if drop != nil {
		if err := drop(); err != nil {
			return "", nil, fmt.Errorf(i18n.Text("无法切回当前用户权限：%w"), err)
		}
	}
	return name, storages, nil
}

type engineDiagnosticWriter struct{ emit func(transfer.Event) }

func (writer engineDiagnosticWriter) Write(data []byte) (int, error) {
	writer.emit(transfer.Event{Type: "diagnostic", Message: string(data)})
	return len(data), nil
}
