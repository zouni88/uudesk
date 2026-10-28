package meeting

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

var testCfg = Config{APIKey: "devkey", APISecret: "this-is-a-test-secret-0123456789abcdef", ServerURL: "wss://meet.example:7881"}

func newTestServer(t *testing.T, cfg Config) *httptest.Server {
	t.Helper()
	rec, err := NewRecordings(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(NewServer(cfg, rec).Handler())
	t.Cleanup(srv.Close)
	return srv
}

// TestTokenGrant 校验签发 JWT 的结构与 video grant（规范 §10.1）。
func TestTokenGrant(t *testing.T) {
	srv := newTestServer(t, testCfg)
	for _, canPub := range []bool{true, false} {
		body, _ := json.Marshal(map[string]any{"room": "r1", "identity": "devA", "can_publish": canPub})
		resp, err := http.Post(srv.URL+"/api/meeting/token", "application/json", bytes.NewReader(body))
		if err != nil {
			t.Fatal(err)
		}
		var out struct {
			Token     string `json:"token"`
			ServerURL string `json:"server_url"`
		}
		if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if out.ServerURL != testCfg.ServerURL {
			t.Fatalf("server_url = %q", out.ServerURL)
		}

		claims := jwt.MapClaims{}
		tok, err := jwt.ParseWithClaims(out.Token, claims, func(*jwt.Token) (any, error) {
			return []byte(testCfg.APISecret), nil
		}, jwt.WithValidMethods([]string{"HS256"}))
		if err != nil || !tok.Valid {
			t.Fatalf("verify token: %v", err)
		}
		if claims["iss"] != testCfg.APIKey || claims["sub"] != "devA" {
			t.Fatalf("iss/sub = %v/%v", claims["iss"], claims["sub"])
		}
		expF, ok := claims["exp"].(float64)
		if !ok {
			t.Fatalf("exp claim: %T", claims["exp"])
		}
		want := time.Now().Add(tokenTTL).Unix()
		if d := expF - float64(want); d < -5 || d > 5 {
			t.Fatalf("exp = %v, want ~%v", expF, want)
		}
		grant, ok := claims["video"].(map[string]any)
		if !ok {
			t.Fatalf("video grant: %T", claims["video"])
		}
		if grant["room"] != "r1" || grant["roomAdmin"] != true ||
			grant["canSubscribe"] != true || grant["canPublishData"] != true ||
			grant["canPublish"] != canPub {
			t.Fatalf("bad grant: %+v", grant)
		}
	}
}

// TestTokenDefaults 缺省 can_publish 应为 true；缺参/未配置返回错误码而非 panic。
func TestTokenDefaults(t *testing.T) {
	srv := newTestServer(t, testCfg)
	body, _ := json.Marshal(map[string]string{"room": "r1", "identity": "devA"})
	resp, err := http.Post(srv.URL+"/api/meeting/token", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	var out struct {
		Token string `json:"token"`
	}
	decodeResp(t, resp, &out)
	claims := jwt.MapClaims{}
	if _, err := jwt.ParseWithClaims(out.Token, claims, func(*jwt.Token) (any, error) {
		return []byte(testCfg.APISecret), nil
	}); err != nil {
		t.Fatal(err)
	}
	grant := claims["video"].(map[string]any)
	if grant["canPublish"] != true {
		t.Fatalf("default can_publish = %v", grant["canPublish"])
	}

	// 缺 room/identity → 400
	resp, _ = http.Post(srv.URL+"/api/meeting/token", "application/json", strings.NewReader(`{"room":"r1"}`))
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("missing identity: %d", resp.StatusCode)
	}
	resp.Body.Close()

	// 未配置 key/secret → 503 + code 5001，不 panic
	unconfigured := newTestServer(t, Config{})
	resp, _ = http.Post(unconfigured.URL+"/api/meeting/token", "application/json", bytes.NewReader(body))
	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("unconfigured: %d", resp.StatusCode)
	}
	var e errorBody
	decodeResp(t, resp, &e)
	if e.Code != 5001 {
		t.Fatalf("unconfigured code = %d", e.Code)
	}
}

func decodeResp(t *testing.T, resp *http.Response, v any) {
	t.Helper()
	defer resp.Body.Close()
	if err := json.NewDecoder(resp.Body).Decode(v); err != nil {
		t.Fatalf("decode: %v", err)
	}
}
