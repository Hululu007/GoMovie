package core

import (
	"context"
	"errors"
	"sort"
	"strings"
)

type Category struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

func nativeCatalogKey(source, category string) string {
	source = canonicalProviderSource(source)
	if category = strings.TrimSpace(category); category != "" {
		return source + "|" + category
	}
	return source
}

// nativeExtendSignature 把二级筛选值拼成稳定的缓存键片段（键排序，避免顺序不同算两次）。
func nativeExtendSignature(extend map[string]string) string {
	if len(extend) == 0 {
		return ""
	}
	keys := make([]string, 0, len(extend))
	for key, value := range extend {
		if strings.TrimSpace(value) == "" {
			continue
		}
		keys = append(keys, key)
	}
	if len(keys) == 0 {
		return ""
	}
	sort.Strings(keys)
	var b strings.Builder
	for _, key := range keys {
		b.WriteString("&")
		b.WriteString(key)
		b.WriteString("=")
		b.WriteString(extend[key])
	}
	return b.String()
}

func ValidNativeCategory(source, category string) bool {
	if category == "" {
		return true
	}
	if len(category) > 128 || strings.ContainsAny(category, "|/\\\x00\r\n") {
		return false
	}
	if descriptor, ok := registeredDescriptor(source); ok {
		// TVBox / 订阅类站源的分类是运行时从 spider 拿的（热播电影、动作片…），
		// 没有静态清单可校验，交给 provider 自己判断，否则一律被判"内容分类无效"。
		if descriptor.ValidCategory == nil {
			return true
		}
		return descriptor.ValidCategory(category)
	}
	return false
}

// nativeFilters 返回某站源每个分类的二级筛选项（TVBox filters）。
// 不支持的站源返回空表，前端自然不显示筛选条。
func (engine *nativeEngine) nativeFilters(ctx context.Context, source string) (map[string][]CategoryFilter, error) {
	source = canonicalProviderSource(source)
	empty := map[string][]CategoryFilter{}
	p, ok := engine.downloader.provider(source)
	if !ok {
		return empty, errors.New("请选择有效站源")
	}
	filtered, ok := providerAs[FilterCataloger](p)
	if !ok {
		return empty, nil
	}
	filters, err := filtered.CategoryFilters(ctx)
	if err != nil {
		return empty, err
	}
	if filters == nil {
		return empty, nil
	}
	return filters, nil
}

func (engine *nativeEngine) nativeCategories(ctx context.Context, source string, force bool) ([]Category, error) {
	source = canonicalProviderSource(source)
	all := []Category{{Name: "全部"}}
	p, ok := engine.downloader.provider(source)
	if !ok {
		return nil, errors.New("请选择有效站源")
	}
	version := providerModuleVersion(p)
	engine.mu.Lock()
	cached := append([]Category{}, engine.categoryOptions[source]...)
	current := engine.categoryVersions[source] == version
	engine.mu.Unlock()
	if len(cached) > 1 && current && !force {
		return cached, nil
	}
	categories, err := p.Categories(ctx, force)
	all = append(all, categories...)
	if errors.Is(err, ErrCategoriesIncomplete) {
		return all, nil
	}
	if err != nil {
		return nil, err
	}
	if len(all) == 1 {
		return nil, errors.New("站源暂未返回内容分类，请稍后重试")
	}
	engine.rememberCategories(source, version, all)
	return all, nil
}

func (engine *nativeEngine) rememberCategories(source, version string, all []Category) {
	engine.mu.Lock()
	defer engine.mu.Unlock()
	if engine.categoryOptions == nil {
		engine.categoryOptions = map[string][]Category{}
	}
	if engine.categoryVersions == nil {
		engine.categoryVersions = map[string]string{}
	}
	engine.categoryOptions[source] = all
	engine.categoryVersions[source] = version
	engine.writeCatalogDiskLocked()
}

func providerModuleVersion(p Provider) string {
	if module, ok := p.(*jsProvider); ok {
		return module.module.manifest.Version
	}
	return ""
}
