// Package store 维护设备注册表（device_id ↔ token），并持久化到 data/devices.json。
package store

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sync"
)

// Device 一台已注册设备。
type Device struct {
	Name     string `json:"name"`
	Role     string `json:"role"`
	DeviceID string `json:"device_id"`
	SPKIPin  string `json:"spki_pin"`
	Token    string `json:"token"`
}

// Store 设备注册表，并发安全。
type Store struct {
	mu      sync.RWMutex
	path    string
	devices map[string]*Device // device_id -> Device
	tokens  map[string]string  // token -> device_id
}

// New 加载（或创建）持久化文件。
func New(dataDir string) (*Store, error) {
	s := &Store{
		path:    filepath.Join(dataDir, "devices.json"),
		devices: make(map[string]*Device),
		tokens:  make(map[string]string),
	}
	if err := os.MkdirAll(dataDir, 0o700); err != nil {
		return nil, err
	}
	data, err := os.ReadFile(s.path)
	if errors.Is(err, os.ErrNotExist) {
		return s, nil
	}
	if err != nil {
		return nil, err
	}
	var list []*Device
	if err := json.Unmarshal(data, &list); err != nil {
		return nil, err
	}
	for _, d := range list {
		s.devices[d.DeviceID] = d
		s.tokens[d.Token] = d.DeviceID
	}
	return s, nil
}

// Register 幂等注册：device_id 已存在则更新资料并复用原 token，否则签发新 token。
func (s *Store) Register(name, role, deviceID, spkiPin string) *Device {
	s.mu.Lock()
	defer s.mu.Unlock()
	d, ok := s.devices[deviceID]
	if !ok {
		d = &Device{DeviceID: deviceID, Token: newToken()}
		s.devices[deviceID] = d
		s.tokens[d.Token] = deviceID
	}
	d.Name, d.Role, d.SPKIPin = name, role, spkiPin
	s.saveLocked()
	return d
}

// ByToken 按令牌查设备。
func (s *Store) ByToken(token string) (*Device, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	id, ok := s.tokens[token]
	if !ok {
		return nil, false
	}
	return s.devices[id], true
}

// ByID 按 device_id 查设备。
func (s *Store) ByID(deviceID string) (*Device, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	d, ok := s.devices[deviceID]
	return d, ok
}

// Count 已注册设备总数。
func (s *Store) Count() int {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return len(s.devices)
}

func newToken() string {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		panic("crypto/rand unavailable: " + err.Error())
	}
	return hex.EncodeToString(b)
}

// saveLocked 调用方需持有写锁；落盘失败仅影响持久化，不影响内存态。
func (s *Store) saveLocked() {
	list := make([]*Device, 0, len(s.devices))
	for _, d := range s.devices {
		list = append(list, d)
	}
	data, err := json.MarshalIndent(list, "", "  ")
	if err != nil {
		return
	}
	tmp := s.path + ".tmp"
	if os.WriteFile(tmp, data, 0o600) == nil {
		_ = os.Rename(tmp, s.path)
	}
}
