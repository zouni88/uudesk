// egress.go 实现规范 §10.2 的录制链路：接收 LiveKit Egress webhook
// （X-Livekit-Signature HS256 校验）并把录制产物记入 data/recordings.json；
// 提供录制列表查询与 egress 启动指令生成。
package meeting

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v5"
	livekit "github.com/livekit/protocol/livekit"
	lksdk "github.com/livekit/server-sdk-go/v2"
)

// maxWebhookBody LiveKit 事件体上限，防御超大请求。
const maxWebhookBody = 1 << 20

// Recording 一条录制产物记录。
type Recording struct {
	Room     string `json:"room"`
	EgressID string `json:"egress_id"`
	FilePath string `json:"filepath"`
	Status   string `json:"status"`
	EndedAt  string `json:"ended_at"` // RFC3339
}

// Recordings 录制列表，并发安全，持久化到 data/recordings.json。
type Recordings struct {
	mu    sync.RWMutex
	path  string
	items []Recording
}

// NewRecordings 加载（或创建）持久化文件。
func NewRecordings(dataDir string) (*Recordings, error) {
	r := &Recordings{path: filepath.Join(dataDir, "recordings.json")}
	if err := os.MkdirAll(dataDir, 0o700); err != nil {
		return nil, err
	}
	data, err := os.ReadFile(r.path)
	if errors.Is(err, os.ErrNotExist) {
		return r, nil
	}
	if err != nil {
		return nil, err
	}
	if err := json.Unmarshal(data, &r.items); err != nil {
		return nil, err
	}
	return r, nil
}

// Add 追加一条记录并落盘。
func (r *Recordings) Add(rec Recording) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.items = append(r.items, rec)
	return r.saveLocked()
}

// List 按房间过滤（room 为空返回全部），按结束时间升序。
func (r *Recordings) List(room string) []Recording {
	r.mu.RLock()
	defer r.mu.RUnlock()
	out := make([]Recording, 0, len(r.items))
	for _, it := range r.items {
		if room == "" || it.Room == room {
			out = append(out, it)
		}
	}
	return out
}

// saveLocked 调用方需持有写锁；原子写 tmp+rename，与 store 包一致。
func (r *Recordings) saveLocked() error {
	data, err := json.MarshalIndent(r.items, "", "  ")
	if err != nil {
		return err
	}
	tmp := r.path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, r.path)
}

// webhookEvent LiveKit 事件体（仅取录制相关字段，兼容嵌套与扁平两种形态）。
type webhookEvent struct {
	Type  string `json:"type"`
	Event struct {
		Room struct {
			Name string `json:"name"`
		} `json:"room"`
		Egress struct {
			EgressID string `json:"egress_id"`
			Status   string `json:"status"`
			Room     string `json:"room"`
			FilePath string `json:"filepath"`
			EndedAt  int64  `json:"ended_at"`
		} `json:"egress"`
	} `json:"event"`
	// 扁平字段（自定义/简化推送）
	EgressID string `json:"egress_id"`
	Status   string `json:"status"`
	Room     string `json:"room"`
	FilePath string `json:"filepath"`
	EndedAt  int64  `json:"ended_at"`
}

func (e webhookEvent) fields() (room, egressID, status, filepath string, endedAt int64) {
	room, egressID, status, filepath, endedAt = e.Room, e.EgressID, e.Status, e.FilePath, e.EndedAt
	if e.Event.Egress.EgressID != "" {
		egressID = e.Event.Egress.EgressID
		status, filepath, endedAt = e.Event.Egress.Status, e.Event.Egress.FilePath, e.Event.Egress.EndedAt
		room = e.Event.Egress.Room
		if room == "" {
			room = e.Event.Room.Name
		}
	}
	return
}

