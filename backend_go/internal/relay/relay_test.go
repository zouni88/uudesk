package relay

import (
	"context"
	"crypto/tls"
	"encoding/binary"
	"encoding/json"
	"io"
	"testing"
	"time"

	"github.com/quic-go/quic-go"
)

// TestRelayPairAndPump 两个 QUIC 客户端各自打开双向流发 relay_hello，
// 验证服务端按 peer 配对后双向转发原始字节。
func TestRelayPairAndPump(t *testing.T) {
	const addr = "127.0.0.1:18443"
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	r := New(addr, t.TempDir())
	errCh := make(chan error, 1)
	go func() { errCh <- r.Listen(ctx) }()

	clientCfg := &tls.Config{InsecureSkipVerify: true, NextProtos: []string{alpn}}
	var connA *quic.Conn
	for i := 0; i < 50; i++ {
		var err error
		connA, err = quic.DialAddr(ctx, addr, clientCfg, nil)
		if err == nil {
			break
		}
		select {
		case e := <-errCh:
			t.Fatalf("relay listen: %v", e)
		default:
		}
		time.Sleep(50 * time.Millisecond)
	}
	if connA == nil {
		t.Fatal("dial A failed")
	}
	defer connA.CloseWithError(0, "done")
	connB, err := quic.DialAddr(ctx, addr, clientCfg, nil)
	if err != nil {
		t.Fatalf("dial B: %v", err)
	}
	defer connB.CloseWithError(0, "done")

	streamA := openHello(t, ctx, connA, "devA", "devB")
	streamB := openHello(t, ctx, connB, "devB", "devA")

	// A→B 原始字节
	if _, err := streamA.Write([]byte("ping")); err != nil {
		t.Fatal(err)
	}
	buf := make([]byte, 4)
	_ = streamB.SetReadDeadline(time.Now().Add(3 * time.Second))
	if _, err := io.ReadFull(streamB, buf); err != nil {
		t.Fatalf("B read: %v", err)
	}
	if string(buf) != "ping" {
		t.Fatalf("B got %q", buf)
	}
	// B→A 原始字节
	if _, err := streamB.Write([]byte("pong")); err != nil {
		t.Fatal(err)
	}
	_ = streamA.SetReadDeadline(time.Now().Add(3 * time.Second))
	if _, err := io.ReadFull(streamA, buf); err != nil {
		t.Fatalf("A read: %v", err)
	}
	if string(buf) != "pong" {
		t.Fatalf("A got %q", buf)
	}
}

func openHello(t *testing.T, ctx context.Context, conn *quic.Conn, self, peer string) *quic.Stream {
	t.Helper()
	stream, err := conn.OpenStreamSync(ctx)
	if err != nil {
		t.Fatalf("open stream %s: %v", self, err)
	}
	payload, _ := json.Marshal(map[string]string{"t": "relay_hello", "peer": peer, "device_id": self})
	var lenBuf [4]byte
	binary.BigEndian.PutUint32(lenBuf[:], uint32(len(payload)))
	if _, err := stream.Write(append(lenBuf[:], payload...)); err != nil {
		t.Fatalf("write hello %s: %v", self, err)
	}
	return stream
}
