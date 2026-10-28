package relay

import (
	"context"
	"crypto/tls"
	"encoding/binary"
	"encoding/json"
	"io"
	"log"
	"sync"
	"time"

	"github.com/quic-go/quic-go"
)

// alpn 与 uu-proto.md §1 一致。
const alpn = "uudesk/1"

// helloWait 首条 relay_hello 的最长等待；pairWait 半连接配对超时。
const (
	helloWait = 10 * time.Second
	pairWait  = 5 * time.Minute
)

// hello 双向流首条消息：{"t":"relay_hello","peer":"<对端>","device_id":"<本机>"}。
// 规范原文只给 peer；服务端无法从 TLS 层获知连接方身份，故扩展 device_id 字段用于配对。
type hello struct {
	T        string `json:"t"`
	Peer     string `json:"peer"`
	DeviceID string `json:"device_id"`
}

type half struct {
	self, want string
	stream     *quic.Stream
	added      time.Time
}

// Relay QUIC 中继服务器。
type Relay struct {
	addr    string
	dataDir string

	mu      sync.Mutex
	pending map[string]*half // device_id -> 等待对端的流
}

func New(addr, dataDir string) *Relay {
	return &Relay{addr: addr, dataDir: dataDir, pending: make(map[string]*half)}
}

// Listen 监听 UDP 并在 ctx 取消后停止接受新连接。
func (r *Relay) Listen(ctx context.Context) error {
	cert, err := ensureCert(r.dataDir)
	if err != nil {
		return err
	}
	cfg := &quic.Config{
		MaxIdleTimeout:        60 * time.Second,
		MaxIncomingStreams:    1024,
		MaxIncomingUniStreams: 1024,
	}
	ln, err := quic.ListenAddr(r.addr, tlsConfig(cert), cfg)
	if err != nil {
		return err
	}
	defer ln.Close()
	log.Printf("relay: quic listening on %s (alpn %s)", r.addr, alpn)

	go func() {
		<-ctx.Done()
		_ = ln.Close()
	}()
	for {
		conn, err := ln.Accept(ctx)
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			log.Printf("relay: accept: %v", err)
			return err
		}
		go r.handleConn(ctx, conn)
	}
}

func tlsConfig(cert tls.Certificate) *tls.Config {
	return &tls.Config{
		Certificates: []tls.Certificate{cert},
		NextProtos:   []string{alpn},
	}
}

func (r *Relay) handleConn(ctx context.Context, conn *quic.Conn) {
	for {
		stream, err := conn.AcceptStream(ctx)
		if err != nil {
			return
		}
		go r.handleStream(ctx, stream)
	}
}

// handleStream 读取 relay_hello，与已等待的对端配对；否则挂起等待。
func (r *Relay) handleStream(ctx context.Context, stream *quic.Stream) {
	_ = stream.SetDeadline(time.Now().Add(helloWait))
	var h hello
	if err := readHello(stream, &h); err != nil || h.T != "relay_hello" || h.DeviceID == "" || h.Peer == "" {
		log.Printf("relay: bad hello: %v", err)
		_ = stream.Close()
		return
	}
	_ = stream.SetDeadline(time.Time{})

	r.mu.Lock()
	r.sweepLocked()
	other, ok := r.pending[h.Peer]
	if ok && other.want == h.DeviceID {
		delete(r.pending, h.Peer)
		r.mu.Unlock()
		log.Printf("relay: paired %s <-> %s", h.DeviceID, h.Peer)
		pump(other.stream, stream)
		return
	}
	if stale, existed := r.pending[h.DeviceID]; existed {
		_ = stale.stream.Close()
	}
	r.pending[h.DeviceID] = &half{self: h.DeviceID, want: h.Peer, stream: stream, added: time.Now()}
	r.mu.Unlock()
}

// sweepLocked 清理超时未配对的半连接。
func (r *Relay) sweepLocked() {
	for id, h := range r.pending {
		if time.Since(h.added) > pairWait {
			_ = h.stream.Close()
			delete(r.pending, id)
		}
	}
}

// pump 双向 io.Copy；任一方向结束即关闭两条流。
func pump(a, b *quic.Stream) {
	done := make(chan struct{}, 2)
	go func() { _, _ = io.Copy(b, a); done <- struct{}{} }()
	go func() { _, _ = io.Copy(a, b); done <- struct{}{} }()
	<-done
	_ = a.Close()
	_ = b.Close()
	<-done
}

// readHello 按规范 §2 控制流帧格式读取：u32 大端长度 + UTF-8 JSON。
func readHello(r io.Reader, h *hello) error {
	var lenBuf [4]byte
	if _, err := io.ReadFull(r, lenBuf[:]); err != nil {
		return err
	}
	n := binary.BigEndian.Uint32(lenBuf[:])
	if n == 0 || n > 64*1024 {
		return io.ErrUnexpectedEOF
	}
	payload := make([]byte, n)
	if _, err := io.ReadFull(r, payload); err != nil {
		return err
	}
	return json.Unmarshal(payload, h)
}
