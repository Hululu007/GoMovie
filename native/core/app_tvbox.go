package core

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"

	"gomovie/native/core/tvbox"
)

type tvboxSubscriptionState struct {
	URL            string       `json:"url"`
	Sites          []tvbox.Site `json:"sites"`
	RegisteredIDs  []string     `json:"registeredIds"`
	SupportedCount int          `json:"supportedCount"`
	SkippedCount   int          `json:"skippedCount"`
}

var (
	tvboxMu      sync.Mutex
	tvboxState   *tvboxSubscriptionState
	tvboxLoaded  bool
	tvboxKeySafe = regexp.MustCompile(`[^a-zA-Z0-9_-]+`)
)

func (engine *nativeEngine) tvboxConfigPath() string {
	dir := filepath.Clean(engine.directory)
	if dir == "" || dir == "." {
		return ""
	}
	return filepath.Join(dir, "tvbox-config.json")
}

func (engine *nativeEngine) tvboxEnsureLoaded() {
	tvboxMu.Lock()
	defer tvboxMu.Unlock()
	if tvboxLoaded {
		return
	}
	tvboxLoaded = true

	path := engine.tvboxConfigPath()
	if path == "" {
		return
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return
	}
	var saved tvboxSubscriptionState
	if err := json.Unmarshal(raw, &saved); err != nil {
		return
	}
	saved.RegisteredIDs = registerTVBoxSitesLocked(saved.Sites)
	tvboxState = &saved
}

func makeTVBoxSourceID(site tvbox.Site) string {
	safe := strings.ToLower(tvboxKeySafe.ReplaceAllString(strings.TrimSpace(site.Key), "_"))
	safe = strings.Trim(safe, "_")
	if safe == "" {
		safe = "site"
	}
	return "tvbox_" + safe
}

func registerTVBoxSitesLocked(sites []tvbox.Site) []string {
	if tvboxState != nil {
		for _, oldID := range tvboxState.RegisteredIDs {
			Unregister(oldID)
		}
	}
	registered := make([]string, 0)
	seen := map[string]bool{}
	for _, site := range sites {
		if !site.Supported {
			continue
		}
		id := makeTVBoxSourceID(site)
		if seen[id] {
			continue
		}
		seen[id] = true
		siteCopy := site
		Unregister(id)
		Register(SourceDescriptor{
			ID:             id,
			Name:           siteCopy.Name,
			Description:    "订阅源（" + string(siteCopy.Kind) + "）",
			Group:          "tvbox",
			GroupName:      "饭太硬订阅",
			SkipVIPPrompt:  true,
			NoHostRotation: true,
		}, func(host Host) Provider {
			return &tvboxProvider{id: id, site: siteCopy, host: host}
		})
		registered = append(registered, id)
	}
	return registered
}

func (engine *nativeEngine) tvboxStatus() map[string]any {
	engine.tvboxEnsureLoaded()
	tvboxMu.Lock()
	defer tvboxMu.Unlock()
	if tvboxState == nil || tvboxState.URL == "" {
		return map[string]any{
			"url":            "",
			"supportedCount": 0,
			"skippedCount":   0,
			"sites":          []tvbox.Site{},
		}
	}
	return map[string]any{
		"url":            tvboxState.URL,
		"supportedCount": tvboxState.SupportedCount,
		"skippedCount":   tvboxState.SkippedCount,
		"sites":          tvboxState.Sites,
	}
}

func (engine *nativeEngine) tvboxSubscribe(ctx context.Context, rawURL string) (map[string]any, error) {
	u := strings.TrimSpace(rawURL)
	if u == "" {
		return nil, errors.New("请输入订阅接口地址")
	}
	cfg, err := tvbox.FetchConfig(ctx, engine.downloader.client, u)
	if err != nil {
		return nil, err
	}
	supported := 0
	skipped := 0
	for _, s := range cfg.Sites {
		if s.Supported {
			supported++
		} else {
			skipped++
		}
	}

	tvboxMu.Lock()
	ids := registerTVBoxSitesLocked(cfg.Sites)
	state := &tvboxSubscriptionState{
		URL:            u,
		Sites:          cfg.Sites,
		RegisteredIDs:  ids,
		SupportedCount: supported,
		SkippedCount:   skipped,
	}
	tvboxState = state
	tvboxLoaded = true
	tvboxMu.Unlock()

	if path := engine.tvboxConfigPath(); path != "" {
		if encoded, err := json.MarshalIndent(state, "", "  "); err == nil {
			_ = os.WriteFile(path, encoded, 0o600)
		}
	}
	return engine.tvboxStatus(), nil
}

func (engine *nativeEngine) tvboxClear() (map[string]any, error) {
	tvboxMu.Lock()
	if tvboxState != nil {
		for _, id := range tvboxState.RegisteredIDs {
			Unregister(id)
		}
	}
	tvboxState = nil
	tvboxLoaded = true
	tvboxMu.Unlock()

	if path := engine.tvboxConfigPath(); path != "" {
		_ = os.Remove(path)
	}
	return engine.tvboxStatus(), nil
}
