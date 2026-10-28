package ws

// 信令消息类型，字段名严格遵循 uu-proto.md §8。

// InMsg 设备→服务端消息的公共字段。
type InMsg struct {
	T      string   `json:"t"`
	To     string   `json:"to,omitempty"`     // invite_result 的目标设备
	Peer   string   `json:"peer,omitempty"`   // candidates / relay_open / presence 的对端设备
	Accept *bool    `json:"accept,omitempty"` // invite_result
	Addrs  []string `json:"addrs,omitempty"`  // candidates 上报的公网地址
}

type presenceMsg struct {
	T        string `json:"t"`
	DeviceID string `json:"device_id"`
	Status   string `json:"status"` // online | offline
}

type inviteMsg struct {
	T        string `json:"t"`
	From     string `json:"from"` // 发起配对的设备名
	Code     string `json:"code"`
	DeviceID string `json:"device_id"` // 发起配对的 device_id
}

type candidatesMsg struct {
	T     string   `json:"t"`
	Peer  string   `json:"peer"`
	Addrs []string `json:"addrs"`
}

type relayOpenMsg struct {
	T    string `json:"t"`
	Peer string `json:"peer"`
}

type genCodeReply struct {
	T         string `json:"t"`
	Code      string `json:"code"`
	ExpiresIn int    `json:"expires_in"` // 秒
}

type revokeCodeReply struct {
	T  string `json:"t"`
	OK bool   `json:"ok"`
}

type reflectReply struct {
	T    string `json:"t"`
	IP   string `json:"ip"`
	Port int    `json:"port"`
}

type errorMsg struct {
	T    string `json:"t"`
	Code int    `json:"code"`
	Msg  string `json:"msg"`
}

// 错误码：2001 沿用规范 §9；4004/4005 为本服务端扩展（目标离线 / 消息非法）。
const (
	codePairInvalid = 2001
	codeTargetOff   = 4004
	codeBadMessage  = 4005
)
