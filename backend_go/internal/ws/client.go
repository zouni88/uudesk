package ws

import (
	"net"
	"strconv"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

const (
	writeWait  = 10 * time.Second
	pongWait   = 75 * time.Second
	pingPeriod = 45 * time.Second
	sendQueue  = 64
)

// client 一个设备的 WS 连接。
type client struct {
	srv        *Server
	hub        *Hub
	conn       *websocket.Conn
	send       chan []byte
	deviceID   string
	remoteAddr string // 服务端观察到的设备公网地址 host:port

	mu         sync.Mutex
	candidates []string // 设备最近一次上报的打洞候选地址
}

func (c *client) enqueue(data []byte) error {
	select {
	case c.send <- data:
		return nil
	default: // 发送队列满视为慢客户端，断开重连
		c.close()
		return ErrOffline
	}
}

func (c *client) close() { closeOnce(c) }

func closeOnce(c *client) {
	_ = c.conn.Close() // 关闭底层连接会使 readPump 退出
}

func (c *client) reflectAddr() (string, int) {
	host, portStr, err := net.SplitHostPort(c.remoteAddr)
	if err != nil {
		return c.remoteAddr, 0
	}
	port, _ := strconv.Atoi(portStr)
	return host, port
}

// readPump 读取并分发设备消息。
func (c *client) readPump() {
	defer func() {
		c.hub.unregister(c)
		_ = c.conn.Close()
	}()
	c.conn.SetReadLimit(64 * 1024)
	_ = c.conn.SetReadDeadline(time.Now().Add(pongWait))
	c.conn.SetPongHandler(func(string) error {
		return c.conn.SetReadDeadline(time.Now().Add(pongWait))
	})
	for {
		_, data, err := c.conn.ReadMessage()
		if err != nil {
			return
		}
		c.handle(data)
	}
}

// writePump 串行化写出并周期 ping。
func (c *client) writePump() {
	ticker := time.NewTicker(pingPeriod)
	defer func() {
		ticker.Stop()
		_ = c.conn.Close()
	}()
	for {
		select {
		case data, ok := <-c.send:
			_ = c.conn.SetWriteDeadline(time.Now().Add(writeWait))
			if !ok {
				_ = c.conn.WriteMessage(websocket.CloseMessage, []byte{})
				return
			}
			if err := c.conn.WriteMessage(websocket.TextMessage, data); err != nil {
				return
			}
		case <-ticker.C:
			_ = c.conn.SetWriteDeadline(time.Now().Add(writeWait))
			if err := c.conn.WriteMessage(websocket.PingMessage, nil); err != nil {
				return
			}
		}
	}
}
