package tvbox

import (
	"context"
	"os"
	"testing"
)

// 联网检查：默认跳过，需要时用
//
//	GOMOVIE_TVBOX_LIVE=1 go test ./core/tvbox -run TestLiveFetchFanTaiYing -v
func TestLiveFetchFanTaiYing(t *testing.T) {
	if os.Getenv("GOMOVIE_TVBOX_LIVE") != "1" {
		t.Skip("设置 GOMOVIE_TVBOX_LIVE=1 才会真正下载订阅")
	}
	u := os.Getenv("GOMOVIE_TVBOX_URL")
	if u == "" {
		u = "https://raw.githubusercontent.com/mrgaoshuiquan/tvbox-config/main/tvbox.json"
	}
	cfg, err := FetchConfig(context.Background(), nil, u)
	if err != nil {
		t.Fatalf("fetch: %v", err)
	}
	sup, skip := 0, 0
	kinds := map[SiteKind]int{}
	for _, s := range cfg.Sites {
		if s.Supported {
			sup++
		} else {
			skip++
		}
		kinds[s.Kind]++
	}
	t.Logf("spider=%q sites=%d supported=%d skipped=%d kinds=%v", cfg.Spider, len(cfg.Sites), sup, skip, kinds)
}
