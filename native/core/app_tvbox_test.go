package core

import (
	"testing"

	"gomovie/native/core/tvbox"
)

// 饭太硬的站点 key 大量是中文，ID 生成必须保证每个站点唯一，
// 否则会在注册去重时被合并成同一个源。
func TestMakeTVBoxSourceIDUnique(t *testing.T) {
	keys := []string{
		"点我切源", "玩偶", "爱刷", "seed", "MDrive", "YGP", "A-B", "A_B", "", "测试源",
	}
	seen := map[string]string{}
	for _, key := range keys {
		id := makeTVBoxSourceID(tvbox.Site{Key: key})
		if id == "tvbox_" {
			t.Fatalf("key %q 生成了空 ID", key)
		}
		if prev, ok := seen[id]; ok {
			t.Fatalf("key %q 与 %q 撞了同一个 ID: %s", key, prev, id)
		}
		seen[id] = key
	}
}
