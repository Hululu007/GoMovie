package core

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"gomovie/native/core/tvbox"
)

func TestTVBoxProviderCatalogSearchAndDetail(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		switch q.Get("ac") {
		case "list":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"class": []map[string]any{
					{"type_id": 1, "type_name": "电影"},
					{"type_id": "2", "type_name": "连续剧"},
				},
			})
		case "detail":
			if q.Get("ids") == "101" {
				_ = json.NewEncoder(w).Encode(map[string]any{
					"list": []map[string]any{
						{
							"vod_id":        "101",
							"vod_name":      "测试电影",
							"vod_play_from": "直连$$$夸克",
							"vod_play_url":  "HD$https://cdn.example.com/1.m3u8$$$4K$https://pan.quark.cn/s/abc123",
						},
					},
				})
				return
			}
			_ = json.NewEncoder(w).Encode(map[string]any{
				"page":      1,
				"pagecount": 2,
				"list": []map[string]any{
					{"vod_id": 101, "vod_name": "测试电影", "vod_remarks": "4K"},
				},
			})
		}
	}))
	defer srv.Close()

	p := &tvboxProvider{
		id:   "tvbox_test",
		site: tvbox.Site{Key: "test", Name: "测试", Type: 1, API: srv.URL, Kind: tvbox.KindCMS, Supported: true},
	}
	ctx := context.Background()

	cats, err := p.Categories(ctx, false)
	if err != nil || len(cats) != 3 {
		t.Fatalf("Categories = %v, err = %v", cats, err)
	}
	items, hasMore, err := p.CatalogPage(ctx, 1, "1")
	if err != nil || !hasMore || len(items) != 1 || items[0].SourceID != "101" {
		t.Fatalf("CatalogPage = %v, hasMore=%v, err=%v", items, hasMore, err)
	}
	searchItems, _, err := p.Search(ctx, 1, "测试")
	if err != nil || len(searchItems) != 1 {
		t.Fatalf("Search = %v, err=%v", searchItems, err)
	}
	drama, chapters, err := p.Detail(ctx, "101")
	if err != nil || drama.Title != "测试电影" || len(chapters) != 2 {
		t.Fatalf("Detail = %+v, chapters=%+v, err=%v", drama, chapters, err)
	}
	media, err := p.ResolveMedia(ctx, Task{Chapter: chapters[0]})
	if err != nil || media.URL != "https://cdn.example.com/1.m3u8" {
		t.Fatalf("ResolveMedia = %+v, err=%v", media, err)
	}
	if _, shareURL, ok := decodeNetdiskVideoRef(chapters[1].VideoURL); !ok || shareURL != "https://pan.quark.cn/s/abc123" {
		t.Fatalf("expected netdisk ref for chapter 1, got %q", chapters[1].VideoURL)
	}
}
