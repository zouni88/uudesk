// Package pair 管理被控端生成的 6 位配对码（10 分钟有效，仅内存）。
package pair

import (
	crand "crypto/rand"
	"encoding/binary"
	"fmt"
	"sync"
	"time"
)

const ttl = 10 * time.Minute

type entry struct {
	deviceID string
	expires  time.Time
}

// Codes 配对码表，并发安全。
type Codes struct {
	mu    sync.Mutex
	byID  map[string]string // device_id -> code（每设备最多一个有效码）
	byVal map[string]entry  // code -> entry
}

func New() *Codes {
	return &Codes{byID: map[string]string{}, byVal: map[string]entry{}}
}

// Gen 为设备生成（或替换）配对码。
func (c *Codes) Gen(deviceID string) (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.revokeLocked(deviceID)
	code, err := sixDigits()
	if err != nil {
		return "", err
	}
	c.byID[deviceID] = code
	c.byVal[code] = entry{deviceID: deviceID, expires: time.Now().Add(ttl)}
	return code, nil
}

// Revoke 撤销设备当前配对码。
func (c *Codes) Revoke(deviceID string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.revokeLocked(deviceID)
}

func (c *Codes) revokeLocked(deviceID string) {
	if code, ok := c.byID[deviceID]; ok {
		delete(c.byVal, code)
		delete(c.byID, deviceID)
	}
}

// Lookup 只读校验配对码（不消费），有效返回持有设备 id。
func (c *Codes) Lookup(code string) (string, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	e, ok := c.byVal[code]
	if !ok || time.Now().After(e.expires) {
		return "", false
	}
	return e.deviceID, true
}

// Consume 校验配对码：有效则返回持有该码的设备 id 并作废（一次性）。
func (c *Codes) Consume(code string) (string, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	e, ok := c.byVal[code]
	if !ok || time.Now().After(e.expires) {
		return "", false
	}
	delete(c.byVal, code)
	delete(c.byID, e.deviceID)
	return e.deviceID, true
}

func sixDigits() (string, error) {
	var b [8]byte
	if _, err := crand.Read(b[:]); err != nil {
		return "", err
	}
	n := binary.BigEndian.Uint64(b[:]) % 1000000
	return fmt.Sprintf("%06d", n), nil
}
