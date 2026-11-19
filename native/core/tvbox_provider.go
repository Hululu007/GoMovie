package core

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"

	"gomovie/native/core/netdisk"
	"gomovie/native/core/tvbox"
)

type tvboxProvider struct {
	id   string
	site tvbox.Site
	host Host
}

func (p *tvboxProvider) Descriptor() SourceDescriptor {
	desc, _ := registeredDescriptor(p.id)
	return desc
}

func (p *tvboxProvider) client() *http.Client {
	if p.host != nil && p.host.Client() != nil {
		return p.host.Client()
	}
	return http.DefaultClient
}

func (p *tvboxProvider) getJSON(ctx context.Context, rawURL string, out any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		return err
	}
	req.Header.Set("User-Agent", "okhttp/3.15")
	resp, err := p.client().Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("站源返回 HTTP %d", resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return err
	}
	return json.Unmarshal(body, out)
}

func (p *tvboxProvider) buildAPIURL(params url.Values) (string, error) {
	u, err := url.Parse(strings.TrimSpace(p.site.API))
	if err != nil {
		return "", err
	}
	q := u.Query()
	for k, vals := range params {
		for _, v := range vals {
			q.Set(k, v)
		}
	}
	u.RawQuery = q.Encode()
	return u.String(), nil
}

type tvboxVodItem struct {
	ID          any    `json:"vod_id"`
	Name        string `json:"vod_name"`
	Pic         string `json:"vod_pic"`
	Remarks     string `json:"vod_remarks"`
	TypeName    string `json:"type_name"`
	Content     string `json:"vod_content"`
	Year        string `json:"vod_year"`
	Area        string `json:"vod_area"`
	PlayFrom    string `json:"vod_play_from"`
	PlayURL     string `json:"vod_play_url"`
	VodDirector string `json:"vod_director"`
	VodActor    string `json:"vod_actor"`
}

type tvboxResponse struct {
	Code      any `json:"code"`
	Page      any `json:"page"`
	PageCount any `json:"pagecount"`
	Class     []struct {
		TypeID   any    `json:"type_id"`
		TypeName string `json:"type_name"`
	} `json:"class"`
	List []tvboxVodItem `json:"list"`
}

func anyToString(v any) string {
	switch val := v.(type) {
	case string:
		return strings.TrimSpace(val)
	case float64:
		return strconv.FormatInt(int64(val), 10)
	case int:
		return strconv.Itoa(val)
	case int64:
		return strconv.FormatInt(val, 10)
	default:
		return ""
	}
}

func anyToInt(v any) int {
	switch val := v.(type) {
	case float64:
		return int(val)
	case int:
		return val
	case int64:
		return int(val)
	case string:
		n, _ := strconv.Atoi(strings.TrimSpace(val))
		return n
	default:
		return 0
	}
}

func (p *tvboxProvider) Categories(ctx context.Context, _ bool) ([]Category, error) {
	q := url.Values{"ac": {"list"}}
	u, err := p.buildAPIURL(q)
	if err != nil {
		return nil, err
	}
	var resp tvboxResponse
	if err := p.getJSON(ctx, u, &resp); err != nil {
		return nil, err
	}
	cats := []Category{{ID: "", Name: "全部"}}
	seen := map[string]bool{"": true}
	for _, c := range resp.Class {
		id := anyToString(c.TypeID)
		name := strings.TrimSpace(c.TypeName)
		if id == "" || name == "" || seen[id] {
			continue
		}
		seen[id] = true
		cats = append(cats, Category{ID: id, Name: name})
	}
	return cats, nil
}

func (p *tvboxProvider) toDramas(items []tvboxVodItem) []Drama {
	out := make([]Drama, 0, len(items))
	for _, item := range items {
		vodID := anyToString(item.ID)
		if vodID == "" {
			continue
		}
		badge := strings.TrimSpace(item.Remarks)
		out = append(out, Drama{
			ID:         p.id + ":" + vodID,
			Source:     p.id,
			SourceID:   vodID,
			Title:      strings.TrimSpace(item.Name),
			Cover:      strings.TrimSpace(item.Pic),
			Desc:       strings.TrimSpace(item.Content),
			Category:   strings.TrimSpace(item.TypeName),
			Badge:      badge,
			OnlineDate: strings.TrimSpace(item.Year),
		})
	}
	return out
}

func (p *tvboxProvider) CatalogPage(ctx context.Context, page int, category string) ([]Drama, bool, error) {
	if page < 1 {
		page = 1
	}
	q := url.Values{
		"ac": {"detail"},
		"pg": {strconv.Itoa(page)},
	}
	if strings.TrimSpace(category) != "" && category != "all" {
		q.Set("t", category)
	}
	u, err := p.buildAPIURL(q)
	if err != nil {
		return nil, false, err
	}
	var resp tvboxResponse
	if err := p.getJSON(ctx, u, &resp); err != nil {
		return nil, false, err
	}
	dramas := p.toDramas(resp.List)
	pageCount := anyToInt(resp.PageCount)
	hasMore := pageCount > page || (pageCount == 0 && len(dramas) >= 20)
	return dramas, hasMore, nil
}

func (p *tvboxProvider) Search(ctx context.Context, page int, query string) ([]Drama, bool, error) {
	if page < 1 {
		page = 1
	}
	q := url.Values{
		"ac": {"detail"},
		"wd": {strings.TrimSpace(query)},
		"pg": {strconv.Itoa(page)},
	}
	u, err := p.buildAPIURL(q)
	if err != nil {
		return nil, false, err
	}
	var resp tvboxResponse
	if err := p.getJSON(ctx, u, &resp); err != nil {
		return nil, false, err
	}
	dramas := p.toDramas(resp.List)
	pageCount := anyToInt(resp.PageCount)
	hasMore := pageCount > page
	return dramas, hasMore, nil
}

