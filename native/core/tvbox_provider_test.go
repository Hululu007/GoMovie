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

func TestTVBoxProviderT4FallbacksAndPlayResolve(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		if q.Get("extend") != "ext123" {
			t.Fatalf("expected extend=ext123, got %q", q.Get("extend"))
		}
		switch {
		case q.Get("play") == "ep_token_1":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"url": "https://stream.example.com/live.m3u8",
				"header": map[string]string{
					"User-Agent": "CustomAgent/1.0",
					"Referer":    "https://ref.example.com/",
				},
			})
		case q.Get("ac") == "list":
			_ = json.NewEncoder(w).Encode(map[string]any{})
		case q.Get("ac") == "detail" && q.Get("ids") == "202":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"list": []map[string]any{
					{
						"vod_id":       "202",
						"vod_name":     "T4 影片",
						"vod_score":    8.6,
						"vod_content":  "<p>第一段&nbsp;简介</p><br/>第二段",
						"vod_area":     "中国大陆",
						"vod_year":     "2025",
						"type_name":    "科幻",
						"vod_director": "张三",
						"vod_actor":    "李四,王五",
						"vod_play_from": "T4线路",
						"vod_play_url":  "第1集$ep_token_1",
					},
				},
			})
		case q.Get("ac") == "detail":
			_ = json.NewEncoder(w).Encode(map[string]any{"list": []any{}})
		default:
			_ = json.NewEncoder(w).Encode(map[string]any{
				"class": []map[string]any{{"type_id": "10", "type_name": "热门"}},
				"list":  []map[string]any{{"vod_id": "202", "vod_name": "T4 影片", "vod_score": "8.6"}},
			})
		}
	}))
	defer srv.Close()

	p := &tvboxProvider{
		id:   "tvbox_t4",
		site: tvbox.Site{Key: "t4", Name: "T4测试", Type: 4, API: srv.URL, Ext: "ext123", Kind: tvbox.KindT4, Supported: true},
	}
	ctx := context.Background()

	cats, err := p.Categories(ctx, false)
	if err != nil || len(cats) != 2 || cats[1].ID != "10" {
		t.Fatalf("Categories fallback = %v, err = %v", cats, err)
	}
	items, _, err := p.CatalogPage(ctx, 1, "")
	if err != nil || len(items) != 1 || items[0].Score != "8.6" {
		t.Fatalf("CatalogPage fallback = %+v, err = %v", items, err)
	}
	drama, chapters, err := p.Detail(ctx, "202")
	if err != nil || drama.Score != "8.6" || drama.Desc != "第一段 简介\n第二段" || len(drama.Tags) < 4 || len(chapters) != 1 {
		t.Fatalf("Detail = %+v, chapters = %+v, err = %v", drama, chapters, err)
	}
	media, err := p.ResolveMedia(ctx, Task{Chapter: chapters[0]})
	if err != nil || media.URL != "https://stream.example.com/live.m3u8" || media.Referer != "https://ref.example.com/" || media.Credentials == nil || media.Credentials.UserAgent != "CustomAgent/1.0" {
		t.Fatalf("ResolveMedia = %+v, err = %v", media, err)
	}
}
