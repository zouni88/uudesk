// Package ws 实现规范 §8 的 WebSocket 信令：presence、invite 路由、
// candidates/relay_open 转发、配对码生成与地址反射。
package ws

import (
	"log"
	"net/http"

	"uudesk-server/internal/pair"
	"uudesk-server/internal/store"

	"github.com/gorilla/websocket"
)

// Server /ws 端点。
type Server struct {
	hub      *Hub
	devices  *store.Store
	codes    *pair.Codes
	upgrader websocket.Upgrader
}

func NewServer(devices *store.Store, codes *pair.Codes) *Server {
	return &Server{
		hub:     NewHub(),
		devices: devices,
		codes:   codes,
		upgrader: websocket.Upgrader{
			ReadBufferSize:  4096,
			WriteBufferSize: 4096,
			// 信令无浏览器 Cookie 场景，跨域检查交由部署层（反代）处理
			CheckOrigin: func(*http.Request) bool { return true },
		},
	}
}

// Hub 暴露在线表供 HTTP API 推送 invite。
func (s *Server) Hub() *Hub { return s.hub }

// ServeHTTP GET /ws?token=<设备令牌>
func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	dev, ok := s.devices.ByToken(r.URL.Query().Get("token"))
	if !ok {
		log.Printf("ws: reject upgrade from %s: invalid token", r.RemoteAddr)
		http.Error(w, `{"t":"error","code":401,"msg":"invalid token"}`, http.StatusUnauthorized)
		return
	}
	conn, err := s.upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("ws: upgrade failed for %s: %v", dev.DeviceID, err)
		return
	}
	c := &client{
		srv:        s,
		hub:        s.hub,
		conn:       conn,
		send:       make(chan []byte, sendQueue),
		deviceID:   dev.DeviceID,
		remoteAddr: r.RemoteAddr,
	}
	s.hub.register(c)
	go c.writePump()
	go c.readPump()
}
