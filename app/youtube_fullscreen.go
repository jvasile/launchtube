package main

import (
	"encoding/json"
	"net/http"
)

// handleYouTubeFullscreen handles requests to fullscreen YouTube video via CDP
func (s *Server) handleYouTubeFullscreen(w http.ResponseWriter, r *http.Request) {
	Log("YouTube fullscreen API called: method=%s", r.Method)

	if r.Method != "POST" {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Access-Control-Allow-Origin", "*")

	// Try to fullscreen via JS - find the button and click it
	Log("YouTube fullscreen: attempting via JS...")
	err := s.browserMgr.EvalJS("youtube.com", `(function() {
		var info = {};
		info.url = location.href;
		info.player = !!document.querySelector('#movie_player');
		info.video = !!document.querySelector('video');
		info.fsBtn = !!document.querySelector('.ytp-fullscreen-button');
		info.controls = !!document.querySelector('.ytp-chrome-bottom');

		var btn = document.querySelector('.ytp-fullscreen-button');
		if (btn) {
			btn.click();
			info.action = 'clicked';
			return JSON.stringify(info);
		}
		var player = document.querySelector('#movie_player');
		if (player) {
			player.focus();
			var ev = new KeyboardEvent('keydown', {key: 'f', code: 'KeyF', keyCode: 70, bubbles: true});
			player.dispatchEvent(ev);
			info.action = 'key_dispatched';
			return JSON.stringify(info);
		}
		info.action = 'nothing_found';
		return JSON.stringify(info);
	})()`)
	if err != nil {
		Log("YouTube fullscreen failed: %v", err)
		json.NewEncoder(w).Encode(map[string]interface{}{
			"success": false,
			"error":   err.Error(),
		})
		return
	}

	Log("YouTube fullscreen succeeded")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"success": true,
	})
}