// handleWebhook 接收 LiveKit 事件：校验签名头，把结束态 Egress 事件记入录制列表。
func (s *Server) handleWebhook(w http.ResponseWriter, r *http.Request) {
	if !s.cfg.Valid() {
		writeJSON(w, http.StatusServiceUnavailable, errorBody{Code: 5001, Msg: "meeting not configured: LIVEKIT_API_KEY/LIVEKIT_API_SECRET missing"})
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, maxWebhookBody))
	if err != nil {
		writeJSON(w, http.StatusBadRequest, errorBody{Code: 400, Msg: "read body failed"})
		return
	}
	sig := r.Header.Get("X-Livekit-Signature")
	if sig == "" {
		sig = r.Header.Get("Authorization")
	}
	if err := s.verifyWebhook(sig, body); err != nil {
		writeJSON(w, http.StatusUnauthorized, errorBody{Code: 5002, Msg: "invalid webhook signature: " + err.Error()})
		return
	}
	var ev webhookEvent
	if err := json.Unmarshal(body, &ev); err != nil {
		writeJSON(w, http.StatusBadRequest, errorBody{Code: 400, Msg: "invalid event json"})
		return
	}
	room, egressID, status, fp, endedAt := ev.fields()
	if isEgressEnded(ev.Type, status, fp) && egressID != "" {
		// 结束后从进行中表移除（若由 stop 接口移除过则无影响）
		s.activeMu.Lock()
		for r, id := range s.active {
			if id == egressID {
				delete(s.active, r)
			}
		}
		s.activeMu.Unlock()
		when := time.Now().UTC()
		if endedAt > 0 {
			when = time.Unix(endedAt, 0).UTC()
		}
		if err := s.rec.Add(Recording{
			Room:     room,
			EgressID: egressID,
			FilePath: fp,
			Status:   status,
			EndedAt:  when.Format(time.RFC3339),
		}); err != nil {
			log.Printf("meeting: persist recording failed room=%s egress_id=%s: %v", room, egressID, err)
			writeJSON(w, http.StatusInternalServerError, errorBody{Code: 500, Msg: "persist recording failed"})
			return
		}
		log.Printf("meeting: recording saved room=%s egress_id=%s status=%s filepath=%s", room, egressID, status, fp)
	}
	writeJSON(w, http.StatusOK, struct {
		OK bool `json:"ok"`
	}{OK: true})
}

// verifyWebhook 按 LiveKit 方案校验：HS256 JWT（密钥为 API secret），
// 若携带 sha256 claim 则须等于请求体的 SHA-256（hex）。
func (s *Server) verifyWebhook(sig string, body []byte) error {
	if sig == "" {
		return errors.New("missing X-Livekit-Signature")
	}
	claims := jwt.MapClaims{}
	tok, err := jwt.ParseWithClaims(sig, claims, func(*jwt.Token) (any, error) {
		return []byte(s.cfg.APISecret), nil
	}, jwt.WithValidMethods([]string{"HS256"}))
	if err != nil || !tok.Valid {
		return errors.New("signature jwt invalid")
	}
	if want, ok := claims["sha256"].(string); ok {
		sum := sha256.Sum256(body)
		if !hmac.Equal([]byte(strings.ToLower(want)), []byte(hex.EncodeToString(sum[:]))) {
			return errors.New("body hash mismatch")
		}
	}
	return nil
}

// isEgressEnded 判定为可记录的结束态录制事件（EgressEnded 携带 filepath）。
func isEgressEnded(eventType, status, filepath string) bool {
	if !strings.Contains(strings.ToLower(eventType), "egress") {
		return false
	}
	switch strings.ToUpper(status) {
	case "EGRESS_END", "EGRESS_FAILED", "EGRESS_ABORTED", "ENDED", "COMPLETE", "FAILED", "ABORTED":
		return true
	}
	return filepath != ""
}

// handleRecordings GET /api/meeting/recordings?room= 录制列表。
func (s *Server) handleRecordings(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, struct {
		Recordings []Recording `json:"recordings"`
	}{Recordings: s.rec.List(r.URL.Query().Get("room"))})
}

