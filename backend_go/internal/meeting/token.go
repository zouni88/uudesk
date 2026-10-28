// Package meeting 实现规范 §10 多人会议控制面：LiveKit 令牌签发、
// Egress 录制 webhook 与录制列表查询。媒体面由自托管 LiveKit server 承担，
// 本包只做签发与记录，不实现 SFU。
package meeting

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// tokenTTL 为规范约定的令牌有效期。
const tokenTTL = 6 * time.Hour

// Config LiveKit 对接配置，来自环境变量。
type Config struct {
	APIKey    string // LIVEKIT_API_KEY
	APISecret string // LIVEKIT_API_SECRET
	ServerURL string // LIVEKIT_URL，如 wss://host:7881
}

// ConfigFromEnv 读取环境变量；缺失字段留空，由 Valid 判定。
func ConfigFromEnv() Config {
	return Config{
		APIKey:    os.Getenv("LIVEKIT_API_KEY"),
		APISecret: os.Getenv("LIVEKIT_API_SECRET"),
		ServerURL: os.Getenv("LIVEKIT_URL"),
	}
}

// Valid key/secret 齐备才可签发令牌与校验 webhook。
func (c Config) Valid() bool { return c.APIKey != "" && c.APISecret != "" }

// Server 会议 HTTP 接口，并发安全（依赖项自身加锁）。
type Server struct {
	cfg Config
	rec *Recordings

	activeMu sync.Mutex
	active   map[string]string // room -> 进行中的 egress_id
}

func NewServer(cfg Config, rec *Recordings) *Server {
	return &Server{cfg: cfg, rec: rec, active: make(map[string]string)}
}

// Handler 返回带全部会议路由的 mux（规范 §10.1/§10.2）。
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/meeting/token", s.handleToken)
	mux.HandleFunc("POST /api/meeting/webhook", s.handleWebhook)
	mux.HandleFunc("GET /api/meeting/recordings", s.handleRecordings)
	mux.HandleFunc("POST /api/meeting/egress/start", s.handleEgressStart)
	mux.HandleFunc("POST /api/meeting/egress/stop", s.handleEgressStop)
	return mux
}

// IssueToken 按 §10.1 签发 LiveKit access token（HS256 JWT）。
func IssueToken(cfg Config, room, identity string, canPublish bool) (string, error) {
	now := time.Now()
	claims := jwt.MapClaims{
		"iss": cfg.APIKey,
		"sub": identity,
		"exp": now.Add(tokenTTL).Unix(),
		"video": map[string]any{
			"room":                 room,
			"roomJoin":             true, // LiveKit EnsureJoinPermission 必需，缺失则 401
			"roomAdmin":            true,
			"canPublish":           canPublish,
			"canSubscribe":         true,
			"canPublishData":       true,
			"canUpdateOwnMetadata": true, // 允许入会后 setName() 改显示名
		},
	}
	return jwt.NewWithClaims(jwt.SigningMethodHS256, claims).SignedString([]byte(cfg.APISecret))
}

func (s *Server) handleToken(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Room       string `json:"room"`
		Identity   string `json:"identity"`
		CanPublish *bool  `json:"can_publish"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		log.Printf("meeting: token request invalid json from %s: %v", r.RemoteAddr, err)
		writeJSON(w, http.StatusBadRequest, errorBody{Code: 400, Msg: "invalid json"})
		return
	}
	if req.Room == "" || req.Identity == "" {
		log.Printf("meeting: token request missing room/identity from %s", r.RemoteAddr)
		writeJSON(w, http.StatusBadRequest, errorBody{Code: 400, Msg: "room and identity required"})
		return
	}
	if !s.cfg.Valid() {
		log.Printf("meeting: token request room=%s identity=%s rejected: LIVEKIT_API_KEY/LIVEKIT_API_SECRET not configured", req.Room, req.Identity)
		writeJSON(w, http.StatusServiceUnavailable, errorBody{Code: 5001, Msg: "meeting not configured: LIVEKIT_API_KEY/LIVEKIT_API_SECRET missing"})
		return
	}
	canPublish := true
	if req.CanPublish != nil {
		canPublish = *req.CanPublish
	}
	token, err := IssueToken(s.cfg, req.Room, req.Identity, canPublish)
	if err != nil {
		log.Printf("meeting: sign token for room=%s identity=%s failed: %v", req.Room, req.Identity, err)
		writeJSON(w, http.StatusInternalServerError, errorBody{Code: 500, Msg: "sign token failed"})
		return
	}
	log.Printf("meeting: token issued room=%s identity=%s canPublish=%v", req.Room, req.Identity, canPublish)
	writeJSON(w, http.StatusOK, struct {
		Token     string `json:"token"`
		ServerURL string `json:"server_url"`
	}{Token: token, ServerURL: s.cfg.ServerURL})
}

type errorBody struct {
	Code int    `json:"code"`
	Msg  string `json:"msg"`
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
