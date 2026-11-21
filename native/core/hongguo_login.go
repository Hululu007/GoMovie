package core

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// 红果扫码登录：二维码由服务端生成，App 扫码确认后回写会话 Cookie。
// 凭据只存应用私有目录（hongguo-session.json，0600），不上传任何服务。

const (
	hongguoLoginEndpoint = "https://hongguoduanju.com/passport/web/check_qrconnect/"
	hongguoSessionFile   = "hongguo-session.json"
	hongguoCookieDomain  = "hongguoduanju.com"
)

type hongguoLoginPayload struct {
	QRCode    string
	Status    string
	ExpiresAt int64
	Cookies   map[string]string
	Nickname  string
}

type hongguoSession struct {
	Cookies   map[string]string `json:"cookies"`
	Nickname  string            `json:"nickname,omitempty"`
	UpdatedAt int64             `json:"updatedAt"`
}

func hongguoNewToken() string {
	raw := make([]byte, 16)
	if _, err := rand.Read(raw); err != nil {
		return ""
	}
	return hex.EncodeToString(raw) + "_lf"
}

func (e *nativeEngine) hongguoSessionPath() string {
	dir := e.directory
	if dir == "" {
		return ""
	}
	return filepath.Join(dir, hongguoSessionFile)
}

// hongguoLoginStart 申请一个扫码会话，返回二维码 PNG（base64）。
func (e *nativeEngine) hongguoLoginStart(ctx context.Context) (map[string]any, error) {
	token := hongguoNewToken()
	if token == "" {
		return nil, errors.New("无法生成登录会话")
	}
	payload, err := e.hongguoLoginProbe(ctx, token)
	if err != nil {
		return nil, err
	}
	if payload.QRCode == "" {
		return nil, errors.New("红果没有返回二维码，请稍后再试")
	}
	return map[string]any{
		"session":   token,
		"qrBase64":  payload.QRCode,
		"status":    payload.Status,
		"expiresAt": payload.ExpiresAt,
	}, nil
}

// hongguoLoginPoll 轮询扫码结果；确认后把 Cookie 落到本地。
func (e *nativeEngine) hongguoLoginPoll(ctx context.Context, token string) (map[string]any, error) {
	token = strings.TrimSpace(token)
	if token == "" {
		return nil, errors.New("扫码会话已失效，请重新获取二维码")
	}
	payload, err := e.hongguoLoginProbe(ctx, token)
	if err != nil {
		return nil, err
	}
	if len(payload.Cookies) > 0 {
		session := hongguoSession{Cookies: payload.Cookies, Nickname: payload.Nickname, UpdatedAt: time.Now().Unix()}
		if err := e.saveHongguoSession(session); err != nil {
			return nil, err
		}
		return map[string]any{"status": "confirmed", "nickname": session.Nickname, "cookieCount": len(payload.Cookies)}, nil
	}
	return map[string]any{"status": payload.Status, "expiresAt": payload.ExpiresAt, "qrBase64": payload.QRCode}, nil
}

func (e *nativeEngine) hongguoStatus() map[string]any {
	session, err := e.loadHongguoSession()
	if err != nil || len(session.Cookies) == 0 {
		return map[string]any{"loggedIn": false}
	}
	return map[string]any{
		"loggedIn":    true,
		"nickname":    session.Nickname,
		"updatedAt":   session.UpdatedAt,
		"cookieCount": len(session.Cookies),
	}
}

func (e *nativeEngine) hongguoLogout() (map[string]any, error) {
	path := e.hongguoSessionPath()
	if path != "" {
		if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
			return nil, errors.New("退出登录失败")
		}
	}
	if e.downloader != nil {
		e.downloader.setHongguoCookie("")
	}
	return map[string]any{"loggedIn": false}, nil
}