// handleEgressStart POST /api/meeting/egress/start {room}。
// 优先经官方 SDK 直连 LiveKit server 启动 RoomComposite MP4 录制；
// LiveKit 不可达时回退为生成 livekit-cli 命令交运维执行。
func (s *Server) handleEgressStart(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Room string `json:"room"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, errorBody{Code: 400, Msg: "invalid json"})
		return
	}
	if req.Room == "" {
		writeJSON(w, http.StatusBadRequest, errorBody{Code: 400, Msg: "room required"})
		return
	}
	if !s.cfg.Valid() {
		writeJSON(w, http.StatusServiceUnavailable, errorBody{Code: 5001, Msg: "meeting not configured: LIVEKIT_API_KEY/LIVEKIT_API_SECRET missing"})
		return
	}
	egressID, sdkErr := s.startEgress(req.Room)
	if sdkErr == nil {
		s.activeMu.Lock()
		s.active[req.Room] = egressID
		s.activeMu.Unlock()
		log.Printf("meeting: egress started room=%s egress_id=%s", req.Room, egressID)
		writeJSON(w, http.StatusOK, struct {
			OK       bool   `json:"ok"`
			Room     string `json:"room"`
			EgressID string `json:"egress_id"`
		}{OK: true, Room: req.Room, EgressID: egressID})
		return
	}
	request, err := json.Marshal(map[string]any{
		"roomName": req.Room,
		"file": map[string]any{
			"filepath": "recordings/{room_name}/{time}.mp4",
			"filetype": "MP4",
		},
	})
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errorBody{Code: 500, Msg: "build request failed"})
		return
	}
	cmd := fmt.Sprintf(`livekit-cli start-room-composite-egress --api-key "$LIVEKIT_API_KEY" --api-secret "$LIVEKIT_API_SECRET" --url "$LIVEKIT_URL" --request %s`,
		shellSingleQuote(string(request)))
	writeJSON(w, http.StatusOK, struct {
		OK      bool   `json:"ok"`
		Room    string `json:"room"`
		Command string `json:"command"`
		Note    string `json:"note"`
	}{
		OK:      true,
		Room:    req.Room,
		Command: cmd,
		Note:    fmt.Sprintf("LiveKit server 不可达（%v），请在服务器上手动执行该命令启动录制；产物路径以 Egress 服务挂载的 /recordings 为准", sdkErr),
	})
}

// handleEgressStop POST /api/meeting/egress/stop {room}。
func (s *Server) handleEgressStop(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Room string `json:"room"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, errorBody{Code: 400, Msg: "invalid json"})
		return
	}
	if req.Room == "" {
		writeJSON(w, http.StatusBadRequest, errorBody{Code: 400, Msg: "room required"})
		return
	}
	if !s.cfg.Valid() {
		writeJSON(w, http.StatusServiceUnavailable, errorBody{Code: 5001, Msg: "meeting not configured: LIVEKIT_API_KEY/LIVEKIT_API_SECRET missing"})
		return
	}
	s.activeMu.Lock()
	egressID, ok := s.active[req.Room]
	if ok {
		delete(s.active, req.Room)
	}
	s.activeMu.Unlock()
	if !ok {
		writeJSON(w, http.StatusNotFound, errorBody{Code: 5003, Msg: "no active recording for room"})
		return
	}
	if err := s.stopEgress(egressID); err != nil {
		log.Printf("meeting: egress stop failed room=%s egress_id=%s: %v", req.Room, egressID, err)
		writeJSON(w, http.StatusBadGateway, errorBody{Code: 5004, Msg: "stop egress failed: " + err.Error()})
		return
	}
	log.Printf("meeting: egress stopped room=%s egress_id=%s", req.Room, egressID)
	writeJSON(w, http.StatusOK, struct {
		OK       bool   `json:"ok"`
		Room     string `json:"room"`
		EgressID string `json:"egress_id"`
	}{OK: true, Room: req.Room, EgressID: egressID})
}

// startEgress 经 SDK 启动 RoomComposite MP4 录制，返回 egress_id。
func (s *Server) startEgress(room string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	ec := lksdk.NewEgressClient(httpURL(s.cfg.ServerURL), s.cfg.APIKey, s.cfg.APISecret)
	info, err := ec.StartRoomCompositeEgress(ctx, &livekit.RoomCompositeEgressRequest{
		RoomName: room,
		Layout:   "speaker",
		Output: &livekit.RoomCompositeEgressRequest_File{
			File: &livekit.EncodedFileOutput{
				FileType: livekit.EncodedFileType_MP4,
				Filepath: fmt.Sprintf("recordings/%s/{time}.mp4", room),
			},
		},
	})
	if err != nil {
		return "", err
	}
	return info.GetEgressId(), nil
}

// stopEgress 经 SDK 停止录制。
func (s *Server) stopEgress(egressID string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	ec := lksdk.NewEgressClient(httpURL(s.cfg.ServerURL), s.cfg.APIKey, s.cfg.APISecret)
	_, err := ec.StopEgress(ctx, &livekit.StopEgressRequest{EgressId: egressID})
	return err
}

// httpURL 把 wss:// 的 LIVEKIT_URL 转成 twirp 需要的 http(s)://。
func httpURL(u string) string {
	u = strings.TrimPrefix(u, "wss://")
	u = strings.TrimPrefix(u, "ws://")
	if !strings.HasPrefix(u, "http://") && !strings.HasPrefix(u, "https://") {
		u = "http://" + u
	}
	return u
}

// shellSingleQuote 用 POSIX 单引号安全包裹字符串（供 bash 直接执行）。
func shellSingleQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}
