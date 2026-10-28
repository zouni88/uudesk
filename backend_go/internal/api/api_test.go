package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"uudesk-server/internal/pair"
	"uudesk-server/internal/store"
	"uudesk-server/internal/ws"
)

// TestSignalingFlow 端到端验证：注册 → WS 上线 → gen_code → /api/pair 推送 invite →
// invite_result/candidates/relay_open 路由 → reflect → health。
func TestSignalingFlow(t *testing.T) {
	devices, err := store.New(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	codes := pair.New()
	wsSrv := ws.NewServer(devices, codes)
	mux := http.NewServeMux()
	mux.Handle("/", NewServer(devices, codes, wsSrv.Hub()).Handler())
	mux.Handle("/ws", wsSrv)
	srv := httptest.NewServer(mux)
	defer srv.Close()

	tokenA := register(t, srv.URL, "alice", "pc", "devA")
	tokenB := register(t, srv.URL, "bob", "phone", "devB")
	if len(tokenA) != 64 || tokenA == tokenB {
		t.Fatalf("bad tokens: %q %q", tokenA, tokenB)
	}
	// 幂等注册应复用 token
	if again := register(t, srv.URL, "alice2", "pc", "devA"); again != tokenA {
		t.Fatal("re-register changed token")
	}

	wsURL := "ws" + strings.TrimPrefix(srv.URL, "http") + "/ws?token="
	connA := dialWS(t, wsURL+tokenA)
	defer connA.Close()
	connB := dialWS(t, wsURL+tokenB)
	defer connB.Close()

	// 被控端 B 生成配对码
	wsSend(t, connB, map[string]any{"t": "gen_code"})
	var codeReply struct {
		T    string `json:"t"`
		Code string `json:"code"`
	}
	readUntil(t, connB, "gen_code", &codeReply)
	if len(codeReply.Code) != 6 {
		t.Fatalf("bad code %q", codeReply.Code)
	}

	// 控制端 A 用配对码发起配对，B 应收到 invite
	resp := postJSON(t, srv.URL+"/api/pair", map[string]string{"code": codeReply.Code, "device_id": "devA"})
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("pair: %d", resp.StatusCode)
	}
	var invite struct {
		T        string `json:"t"`
		From     string `json:"from"`
		Code     string `json:"code"`
		DeviceID string `json:"device_id"`
	}
	readUntil(t, connB, "invite", &invite)
	if invite.From != "alice2" || invite.DeviceID != "devA" {
		t.Fatalf("bad invite: %+v", invite)
	}

	// B 回复 invite_result → A 收到
	wsSend(t, connB, map[string]any{"t": "invite_result", "to": "devA", "accept": true})
	var result struct {
		T      string `json:"t"`
		To     string `json:"to"`
		Accept bool   `json:"accept"`
	}
	readUntil(t, connA, "invite_result", &result)
	if !result.Accept || result.To != "devA" {
		t.Fatalf("bad invite_result: %+v", result)
	}

	// A 上报 candidates → B 收到 A 的地址；A 收到 B 的已知地址（互发）
	wsSend(t, connA, map[string]any{"t": "candidates", "peer": "devB", "addrs": []string{"8.8.8.8:1234"}})
	var candB struct {
		T     string   `json:"t"`
		Peer  string   `json:"peer"`
		Addrs []string `json:"addrs"`
	}
	readUntil(t, connB, "candidates", &candB)
	if candB.Peer != "devA" || candB.Addrs[0] != "8.8.8.8:1234" {
		t.Fatalf("bad candidates to B: %+v", candB)
	}
	var candA struct {
		T     string   `json:"t"`
		Peer  string   `json:"peer"`
		Addrs []string `json:"addrs"`
	}
	readUntil(t, connA, "candidates", &candA)
	if candA.Peer != "devB" || len(candA.Addrs) == 0 {
		t.Fatalf("bad candidates back to A: %+v", candA)
	}

	// relay_open 路由
	wsSend(t, connA, map[string]any{"t": "relay_open", "peer": "devB"})
	var ro struct {
		T    string `json:"t"`
		Peer string `json:"peer"`
	}
	readUntil(t, connB, "relay_open", &ro)
	if ro.Peer != "devA" {
		t.Fatalf("bad relay_open: %+v", ro)
	}

	// WS reflect 返回观察地址
	wsSend(t, connA, map[string]any{"t": "reflect"})
	var refl struct {
		T  string `json:"t"`
		IP string `json:"ip"`
	}
	readUntil(t, connA, "reflect", &refl)
	if refl.IP == "" {
		t.Fatalf("bad reflect: %+v", refl)
	}

	// HTTP reflect
	var rr struct {
		IP   string `json:"ip"`
		Addr string `json:"addr"`
	}
	getJSON(t, srv.URL+"/api/reflect", &rr)
	if rr.IP == "" || rr.Addr == "" {
		t.Fatalf("bad /api/reflect: %+v", rr)
	}

	// health
	var h struct {
		Status string `json:"status"`
		Online int    `json:"online"`
	}
	getJSON(t, srv.URL+"/api/health", &h)
	if h.Status != "ok" || h.Online != 2 {
		t.Fatalf("bad health: %+v", h)
	}

	// 离线路由错误：断开 B 后 A 再发 relay_open，应收到 error(4004)
	connB.Close()
	time.Sleep(100 * time.Millisecond)
	wsSend(t, connA, map[string]any{"t": "relay_open", "peer": "devB"})
	var e struct {
		T    string `json:"t"`
		Code int    `json:"code"`
	}
	readUntil(t, connA, "error", &e)
	if e.Code != 4004 {
		t.Fatalf("bad offline error: %+v", e)
	}
}

