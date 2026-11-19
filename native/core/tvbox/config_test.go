package tvbox

import (
	"encoding/base64"
	"testing"
)

func TestParseConfigWithCommentsAndClassification(t *testing.T) {
	raw := []byte(`
// 饭太硬测试配置
{
  "spider": "https://example.com/fan.jar;md5;1234",
  "sites": [
    {"key": "cms1", "name": "高清影视", "type": 1, "api": "https://cms.example.com/api.php/provide/vod/", "searchable": 1},
    {"key": "t4_1", "name": "玩偶 T4", "type": 4, "api": "https://t4.example.com/vod", "searchable": 1},
    {"key": "jar1", "name": "传统爬虫", "type": 3, "api": "csp_Fan", "searchable": 1}
  ]
}
`)
	cfg, err := ParseConfig(raw)
	if err != nil {
		t.Fatalf("ParseConfig failed: %v", err)
	}
	if len(cfg.Sites) != 3 {
		t.Fatalf("expected 3 sites, got %d", len(cfg.Sites))
	}
	if !cfg.Sites[0].Supported || cfg.Sites[0].Kind != KindCMS {
		t.Fatalf("site 0 expected supported CMS, got %+v", cfg.Sites[0])
	}
	if !cfg.Sites[1].Supported || cfg.Sites[1].Kind != KindT4 {
		t.Fatalf("site 1 expected supported T4, got %+v", cfg.Sites[1])
	}
	if cfg.Sites[2].Supported || cfg.Sites[2].Kind != KindJar {
		t.Fatalf("site 2 expected unsupported Jar, got %+v", cfg.Sites[2])
	}
}

func TestParseBase64ObfuscatedConfig(t *testing.T) {
	inner := `{"sites":[{"key":"k1","name":"测试源","type":4,"api":"https://t4.example.com/api"}]}`
	encoded := "deadbeef**" + base64.StdEncoding.EncodeToString([]byte(inner))
	cfg, err := ParseConfig([]byte(encoded))
	if err != nil {
		t.Fatalf("ParseConfig base64 failed: %v", err)
	}
	if len(cfg.Sites) != 1 || cfg.Sites[0].Key != "k1" || !cfg.Sites[0].Supported {
		t.Fatalf("unexpected sites: %+v", cfg.Sites)
	}
}