func (e *nativeEngine) hongguoLoginProbe(ctx context.Context, token string) (hongguoLoginPayload, error) {
	query := url.Values{}
	query.Set("next", "https://hongguoduanju.com/")
	query.Set("token", token)
	query.Set("aid", "513755")
	query.Set("language", "zh")
	query.Set("is_from_ttaccountsdk", "1")
	query.Set("account_sdk_source", "web")
	query.Set("passport_jssdk_version", "2.4.13")
	query.Set("passport_jssdk_type", "normal")
	response, err := e.downloader.Fetch(ctx, HTTPRequest{
		Label:  "红果登录",
		Method: http.MethodGet,
		URL:    hongguoLoginEndpoint + "?" + query.Encode(),
		Header: map[string]string{
			"Referer": "https://hongguoduanju.com/",
			"Accept":  "application/json",
		},
		Timeout:         15 * time.Second,
		FollowRedirects: true,
		AnyStatus:       true,
	})
	if err != nil {
		return hongguoLoginPayload{}, errors.New("连接红果登录服务失败，请检查网络")
	}
	if response.Status != http.StatusOK {
		return hongguoLoginPayload{}, errors.New("红果登录服务暂不可用（HTTP " + itoa(response.Status) + "）")
	}
	var body struct {
		Data struct {
			QRCode    string `json:"qrcode"`
			Status    string `json:"status"`
			ExpireAt  int64  `json:"expire_time"`
			ErrorCode int    `json:"error_code"`
			Nickname  string `json:"nickname"`
			UserName  string `json:"user_name"`
		} `json:"data"`
		Message string `json:"message"`
	}
	if err := json.Unmarshal(response.Body, &body); err != nil {
		return hongguoLoginPayload{}, errors.New("红果登录服务返回格式异常")
	}
	payload := hongguoLoginPayload{
		QRCode:    body.Data.QRCode,
		Status:    strings.ToLower(strings.TrimSpace(body.Data.Status)),
		ExpiresAt: body.Data.ExpireAt,
		Nickname:  firstNonEmptyString(body.Data.Nickname, body.Data.UserName),
	}
	if payload.Status == "" {
		payload.Status = "pending"
	}
	if cookies := hongguoSessionCookies(response.Header); len(cookies) > 0 {
		payload.Cookies = cookies
	}
	return payload, nil
}

// 只收会话相关的 Cookie，其它统计/风控 Cookie 不落盘。
func hongguoSessionCookies(header map[string][]string) map[string]string {
	values := header["Set-Cookie"]
	if len(values) == 0 {
		values = header["set-cookie"]
	}
	cookies := map[string]string{}
	for _, raw := range values {
		parts := strings.Split(raw, ";")
		if len(parts) == 0 {
			continue
		}
		pair := strings.SplitN(strings.TrimSpace(parts[0]), "=", 2)
		if len(pair) != 2 || pair[1] == "" {
			continue
		}
		name := pair[0]
		if !strings.HasPrefix(name, "sessionid") && !strings.HasPrefix(name, "sid_") &&
			!strings.HasPrefix(name, "passport") && !strings.HasPrefix(name, "uid_tt") {
			continue
		}
		cookies[name] = pair[1]
	}
	return cookies
}

func (e *nativeEngine) loadHongguoSession() (hongguoSession, error) {
	path := e.hongguoSessionPath()
	if path == "" {
		return hongguoSession{}, errors.New("缺少应用目录")
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return hongguoSession{}, err
	}
	var session hongguoSession
	if err := json.Unmarshal(raw, &session); err != nil {
		return hongguoSession{}, err
	}
	return session, nil
}

func (e *nativeEngine) saveHongguoSession(session hongguoSession) error {
	path := e.hongguoSessionPath()
	if path == "" {
		return errors.New("缺少应用目录")
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return errors.New("无法创建凭据目录")
	}
	raw, err := json.Marshal(session)
	if err != nil {
		return errors.New("无法序列化凭据")
	}
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		return errors.New("无法保存凭据")
	}
	if e.downloader != nil {
		e.downloader.setHongguoCookie(hongguoCookieHeader(session.Cookies))
	}
	return nil
}

// 启动时把已存 Cookie 装进 Downloader。
func (e *nativeEngine) hongguoRestore() {
	if e.downloader == nil {
		return
	}
	session, err := e.loadHongguoSession()
	if err != nil || len(session.Cookies) == 0 {
		return
	}
	e.downloader.setHongguoCookie(hongguoCookieHeader(session.Cookies))
}

func hongguoCookieHeader(cookies map[string]string) string {
	if len(cookies) == 0 {
		return ""
	}
	names := make([]string, 0, len(cookies))
	for name := range cookies {
		names = append(names, name)
	}
	sort.Strings(names)
	parts := make([]string, 0, len(names))
	for _, name := range names {
		parts = append(parts, name+"="+cookies[name])
	}
	return strings.Join(parts, "; ")
}

func hongguoNeedsCookie(rawURL string) bool {
	return strings.Contains(rawURL, hongguoCookieDomain) || strings.Contains(rawURL, "snssdk.com/reading_offline")
}

func firstNonEmptyString(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return strings.TrimSpace(value)
		}
	}
	return ""
}

func itoa(value int) string {
	if value == 0 {
		return "0"
	}
	digits := ""
	for value > 0 {
		digits = string(rune('0'+value%10)) + digits
		value /= 10
	}
	return digits
}

func (d *Downloader) setHongguoCookie(value string) {
	d.hongguoCookieMu.Lock()
	d.hongguoCookie = value
	d.hongguoCookieMu.Unlock()
}

func (d *Downloader) hongguoCookieValue() string {
	d.hongguoCookieMu.RLock()
	defer d.hongguoCookieMu.RUnlock()
	return d.hongguoCookie
}
