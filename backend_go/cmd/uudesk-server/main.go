// uudesk-server：UUDesk 公网信令 + 配对 + NAT 打洞辅助 + QUIC 应用层中继。
package main

import (
	"context"
	"errors"
	"flag"
	"log"
	"net/http"
	"os/signal"
	"syscall"
	"time"

	"uudesk-server/internal/api"
	"uudesk-server/internal/meeting"
	"uudesk-server/internal/pair"
	"uudesk-server/internal/relay"
	"uudesk-server/internal/store"
	"uudesk-server/internal/ws"
)

func main() {
	httpAddr := flag.String("http", ":8080", "HTTP/WS 监听地址")
	quicAddr := flag.String("quic", ":8443", "QUIC 中继监听地址")
	dataDir := flag.String("data", "./data", "数据目录（devices.json、中继证书）")
	flag.Parse()

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	devices, err := store.New(*dataDir)
	if err != nil {
		log.Fatalf("store: %v", err)
	}
	codes := pair.New()
	wsSrv := ws.NewServer(devices, codes)

	// 会议模块：环境变量缺失时服务器照常启动，接口返回 5001。
	recordings, err := meeting.NewRecordings(*dataDir)
	if err != nil {
		log.Fatalf("recordings: %v", err)
	}
	meetingCfg := meeting.ConfigFromEnv()
	if !meetingCfg.Valid() {
		log.Print("meeting: LIVEKIT_API_KEY/LIVEKIT_API_SECRET 未配置，会议接口不可用")
	}

	mux := http.NewServeMux()
	mux.Handle("/", api.NewServer(devices, codes, wsSrv.Hub()).Handler())
	mux.Handle("/ws", wsSrv)
	mux.Handle("/api/meeting/", meeting.NewServer(meetingCfg, recordings).Handler())

	httpSrv := &http.Server{Addr: *httpAddr, Handler: mux, ReadHeaderTimeout: 10 * time.Second}
	go func() {
		log.Printf("http: listening on %s", *httpAddr)
		if err := httpSrv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("http: %v", err)
		}
	}()

	relaySrv := relay.New(*quicAddr, *dataDir)
	go func() {
		if err := relaySrv.Listen(ctx); err != nil && ctx.Err() == nil {
			log.Fatalf("relay: %v", err)
		}
	}()

	<-ctx.Done()
	log.Print("shutting down...")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = httpSrv.Shutdown(shutdownCtx)
}
