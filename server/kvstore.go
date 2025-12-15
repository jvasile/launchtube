package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
)

type KVStore struct {
	mu       sync.RWMutex
	data     map[string]map[string]interface{}
	dirty    bool
	filePath string
}

func NewKVStore() *KVStore {
	home, _ := os.UserHomeDir()
	filePath := filepath.Join(home, ".local", "share", "launchtube", "service_data.json")

	store := &KVStore{
		data:     make(map[string]map[string]interface{}),
		filePath: filePath,
	}

	store.load()
	return store
}

func (s *KVStore) load() {
	data, err := os.ReadFile(s.filePath)
	if err != nil {
		return
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	json.Unmarshal(data, &s.data)
}

func (s *KVStore) save() {
	s.mu.RLock()
	data, err := json.MarshalIndent(s.data, "", "  ")
	s.mu.RUnlock()

	if err != nil {
		return
	}

	os.MkdirAll(filepath.Dir(s.filePath), 0755)
	os.WriteFile(s.filePath, data, 0644)
}

func (s *KVStore) Get(serviceID, key string) (interface{}, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	if svc, ok := s.data[serviceID]; ok {
		val, ok := svc[key]
		return val, ok
	}
	return nil, false
}

func (s *KVStore) GetAll(serviceID string) map[string]interface{} {
	s.mu.RLock()
	defer s.mu.RUnlock()

	if svc, ok := s.data[serviceID]; ok {
		// Return a copy
		result := make(map[string]interface{})
		for k, v := range svc {
			result[k] = v
		}
		return result
	}
	return map[string]interface{}{}
}

func (s *KVStore) Set(serviceID, key string, value interface{}) {
	s.mu.Lock()
	if _, ok := s.data[serviceID]; !ok {
		s.data[serviceID] = make(map[string]interface{})
	}
	s.data[serviceID][key] = value
	s.dirty = true
	s.mu.Unlock()

	s.save()
}

func (s *KVStore) Delete(serviceID, key string) {
	s.mu.Lock()
	if svc, ok := s.data[serviceID]; ok {
		delete(svc, key)
		s.dirty = true
	}
	s.mu.Unlock()

	s.save()
}

func (s *KVStore) DeleteAll(serviceID string) {
	s.mu.Lock()
	delete(s.data, serviceID)
	s.dirty = true
	s.mu.Unlock()

	s.save()
}
