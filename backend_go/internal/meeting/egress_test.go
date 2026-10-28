package meeting

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// signWebhook 按 LiveKit 方案生成签名 JWT：HS256 + sha256(body) claim。
func signWebhook(t *testing.T, secret string, body []byte) string {
	t.Helper()
	sum := sha256.Sum256(body)
	claims := jwt.MapClaims{
		"iss":    "devkey",
		"sha256": hex.EncodeToString(sum[:]),
		"exp":    time.Now().Add(time.Minute).Unix(),
		"nbf":    time.Now().Add(-time.Minute).Unix(),
	}
	s, err := jwt.NewWithClaims(jwt.SigningMethodHS256, claims).SignedString([]byte(secret))
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func postWebhook(t *testing.T, url string, body []byte, sig string) *http.Response {
	t.Helper()
	req, err := http.NewRequest(http.MethodPost, url+"/api/meeting/webhook", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Content-Type", "application/json")
	if sig != "" {
		req.Header.Set("X-Livekit-Signature", sig)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	return resp
}

func getRecordings(t *testing.T, url string) []Recording {
	t.Helper()
	resp, err := http.Get(url + "/api/meeting/recordings")
	if err != nil {
		t.Fatal(err)
	}
	var out struct {
		Recordings []Recording `json:"recordings"`
	}
	decodeResp(t, resp, &out)
	return out.Recordings
}

// TestWebhookRecordsEgressEnded 合法签名的 EgressEnded 事件应记入列表并持久化。
func TestWebhookRecordsEgressEnded(t *testing.T) {
	dir := t.TempDir()
	rec, err := NewRecordings(dir)
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(NewServer(testCfg, rec).Handler())
	defer srv.Close()

	event, _ := json.Marshal(map[string]any{
		"type": "egress_ended",
		"event": map[string]any{
			"room":   map[string]any{"name": "standup"},
			"egress": map[string]any{"egress_id": "eg_1", "status": "EGRESS_END", "room": "standup", "filepath": "/recordings/standup/a.mp4"},
		},
	})
	resp := postWebhook(t, srv.URL, event, signWebhook(t, testCfg.APISecret, event))
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("webhook: %d", resp.StatusCode)
	}
	resp.Body.Close()

	// 非录制事件应被忽略但仍返回 200
	other, _ := json.Marshal(map[string]any{"type": "participant_joined"})
	resp = postWebhook(t, srv.URL, other, signWebhook(t, testCfg.APISecret, other))
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("non-egress webhook: %d", resp.StatusCode)
	}
	resp.Body.Close()

	list := getRecordings(t, srv.URL)
	if len(list) != 1 {
		t.Fatalf("recordings = %+v", list)
	}
	got := list[0]
	if got.Room != "standup" || got.EgressID != "eg_1" || got.FilePath != "/recordings/standup/a.mp4" {
		t.Fatalf("bad recording: %+v", got)
	}
	if _, err := time.Parse(time.RFC3339, got.EndedAt); err != nil {
		t.Fatalf("ended_at: %v", err)
	}

	// 持久化：重新加载后仍在
	reloaded, err := NewRecordings(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(reloaded.List("standup")) != 1 || len(reloaded.List("other")) != 0 {
		t.Fatalf("reload: %+v", reloaded.items)
	}
	data, err := os.ReadFile(filepath.Join(dir, "recordings.json"))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(data, []byte("eg_1")) {
		t.Fatalf("recordings.json missing entry: %s", data)
	}
}

// TestWebhookSignatureChecks 签名错误、body 篡改、缺签名均应拒绝。
func TestWebhookSignatureChecks(t *testing.T) {
	srv := newTestServer(t, testCfg)
	event, _ := json.Marshal(map[string]any{
		"type": "egress_ended",
		"event": map[string]any{
			"egress": map[string]any{"egress_id": "eg_x", "status": "EGRESS_END", "room": "r", "filepath": "/x.mp4"},
		},
	})

	// 密钥错误
	if resp := postWebhook(t, srv.URL, event, signWebhook(t, "wrong-secret-0123456789abcdef-0123456789", event)); resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("wrong secret: %d", resp.StatusCode)
	} else {
		resp.Body.Close()
	}
	// 缺签名
	if resp := postWebhook(t, srv.URL, event, ""); resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("missing sig: %d", resp.StatusCode)
	} else {
		resp.Body.Close()
	}
	// 签名合法但 body 被篡改（sha256 claim 不匹配）
	sig := signWebhook(t, testCfg.APISecret, event)
	tampered := append(append([]byte{}, event...), []byte(" ")...)
	if resp := postWebhook(t, srv.URL, tampered, sig); resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("tampered body: %d", resp.StatusCode)
	} else {
		resp.Body.Close()
	}
	if list := getRecordings(t, srv.URL); len(list) != 0 {
		t.Fatalf("rejected events recorded: %+v", list)
	}
}

// TestEgressStartCommand 返回 livekit-cli 命令，且不回显 API secret。
func TestEgressStartCommand(t *testing.T) {
	srv := newTestServer(t, testCfg)
	body, _ := json.Marshal(map[string]string{"room": "weekly"})
	resp, err := http.Post(srv.URL+"/api/meeting/egress/start", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	var out struct {
		OK      bool   `json:"ok"`
		Command string `json:"command"`
	}
	decodeResp(t, resp, &out)
	if !out.OK || !strings.Contains(out.Command, "start-room-composite-egress") {
		t.Fatalf("bad response: %+v", out)
	}
	if !strings.Contains(out.Command, `"roomName":"weekly"`) || !strings.Contains(out.Command, "MP4") {
		t.Fatalf("bad command: %s", out.Command)
	}
	if strings.Contains(out.Command, testCfg.APISecret) {
		t.Fatal("command leaks api secret")
	}

	// 房间名含单引号不应破坏 shell 引用
	body, _ = json.Marshal(map[string]string{"room": "o'brien"})
	resp, err = http.Post(srv.URL+"/api/meeting/egress/start", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	decodeResp(t, resp, &out)
	if !strings.Contains(out.Command, `'\''`) {
		t.Fatalf("quote not escaped: %s", out.Command)
	}
}
