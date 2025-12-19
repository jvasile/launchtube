package main

import (
	"os"
	"sync"
	"time"
)

type FileCacheEntry struct {
	content string
	mtime   time.Time
}

type FileCache struct {
	mu    sync.RWMutex
	cache map[string]FileCacheEntry
}

func NewFileCache() *FileCache {
	return &FileCache{
		cache: make(map[string]FileCacheEntry),
	}
}

func (fc *FileCache) GetString(path string) (string, time.Time, error) {
	info, err := os.Stat(path)
	if err != nil {
		return "", time.Time{}, err
	}

	mtime := info.ModTime()

	fc.mu.RLock()
	entry, ok := fc.cache[path]
	fc.mu.RUnlock()

	if ok && entry.mtime.Equal(mtime) {
		return entry.content, mtime, nil
	}

	// Read file
	data, err := os.ReadFile(path)
	if err != nil {
		return "", time.Time{}, err
	}

	content := string(data)

	fc.mu.Lock()
	fc.cache[path] = FileCacheEntry{
		content: content,
		mtime:   mtime,
	}
	fc.mu.Unlock()

	return content, mtime, nil
}

func (fc *FileCache) GetMtime(path string) time.Time {
	info, err := os.Stat(path)
	if err != nil {
		return time.Time{}
	}
	return info.ModTime()
}
