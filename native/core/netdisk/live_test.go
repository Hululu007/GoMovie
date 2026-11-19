package netdisk

import (
	"context"
	"encoding/json"
	"net/http"
	"os"
	"testing"
	"time"
)

// TestLiveQuarkShare 是联网集成测试，默认跳过。
// 运行方式：
//
//	GOMOVIE_NETDISK_LIVE=1 GOMOVIE_COOKIES=/path/web-cookies.json \
//	GOMOVIE_SHARE=https://pan.quark.cn/s/xxxx \
//	go test ./core/netdisk -run TestLiveQuarkShare -v
func TestLiveQuarkShare(t *testing.T) {
	if os.Getenv("GOMOVIE_NETDISK_LIVE") != "1" {
		t.Skip("设置 GOMOVIE_NETDISK_LIVE=1 才会访问真实网盘")
	}
	path := os.Getenv("GOMOVIE_COOKIES")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("读取 cookie 失败: %v", err)
	}
	var jar map[string]string
	if err := json.Unmarshal(raw, &jar); err != nil {
		t.Fatalf("cookie 格式不对: %v", err)
	}
	creds := &Credentials{Provider: "quark", SavedAt: time.Now().Unix()}
	for k, v := range jar {
		creds.Cookies = append(creds.Cookies, Cookie{Name: k, Value: v})
	}
	if !ProviderReady(creds) {
		t.Fatalf("凭据缺少 __puus，无法播放")
	}

	share := os.Getenv("GOMOVIE_SHARE")
	client := NewQuark(creds)
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()

	info, err := client.Share(ctx, share)
	if err != nil {
		t.Fatalf("解析分享失败: %v", err)
	}
	t.Logf("分享 %s：%d 集，第一集 %s", info.ShareID, len(info.Episodes), info.Episodes[0].Name)

	play, err := client.ResolveShare(ctx, share, 0)
	if err != nil {
		t.Fatalf("取播放地址失败: %v", err)
	}
	t.Logf("直链主机 %s", play.URL[:min(60, len(play.URL))])

	req, err := http.NewRequest(http.MethodGet, play.URL, nil)
	if err != nil {
		t.Fatalf("构造请求失败: %v", err)
	}
	for k, v := range play.Headers {
		req.Header.Set(k, v)
	}
	req.Header.Set("Range", "bytes=0-1023")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("拉流失败: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusPartialContent && resp.StatusCode != http.StatusOK {
		t.Fatalf("拉流状态异常: %d", resp.StatusCode)
	}
	if ct := resp.Header.Get("Content-Type"); ct == "" {
		t.Fatalf("缺少 Content-Type")
	} else {
		t.Logf("拉流成功：%d %s", resp.StatusCode, ct)
	}
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
