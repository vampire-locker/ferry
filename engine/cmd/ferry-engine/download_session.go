package main

import (
	"context"
	"crypto/rand"
	"errors"
	"ferry.local/engine/internal/i18n"
	"ferry.local/engine/internal/transfer"
	"reflect"
	"slices"
)

// One serial USB session owns at most one cooperative download. The ID is an
// opaque match token, never an output path or permission to resume disk data.
type downloadSession struct {
	id          string
	job         *transfer.DownloadJob
	request     transfer.Request
	checkpoints map[string]cancelledDownload
	retained    int
}

type cancelledDownload struct {
	id         string
	request    transfer.Request
	checkpoint *transfer.DownloadCheckpoint
}

func downloadBinding(req transfer.Request) transfer.Request {
	req.DownloadID, req.DownloadAction, req.ResumeToken = "", "", ""
	req.RecoveryPath = ""
	req.ConflictDecision = nil
	req.ObjectIDs = slices.Clone(req.ObjectIDs)
	if req.USBTarget != nil {
		target := *req.USBTarget
		target.PortNumbers = slices.Clone(target.PortNumbers)
		req.USBTarget = &target
	}
	return req
}

func (s *downloadSession) close(err error) error {
	s.checkpoints, s.retained = nil, 0
	if s.job == nil {
		return nil
	}
	job := s.job
	s.job, s.id = nil, ""
	return job.Abort(err)
}

func (s *downloadSession) handle(ctx context.Context, engine *transfer.Engine, req transfer.Request, deviceName string) (transfer.Event, string, error) {
	if req.DownloadID == "" || len(req.DownloadID) > 128 {
		return transfer.Event{}, "", errors.New(i18n.Text("下载任务标识无效，请新建任务。"))
	}
	if req.DownloadAction == "begin" || req.DownloadAction == "restart" || req.DownloadAction == "resume" || req.DownloadAction == "recover" {
		if s.job != nil {
			return transfer.Event{}, s.job.Output, errors.New(i18n.Text("已有下载任务正在执行，请等待其结束。"))
		}
		var job *transfer.DownloadJob
		var output string
		var err error
		if req.DownloadAction == "resume" {
			saved, ok := s.checkpoints[req.ResumeToken]
			if !ok || saved.id != req.DownloadID || !reflect.DeepEqual(saved.request, downloadBinding(req)) {
				return transfer.Event{}, "", errors.New(i18n.Text("恢复信息已失效，请在本次手机连接内继续，或重新选择未完成文件。"))
			}
			job, err = saved.checkpoint.Resume(ctx, engine)
			if err == nil {
				output = job.Output
				delete(s.checkpoints, req.ResumeToken)
				s.retained -= saved.checkpoint.ItemCount()
			}
		} else if req.DownloadAction == "recover" {
			job, output, err = engine.RecoverDownload(ctx, req, deviceName)
		} else {
			job, output, err = engine.PrepareDownload(ctx, req, deviceName)
		}
		if err != nil {
			return transfer.Event{}, output, err
		}
		s.id, s.job = req.DownloadID, job
		s.request = downloadBinding(req)
		return transfer.Event{Type: "yielded", State: "running", Output: output, ReportPath: job.ReportPath, RecoveryPath: job.RecoveryPath}, output, nil
	}
	if s.job == nil || s.id != req.DownloadID || s.job.StorageID != req.StorageID {
		return transfer.Event{}, "", errors.New(i18n.Text("下载任务已变化或已结束，请新建任务。"))
	}
	output := s.job.Output
	reportPath := s.job.ReportPath
	switch req.DownloadAction {
	case "next", "resolve":
		if req.DownloadAction == "resolve" {
			if err := s.job.ResolveConflict(req.ConflictDecision); err != nil {
				return transfer.Event{}, output, err
			}
		}
		done, err := s.job.Step(ctx)
		if err != nil {
			s.job, s.id = nil, ""
			return transfer.Event{}, output, err
		}
		if done {
			s.job, s.id = nil, ""
			return transfer.Event{Type: "completed", State: "completed", Message: i18n.Text("下载完成"), Output: output, ReportPath: reportPath}, output, nil
		}
		state := "running"
		if s.job.Conflict() != nil {
			state = "waiting"
		}
		return transfer.Event{Type: "yielded", State: state, Output: output, ReportPath: reportPath, Conflict: s.job.Conflict()}, output, nil
	case "cancel":
		checkpoint, err := s.job.CancelForResume()
		event := transfer.Event{Type: "completed", State: "cancelled", Output: output, ReportPath: reportPath}
		if err == nil && checkpoint != nil {
			// Retain bounded metadata only; no open files, device calls, partial
			// downloads or permanent recovery state survive cancellation.
			if len(s.checkpoints) < 32 && s.retained+checkpoint.ItemCount() <= 1_000_000 {
				if s.checkpoints == nil {
					s.checkpoints = make(map[string]cancelledDownload)
				}
				event.ResumeToken = rand.Text()
				s.checkpoints[event.ResumeToken] = cancelledDownload{id: s.id, request: s.request, checkpoint: checkpoint}
				s.retained += checkpoint.ItemCount()
			} else if s.job.RecoveryPath == "" {
				event.Message = i18n.Text("恢复信息已达本次连接的容量上限，请重新选择未完成文件。")
			}
		}
		s.job, s.id, s.request = nil, "", transfer.Request{}
		return event, output, err
	default:
		return transfer.Event{}, output, errors.New(i18n.Text("未知下载调度操作。"))
	}
}
