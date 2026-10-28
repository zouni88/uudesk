package ws

import (
	"encoding/json"
	"errors"
	"log"
	"sync"
)

// ErrOffline 目标设备不在线。
var ErrOffline = errors.New("device offline")

// Hub 在线设备表：device_id -> 唯一活动连接，并发安全。
type Hub struct {
	mu      sync.RWMutex
	clients map[string]*client
}

func NewHub() *Hub { return &Hub{clients: make(map[string]*client)} }

func (h *Hub) register(c *client) {
	h.mu.Lock()
	old := h.clients[c.deviceID]
	h.clients[c.deviceID] = c
	h.mu.Unlock()
	if old != nil && old != c {
		log.Printf("ws: device %s reconnected, kicking old conn", c.deviceID)
		old.close() // 同设备重复上线，踢掉旧连接
	}
	log.Printf("ws: device %s online (%s), total %d", c.deviceID, c.remoteAddr, h.OnlineCount())
	h.broadcast(presenceMsg{T: "presence", DeviceID: c.deviceID, Status: "online"})
}

func (h *Hub) unregister(c *client) {
	h.mu.Lock()
	if h.clients[c.deviceID] == c {
		delete(h.clients, c.deviceID)
		h.mu.Unlock()
		log.Printf("ws: device %s offline, total %d", c.deviceID, h.OnlineCount())
		h.broadcast(presenceMsg{T: "presence", DeviceID: c.deviceID, Status: "offline"})
		return
	}
	h.mu.Unlock()
}

// Online 设备是否有活动连接。
func (h *Hub) Online(deviceID string) bool {
	h.mu.RLock()
	defer h.mu.RUnlock()
	_, ok := h.clients[deviceID]
	return ok
}

// SendTo 向指定设备发送 JSON 消息；离线返回 ErrOffline。
func (h *Hub) SendTo(deviceID string, v any) error {
	data, err := json.Marshal(v)
	if err != nil {
		return err
	}
	h.mu.RLock()
	c := h.clients[deviceID]
	h.mu.RUnlock()
	if c == nil {
		return ErrOffline
	}
	return c.enqueue(data)
}

func (h *Hub) broadcast(v any) {
	data, err := json.Marshal(v)
	if err != nil {
		return
	}
	h.mu.RLock()
	defer h.mu.RUnlock()
	for _, c := range h.clients {
		_ = c.enqueue(data)
	}
}

// OnlineCount 当前在线设备数。
func (h *Hub) OnlineCount() int {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return len(h.clients)
}
