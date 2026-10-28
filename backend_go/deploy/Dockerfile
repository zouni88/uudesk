# uudesk-server 镜像（compose build context = backend_go/）
FROM golang:1.25-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o /out/uudesk-server ./cmd/uudesk-server

FROM alpine:3.20
RUN apk add --no-cache ca-certificates
COPY --from=build /out/uudesk-server /usr/local/bin/uudesk-server
EXPOSE 8080 8443/udp
ENTRYPOINT ["uudesk-server", "-http", ":8080", "-quic", ":8443", "-data", "/data"]
