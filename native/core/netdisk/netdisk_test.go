package netdisk

import (
	"testing"
)

func TestExtractAndDetectShareURL(t *testing.T) {
	cases := []struct {
		raw      string
		wantURL  string
		wantProv string
	}{
		{"https://pan.quark.cn/s/abc123def", "https://pan.quark.cn/s/abc123def", "quark"},
		{"push://https://pan.quark.cn/s/abc123def?entry=1", "https://pan.quark.cn/s/abc123def?entry=1", "quark"},
		{"推荐观看 https://drive.uc.cn/s/xyz987 谢谢", "https://drive.uc.cn/s/xyz987", "uc"},
		{"https://www.alipan.com/s/112233", "https://www.alipan.com/s/112233", "alipan"},
		{"https://example.com/video.mp4", "", ""},
	}
	for _, tc := range cases {
		if got := ExtractShareURL(tc.raw); got != tc.wantURL {
			t.Fatalf("ExtractShareURL(%q) = %q, want %q", tc.raw, got, tc.wantURL)
		}
		if got := DetectProvider(tc.raw); got != tc.wantProv {
			t.Fatalf("DetectProvider(%q) = %q, want %q", tc.raw, got, tc.wantProv)
		}
	}
}

func TestStoreRoundTrip(t *testing.T) {
	dir := t.TempDir()
	store := NewStore(dir)
	creds := &Credentials{
		Provider: "quark",
		Cookies: []Cookie{
			{Name: "__puus", Value: "secret-token"},
			{Name: "uid", Value: "12345"},
		},
		SavedAt: 1700000000,
	}
	if err := store.Put(creds); err != nil {
		t.Fatalf("Put failed: %v", err)
	}
	got, err := store.Get("quark")
	if err != nil {
		t.Fatalf("Get failed: %v", err)
	}
	if !ProviderReady(got) {
		t.Fatalf("expected ProviderReady to be true")
	}
	if got.Cookie("uid") != "12345" {
		t.Fatalf("unexpected cookie uid: %q", got.Cookie("uid"))
	}
	if err := store.Clear("quark"); err != nil {
		t.Fatalf("Clear failed: %v", err)
	}
	if _, err := store.Get("quark"); err == nil {
		t.Fatalf("expected error after Clear")
	}
}