func (p *tvboxProvider) Detail(ctx context.Context, sourceID string) (Drama, []Chapter, error) {
	q := url.Values{
		"ac":  {"detail"},
		"ids": {strings.TrimSpace(sourceID)},
	}
	u, err := p.buildAPIURL(q)
	if err != nil {
		return Drama{}, nil, err
	}
	var resp tvboxResponse
	if err := p.getJSON(ctx, u, &resp); err != nil {
		return Drama{}, nil, err
	}
	if len(resp.List) == 0 {
		return Drama{}, nil, errors.New("未找到影片详情")
	}
	item := resp.List[0]
	drama := Drama{
		ID:         p.id + ":" + sourceID,
		Source:     p.id,
		SourceID:   sourceID,
		Title:      strings.TrimSpace(item.Name),
		Cover:      strings.TrimSpace(item.Pic),
		Desc:       strings.TrimSpace(item.Content),
		Category:   strings.TrimSpace(item.TypeName),
		Badge:      strings.TrimSpace(item.Remarks),
		OnlineDate: strings.TrimSpace(item.Year),
	}

	routes := strings.Split(item.PlayFrom, "$$$")
	urlGroups := strings.Split(item.PlayURL, "$$$")
	chapters := make([]Chapter, 0)
	epIndex := 0

	for rIdx, group := range urlGroups {
		routeName := ""
		if rIdx < len(routes) {
			routeName = strings.TrimSpace(routes[rIdx])
		}
		entries := strings.Split(group, "#")
		// 如果某条线路只给了一个夸克分享链接，自动展开分享文件夹里的全部剧集。
		if len(entries) == 1 {
			_, rawLink := parseEpisodeEntry(entries[0], "正片")
			if shareURL := netdisk.ExtractShareURL(rawLink); shareURL != "" && netdisk.DetectProvider(shareURL) == "quark" {
				if expanded, ok := p.expandQuarkShare(ctx, drama.ID, routeName, shareURL, &epIndex); ok {
					chapters = append(chapters, expanded...)
					continue
				}
			}
		}

		for _, entry := range entries {
			epName, rawLink := parseEpisodeEntry(entry, fmt.Sprintf("第 %d 集", epIndex+1))
			if rawLink == "" {
				continue
			}
			if routeName != "" && len(urlGroups) > 1 {
				epName = routeName + " · " + epName
			}
			videoRef := rawLink
			if shareURL := netdisk.ExtractShareURL(rawLink); shareURL != "" {
				videoRef = encodeNetdiskVideoRef(0, shareURL)
			}
			epIndex++
			epNum, _ := json.Marshal(epIndex)
			chapters = append(chapters, Chapter{
				ID:             fmt.Sprintf("%s#%d", drama.ID, epIndex),
				Source:         p.id,
				Title:          epName,
				VideoURL:       videoRef,
				CurrentEpisode: epNum,
			})
		}
	}
	return drama, chapters, nil
}

func (p *tvboxProvider) expandQuarkShare(ctx context.Context, dramaID, routeName, shareURL string, epIndex *int) ([]Chapter, bool) {
	netdiskMu.Lock()
	rt := netdiskRT
	netdiskMu.Unlock()
	var creds *netdisk.Credentials
	if rt != nil && rt.store != nil {
		creds, _ = rt.store.Get("quark")
	}
	info, err := netdisk.NewQuark(creds).Share(ctx, shareURL)
	if err != nil || len(info.Episodes) == 0 {
		return nil, false
	}
	out := make([]Chapter, 0, len(info.Episodes))
	for i, ep := range info.Episodes {
		*epIndex++
		title := ep.Name
		if sizeText := formatNetdiskSize(ep.Size); sizeText != "" {
			title += " · " + sizeText
		}
		if routeName != "" {
			title = routeName + " · " + title
		}
		epNum, _ := json.Marshal(*epIndex)
		out = append(out, Chapter{
			ID:             fmt.Sprintf("%s#%d", dramaID, *epIndex),
			Source:         p.id,
			Title:          title,
			VideoURL:       encodeNetdiskVideoRef(i, shareURL),
			CurrentEpisode: epNum,
			MediaSize:      ep.Size,
		})
	}
	return out, true
}

func parseEpisodeEntry(entry, fallbackName string) (string, string) {
	trimmed := strings.TrimSpace(entry)
	if trimmed == "" {
		return "", ""
	}
	if name, link, ok := strings.Cut(trimmed, "$"); ok {
		name = strings.TrimSpace(name)
		link = strings.TrimSpace(link)
		if name == "" {
			name = fallbackName
		}
		return name, link
	}
	return fallbackName, trimmed
}

func (p *tvboxProvider) ResolveMedia(ctx context.Context, task Task) (ProviderMedia, error) {
	raw := strings.TrimSpace(task.Chapter.VideoURL)
	if raw == "" {
		return ProviderMedia{}, errors.New("该集缺少播放地址")
	}
	if _, _, isNetdisk := decodeNetdiskVideoRef(raw); isNetdisk {
		return resolveNetdiskMedia(ctx, raw)
	}
	return ProviderMedia{
		URL:     raw,
		Referer: p.site.API,
	}, nil
}