func register(t *testing.T, base, name, role, id string) string {
	t.Helper()
	resp := postJSON(t, base+"/api/register", map[string]string{
		"name": name, "role": role, "device_id": id, "spki_pin": "pin-" + id,
	})
	var out struct {
		Token    string `json:"token"`
		DeviceID string `json:"device_id"`
	}
	decode(t, resp, &out)
	if out.DeviceID != id || out.Token == "" {
		t.Fatalf("register %s -> %+v", id, out)
	}
	return out.Token
}

func postJSON(t *testing.T, url string, body any) *http.Response {
	t.Helper()
	data, _ := json.Marshal(body)
	resp, err := http.Post(url, "application/json", bytes.NewReader(data))
	if err != nil {
		t.Fatalf("post %s: %v", url, err)
	}
	return resp
}

func getJSON(t *testing.T, url string, v any) {
	t.Helper()
	resp, err := http.Get(url)
	if err != nil {
		t.Fatalf("get %s: %v", url, err)
	}
	defer resp.Body.Close()
	if err := json.NewDecoder(resp.Body).Decode(v); err != nil {
		t.Fatalf("decode %s: %v", url, err)
	}
}

func decode(t *testing.T, resp *http.Response, v any) {
	t.Helper()
	defer resp.Body.Close()
	if err := json.NewDecoder(resp.Body).Decode(v); err != nil {
		t.Fatalf("decode: %v", err)
	}
}

func dialWS(t *testing.T, url string) *websocket.Conn {
	t.Helper()
	conn, _, err := websocket.DefaultDialer.Dial(url, nil)
	if err != nil {
		t.Fatalf("dial %s: %v", url, err)
	}
	return conn
}

func wsSend(t *testing.T, conn *websocket.Conn, v any) {
	t.Helper()
	data, _ := json.Marshal(v)
	if err := conn.WriteMessage(websocket.TextMessage, data); err != nil {
		t.Fatalf("ws write: %v", err)
	}
}

// readUntil 读取直到出现指定 t 类型的消息（跳过 presence 等），超时失败。
func readUntil(t *testing.T, conn *websocket.Conn, want string, v any) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		_ = conn.SetReadDeadline(time.Now().Add(3 * time.Second))
		_, data, err := conn.ReadMessage()
		if err != nil {
			t.Fatalf("ws read waiting %q: %v", want, err)
		}
		var head struct {
			T string `json:"t"`
		}
		if json.Unmarshal(data, &head) != nil {
			continue
		}
		if head.T == want {
			if err := json.Unmarshal(data, v); err != nil {
				t.Fatalf("decode %q: %v", want, err)
			}
			return
		}
	}
	t.Fatalf("timeout waiting for %q", want)
}
