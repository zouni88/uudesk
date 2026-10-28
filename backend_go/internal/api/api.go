// Package api 实现规范 §8 的 HTTP 接口：register / pair / health / reflect。
package api

import (
	"encoding/json"
	"log"
	"net"
	"net/http"
	"strconv"

	"uudesk-server/internal/pair"
	"uudesk-server/internal/store"
	"uudesk-server/internal/ws"
)

type Server struct {
	devices *store.Store
	codes   *pair.Codes
	hub     *ws.Hub
}

func NewServer(devices *store.Store, codes *pair.Codes, hub *ws.Hub) *Server {
	return &Server{devices: devices, codes: codes, hub: hub}
}

// Handler 返回带全部路由的 mux。
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/register", s.handleRegister)
	mux.HandleFunc("POST /api/pair", s.handlePair)
	mux.HandleFunc("GET /api/health", s.handleHealth)
	mux.HandleFunc("GET /api/reflect", s.handleReflect)
	return mux
}

func (s *Server) handleRegister(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Name     string `json:"name"`
		Role     string `json:"role"`
		DeviceID string `json:"device_id"`
		SPKIPin  string `json:"spki_pin"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, errorBody{Code: 400, Msg: "invalid json"})
		return
	}
	if req.DeviceID == "" || req.Role == "" {
		writeJSON(w, http.StatusBadRequest, errorBody{Code: 400, Msg: "device_id and role required"})
		return
	}
	d := s.devices.Register(req.Name, req.Role, req.DeviceID, req.SPKIPin)
	log.Printf("api: register device=%s name=%q role=%s from %s", d.DeviceID, req.Name, req.Role, r.RemoteAddr)
	writeJSON(w, http.StatusOK, struct {
		Token    string `json:"token"`
		DeviceID string `json:"device_id"`
	}{Token: d.Token, DeviceID: d.DeviceID})
}

// handlePair 校验配对码并向被控设备推送 invite。
// invite 字段语义（规范未细化）：from=控制端设备名，device_id=控制端 device_id。
func (s *Server) handlePair(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Code     string `json:"code"`
		DeviceID string `json:"device_id"` // 发起配对的控制端
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, errorBody{Code: 400, Msg: "invalid json"})
		return
	}
	target, ok := s.codes.Lookup(req.Code)
	if !ok {
		log.Printf("api: pair failed: invalid or expired code %q from %s", req.Code, req.DeviceID)
		writeJSON(w, http.StatusBadRequest, errorBody{Code: 2001, Msg: "pairing code invalid or expired"})
		return
	}
	if !s.hub.Online(target) {
		log.Printf("api: pair failed: target %s offline", target)
		writeJSON(w, http.StatusBadRequest, errorBody{Code: 4004, Msg: "target device offline"})
		return
	}
	from := req.DeviceID
	if d, ok := s.devices.ByID(req.DeviceID); ok && d.Name != "" {
		from = d.Name
	}
	s.codes.Consume(req.Code)
	log.Printf("api: pair %s -> %s (code %s)", req.DeviceID, target, req.Code)
	if err := s.hub.SendTo(target, inviteMsg{T: "invite", From: from, Code: req.Code, DeviceID: req.DeviceID}); err != nil {
		log.Printf("api: push invite to %s failed: %v", target, err)
		writeJSON(w, http.StatusServiceUnavailable, errorBody{Code: 4004, Msg: "push invite failed"})
		return
	}
	writeJSON(w, http.StatusOK, struct {
		OK     bool   `json:"ok"`
		Target string `json:"target"`
	}{OK: true, Target: target})
}

func (s *Server) handleHealth(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, struct {
		Status  string `json:"status"`
		Devices int    `json:"devices"`
		Online  int    `json:"online"`
	}{Status: "ok", Devices: s.devices.Count(), Online: s.hub.OnlineCount()})
}

// handleReflect 返回请求方被观察到的公网 IP:Port，供 NAT 打洞使用。
func (s *Server) handleReflect(w http.ResponseWriter, r *http.Request) {
	ip, port := observedAddr(r)
	writeJSON(w, http.StatusOK, struct {
		IP   string `json:"ip"`
		Port int    `json:"port"`
		Addr string `json:"addr"`
	}{IP: ip, Port: port, Addr: net.JoinHostPort(ip, strconv.Itoa(port))})
}

func observedAddr(r *http.Request) (string, int) {
	host, portStr, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr, 0
	}
	port, _ := strconv.Atoi(portStr)
	return host, port
}

// inviteMsg 服务端→被控设备的邀请，字段遵循规范 §8。
type inviteMsg struct {
	T        string `json:"t"`
	From     string `json:"from"` // 控制端设备名
	Code     string `json:"code"`
	DeviceID string `json:"device_id"` // 控制端 device_id
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
