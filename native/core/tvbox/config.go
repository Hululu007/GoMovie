package tvbox

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"runtime"
	"strings"
)

type SiteKind string

const (
	KindCMS SiteKind = "cms"
	KindT4  SiteKind = "t4"
	KindJar SiteKind = "jar"
)

type FlexInt int

func (f *FlexInt) UnmarshalJSON(data []byte) error {
	s := strings.TrimSpace(string(data))
	if s == "" || s == "null" {
		*f = 0
		return nil
	}
	if strings.HasPrefix(s, `"`) && strings.HasSuffix(s, `"`) {
		s = strings.Trim(s, `"`)
	}
	if s == "" {
		*f = 0
		return nil
	}
	var n int
	if _, err := fmt.Sscanf(s, "%d", &n); err != nil {
		return nil
	}
	*f = FlexInt(n)
	return nil
}

type Site struct {
	Key         string   `json:"key"`
	Name        string   `json:"name"`
	Type        FlexInt  `json:"type"`
	API         string   `json:"api"`
	Searchable  FlexInt  `json:"searchable"`
	QuickSearch FlexInt  `json:"quickSearch"`
	Filterable  FlexInt  `json:"filterable"`
	Ext         any      `json:"ext,omitempty"`
	Kind        SiteKind `json:"kind"`
	Supported   bool     `json:"supported"`
}

type ParseItem struct {
	Name string  `json:"name"`
	Type FlexInt `json:"type"`
	URL  string  `json:"url"`
}

type Config struct {
	Spider string      `json:"spider,omitempty"`
	Sites  []Site      `json:"sites"`
	Parses []ParseItem `json:"parses,omitempty"`
}

// FetchConfig 下载并解析饭太硬 / TVBox 订阅配置。
func FetchConfig(ctx context.Context, client *http.Client, rawURL string) (*Config, error) {
	u := strings.TrimSpace(rawURL)
	if !strings.HasPrefix(u, "http://") && !strings.HasPrefix(u, "https://") {
		return nil, errors.New("订阅地址必须以 http:// 或 https:// 开头")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "okhttp/3.15")
	if client == nil {
		client = http.DefaultClient
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("订阅请求失败（HTTP %d）", resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return nil, err
	}
	return ParseConfig(body)
}

// ParseConfig 解析原始订阅文本（兼容注释与 **Base64 混淆）。
func ParseConfig(raw []byte) (*Config, error) {
	text := strings.TrimSpace(string(raw))
	text = strings.TrimPrefix(text, "\ufeff")
	if text == "" {
		return nil, errors.New("订阅内容为空")
	}
	if idx := strings.LastIndex(text, "**"); idx >= 0 && !strings.HasPrefix(text, "{") {
		encoded := strings.TrimSpace(text[idx+2:])
		if decoded, err := decodeBase64Flexible(encoded); err == nil {
			text = string(decoded)
		}
	} else if !strings.HasPrefix(text, "{") && !strings.HasPrefix(text, "//") && !strings.HasPrefix(text, "/*") {
		if decoded, err := decodeBase64Flexible(text); err == nil && strings.Contains(string(decoded), "{") {
			text = string(decoded)
		}
	}
	cleaned := stripJSONComments(text)
	var cfg Config
	if err := json.Unmarshal([]byte(cleaned), &cfg); err != nil {
		return nil, fmt.Errorf("订阅 JSON 解析失败: %w", err)
	}
	for i := range cfg.Sites {
		s := &cfg.Sites[i]
		s.Kind, s.Supported = classifySite(*s)
	}
	return &cfg, nil
}

func classifySite(s Site) (SiteKind, bool) {
	api := strings.TrimSpace(s.API)
	lowerAPI := strings.ToLower(api)
	isHTTP := strings.HasPrefix(lowerAPI, "http://") || strings.HasPrefix(lowerAPI, "https://")
	isJS := strings.HasSuffix(lowerAPI, ".js") || strings.Contains(lowerAPI, ".js?")
	switch s.Type {
	case 0, 1:
		return KindCMS, isHTTP
	case 4:
		return KindT4, isHTTP && !isJS
	default:
		if isHTTP && !isJS && !strings.HasPrefix(lowerAPI, "csp_") {
			return KindT4, true
		}
		if strings.HasPrefix(lowerAPI, "csp_") {
			return KindJar, runtime.GOOS == "android"
		}
		return KindJar, false
	}
}

func decodeBase64Flexible(s string) ([]byte, error) {
	s = strings.TrimSpace(s)
	if b, err := base64.StdEncoding.DecodeString(s); err == nil {
		return b, nil
	}
	return base64.RawStdEncoding.DecodeString(s)
}

func stripJSONComments(input string) string {
	var out strings.Builder
	out.Grow(len(input))
	inString := false
	escaped := false
	for i := 0; i < len(input); i++ {
		c := input[i]
		if inString {
			out.WriteByte(c)
			if escaped {
				escaped = false
			} else if c == '\\' {
				escaped = true
			} else if c == '"' {
				inString = false
			}
			continue
		}
		if c == '"' {
			inString = true
			out.WriteByte(c)
			continue
		}
		if c == '/' && i+1 < len(input) && input[i+1] == '/' {
			for i < len(input) && input[i] != '\n' {
				i++
			}
			if i < len(input) {
				out.WriteByte('\n')
			}
			continue
		}
		if c == '/' && i+1 < len(input) && input[i+1] == '*' {
			i += 2
			for i+1 < len(input) && !(input[i] == '*' && input[i+1] == '/') {
				i++
			}
			i++
			continue
		}
		out.WriteByte(c)
	}
	return out.String()
}
