package core

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

var (
	webViewBridgeMu    sync.RWMutex
	webViewBridgePort  int
	webViewBridgeHosts = map[string]bool{}
	webViewLocalClient = &http.Client{Timeout: 25 * time.Second}
)

func (engine *nativeEngine) setWebViewBridge(port int, rawHost, source string) map[string]any {
	hosts := make([]string, 0, 4)
	if h := normalizeBridgeHost(rawHost); h != "" {
		hosts = append(hosts, h)
	}
	if source != "" {
		if desc, ok := registeredDescriptor(canonicalProviderSource(source)); ok {
			for _, alias := range desc.Aliases {
				if h := normalizeBridgeHost(alias); h != "" {
					hosts = append(hosts, h)
				}
			}
			for _, h := range desc.Hosts {
				if clean := normalizeBridgeHost(h); clean != "" && !strings.HasPrefix(clean, "*.") {
					hosts = append(hosts, clean)
				}
			}
		}
		if engine.downloader != nil {
			if base := engine.downloader.providerBaseURL(source); base != "" {
				if h := normalizeBridgeHost(base); h != "" {
					hosts = append(hosts, h)
				}
			}
		}
	}

	webViewBridgeMu.Lock()
	if port > 0 {
		webViewBridgePort = port
	}
	for _, h := range hosts {
		webViewBridgeHosts[h] = true
	}
	webViewBridgeMu.Unlock()

	if engine.downloader != nil && engine.downloader.limiter != nil {
		engine.downloader.limiter.mu.Lock()
		for _, h := range hosts {
			delete(engine.downloader.limiter.backoffs, h)
			delete(engine.downloader.limiter.backgroundBackoffs, h)
		}
		engine.downloader.limiter.mu.Unlock()
	}
	return map[string]any{"ok": true, "hosts": hosts}
}

func (engine *nativeEngine) sourceChallengeURL(source string) string {
	id := canonicalProviderSource(source)
	if engine.downloader != nil {
		if base := strings.TrimSpace(engine.downloader.providerBaseURL(id)); base != "" {
			return base
		}
	}
	if desc, ok := registeredDescriptor(id); ok {
		for _, h := range desc.Hosts {
			h = strings.TrimSpace(h)
			if h != "" && !strings.HasPrefix(h, "*.") {
				return "https://" + h
			}
		}
	}
	return ""
}

func normalizeBridgeHost(raw string) string {
	s := strings.TrimSpace(raw)
	if s == "" {
		return ""
	}
	if strings.Contains(s, "://") {
		if u, err := url.Parse(s); err == nil {
			return strings.ToLower(u.Hostname())
		}
	}
	if host, _, ok := strings.Cut(s, ":"); ok {
		s = host
	}
	return strings.ToLower(strings.TrimSpace(s))
}

func isWebViewBridgeHost(rawURL string) (int, string, bool) {
	u, err := url.Parse(rawURL)
	if err != nil {
		return 0, "", false
	}
	host := strings.ToLower(u.Hostname())
	if host == "" {
		return 0, "", false
	}
	webViewBridgeMu.RLock()
	port := webViewBridgePort
	ok := port > 0 && webViewBridgeHosts[host]
	webViewBridgeMu.RUnlock()
	return port, host, ok
}

func webViewBridgeFetch(ctx context.Context, rawURL string) (string, string, bool, error) {
	port, host, ok := isWebViewBridgeHost(rawURL)
	if !ok {
		return "", "", false, nil
	}
	endpoint := fmt.Sprintf("http://127.0.0.1:%d/fetch?url=%s", port, url.QueryEscape(rawURL))
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return "", "", true, err
	}
	resp, err := webViewLocalClient.Do(req)
	if err != nil {
		return "", "", true, err
	}
	defer resp.Body.Close()
	bodyBytes, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return "", "", true, err
	}
	var payload struct {
		OK    bool   `json:"ok"`
		HTML  string `json:"html"`
		URL   string `json:"url"`
		Error string `json:"error"`
	}
	if err := json.Unmarshal(bodyBytes, &payload); err != nil {
		return "", "", true, err
	}
	if !payload.OK {
		if payload.Error != "" {
			return "", "", true, errors.New(payload.Error)
		}
		return "", "", true, errors.New("WebView 请求失败")
	}
	lower := strings.ToLower(payload.HTML)
	if strings.Contains(lower, "_cf_chl_opt") || (strings.Contains(lower, "<title>just a moment") && strings.Contains(lower, "cloudflare")) {
		webViewBridgeMu.Lock()
		delete(webViewBridgeHosts, host)
		webViewBridgeMu.Unlock()
		return "", "", true, errors.New("该站已开启 Cloudflare 人机验证，请点击「完成人机验证」通过后再试")
	}
	finalURL := payload.URL
	if finalURL == "" {
		finalURL = rawURL
	}
	return payload.HTML, finalURL, true, nil
}
