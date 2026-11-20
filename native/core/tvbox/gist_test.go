package tvbox

import (
	"context"
	"os"
	"testing"
)

func TestGistConfig(t *testing.T) {
	u := os.Getenv("URL")
	cfg, err := FetchConfig(context.Background(), nil, u)
	if err != nil {
		t.Fatalf("fetch: %v", err)
	}
	sup, skip := 0, 0
	for _, s := range cfg.Sites {
		if s.Supported {
			sup++
		} else {
			skip++
		}
	}
	t.Logf("spider=%.60s sites=%d supported=%d skipped=%d", cfg.Spider, len(cfg.Sites), sup, skip)
}
