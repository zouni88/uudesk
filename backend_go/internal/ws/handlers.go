package ws

import (
	"encoding/json"
	"log"
	"time"
)

// handle 按消息类型分发设备上报的信令消息。
func (c *client) handle(data []byte) {
	var m InMsg
	if err := json.Unmarshal(data, &m); err != nil || m.T == "" {
		log.Printf("ws: %s malformed message: %v", c.deviceID, err)
		c.replyError(codeBadMessage, "malformed message")
		return
	}
	log.Printf("ws: %s <- %s", c.deviceID, m.T)
	switch m.T {
	case "invite_result":
		c.routeInviteResult(m)
	case "candidates":
		c.routeCandidates(m)
	case "relay_open":
		c.routeRelayOpen(m)
	case "presence":
		c.handlePresence(m)
	case "gen_code":
		c.handleGenCode()
	case "revoke_code":
		c.srv.codes.Revoke(c.deviceID)
		c.enqueueJSON(revokeCodeReply{T: "revoke_code", OK: true})
	case "reflect":
		ip, port := c.reflectAddr()
		c.enqueueJSON(reflectReply{T: "reflect", IP: ip, Port: port})
	default:
		c.replyError(codeBadMessage, "unknown message type: "+m.T)
	}
}

// routeInviteResult 被控端的接受/拒绝结果，原样路由给控制端。
func (c *client) routeInviteResult(m InMsg) {
	if m.To == "" {
		c.replyError(codeBadMessage, "invite_result missing to")
		return
	}
	if err := c.hub.SendTo(m.To, m); err != nil {
		c.replyError(codeTargetOff, "target offline: "+m.To)
	}
}

// routeCandidates 存储并互发双方公网地址：转发给 peer（peer 字段改写为发送方），
// 同时把 peer 已知地址回填给发送方，使一次上报即可完成地址交换。
func (c *client) routeCandidates(m InMsg) {
	if m.Peer == "" {
		c.replyError(codeBadMessage, "candidates missing peer")
		return
	}
	c.mu.Lock()
	c.candidates = dedup(append(m.Addrs, c.remoteAddr))
	addrs := append([]string(nil), c.candidates...)
	c.mu.Unlock()

	out := candidatesMsg{T: "candidates", Peer: c.deviceID, Addrs: addrs}
	if err := c.hub.SendTo(m.Peer, out); err != nil {
		c.replyError(codeTargetOff, "target offline: "+m.Peer)
		return
	}
	if peerAddrs, ok := c.hub.addrsOf(m.Peer); ok {
		c.enqueueJSON(candidatesMsg{T: "candidates", Peer: m.Peer, Addrs: peerAddrs})
	}
}

// routeRelayOpen 打洞失败请求中继，peer 改写为发送方后转发。
func (c *client) routeRelayOpen(m InMsg) {
	if m.Peer == "" {
		c.replyError(codeBadMessage, "relay_open missing peer")
		return
	}
	if err := c.hub.SendTo(m.Peer, relayOpenMsg{T: "relay_open", Peer: c.deviceID}); err != nil {
		c.replyError(codeTargetOff, "target offline: "+m.Peer)
	}
}

// handlePresence 查询对端（或自身）在线状态。
func (c *client) handlePresence(m InMsg) {
	target := m.Peer
	if target == "" {
		target = c.deviceID
	}
	status := "offline"
	if c.hub.Online(target) {
		status = "online"
	}
	c.enqueueJSON(presenceMsg{T: "presence", DeviceID: target, Status: status})
}

func (c *client) handleGenCode() {
	code, err := c.srv.codes.Gen(c.deviceID)
	if err != nil {
		c.replyError(codeBadMessage, "generate code failed")
		return
	}
	c.enqueueJSON(genCodeReply{T: "gen_code", Code: code, ExpiresIn: int((10 * time.Minute).Seconds())})
}

func (c *client) replyError(code int, msg string) {
	c.enqueueJSON(errorMsg{T: "error", Code: code, Msg: msg})
}

func (c *client) enqueueJSON(v any) {
	data, err := json.Marshal(v)
	if err == nil {
		_ = c.enqueue(data)
	}
}

func dedup(in []string) []string {
	seen := make(map[string]bool, len(in))
	out := in[:0]
	for _, s := range in {
		if s != "" && !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
	}
	return out
}

// addrsOf 取在线设备已知的打洞地址（上报的 candidates 优先，否则服务端观察地址）。
func (h *Hub) addrsOf(deviceID string) ([]string, bool) {
	h.mu.RLock()
	defer h.mu.RUnlock()
	c, ok := h.clients[deviceID]
	if !ok {
		return nil, false
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if len(c.candidates) > 0 {
		return append([]string(nil), c.candidates...), true
	}
	return []string{c.remoteAddr}, true
}
