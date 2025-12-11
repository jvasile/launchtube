// Launch Tube: Jellyfin External Player Integration
// Intercepts video playback and sends it to an external player (mpv)

(function() {
    'use strict';

    // Prevent double-loading
    if (window.__LAUNCHTUBE_JELLYFIN_LOADED__) return;

    const LAUNCH_TUBE_PORT = window.LAUNCH_TUBE_PORT || 8765;
    const LAUNCH_TUBE_URL = `http://localhost:${LAUNCH_TUBE_PORT}`;

    // Version detection bootstrap
    async function detectJellyfinVersion() {
        try {
            // /System/Info/Public doesn't require authentication
            const resp = await fetch(`${location.origin}/System/Info/Public`);
            if (resp.ok) {
                const info = await resp.json();
                return info.Version; // e.g., "10.9.3"
            }
        } catch (e) {
            console.log('Launch Tube: Could not detect Jellyfin version:', e);
        }
        return null;
    }

    async function tryLoadVersionedScript(version) {
        const url = `${LAUNCH_TUBE_URL}/api/1/match?url=${encodeURIComponent(location.href)}&version=${encodeURIComponent(version)}`;
        try {
            const resp = await fetch(url);
            if (resp.ok && resp.status !== 204) {
                const script = await resp.text();
                // Check if we got a different (versioned) script
                if (script && script.includes('__LAUNCHTUBE_JELLYFIN_LOADED__')) {
                    console.log('Launch Tube: Loading versioned script for Jellyfin', version);
                    window.__LAUNCHTUBE_JELLYFIN_LOADED__ = true;
                    const el = document.createElement('script');
                    el.textContent = script;
                    document.head.appendChild(el);
                    return true;
                }
            }
        } catch (e) {
            console.log('Launch Tube: Versioned script request failed:', e);
        }
        return false;
    }

    async function bootstrap() {
        const version = await detectJellyfinVersion();
        console.log('Launch Tube: Detected Jellyfin version:', version);

        if (version) {
            const loaded = await tryLoadVersionedScript(version);
            if (loaded) return; // Versioned script will handle everything
        }

        // Fall through to base implementation
        window.__LAUNCHTUBE_JELLYFIN_LOADED__ = true;
        initJellyfin();
    }

    // Start bootstrap
    bootstrap();

    // Base implementation
    function initJellyfin() {
        console.log('Launch Tube: Jellyfin script loaded');

    // Modal state
    let modalElement = null;
    let statusElement = null;
    let pollInterval = null;

    let dialogObserver = null;

    function showModal(message) {
        if (modalElement) return;

        // Remove any error dialogs and watch for new ones
        const removeDialogs = () => {
            document.querySelectorAll('.dialog, .dialogContainer, .dialogBackdrop, .dialogBackdropOpened').forEach(el => el.remove());
        };
        removeDialogs();
        dialogObserver = new MutationObserver(removeDialogs);
        dialogObserver.observe(document.body, { childList: true, subtree: true });

        modalElement = document.createElement('div');
        modalElement.id = 'launchtube-modal';
        modalElement.innerHTML = `
            <style>
                #launchtube-modal {
                    position: fixed !important;
                    top: 0 !important;
                    left: 0 !important;
                    right: 0 !important;
                    bottom: 0 !important;
                    background: rgba(0, 0, 0, 0.95) !important;
                    z-index: 2147483647 !important;
                    display: flex !important;
                    align-items: center;
                    justify-content: center;
                }
                #launchtube-modal .modal-box {
                    background: #1a1a1a;
                    border: 1px solid #333;
                    border-radius: 8px;
                    padding: 40px 60px;
                    text-align: center;
                    color: #fff;
                    font-family: system-ui, sans-serif;
                    max-width: 500px;
                }
                #launchtube-modal .modal-title {
                    font-size: 24px;
                    margin-bottom: 20px;
                }
                #launchtube-modal .modal-status {
                    font-size: 18px;
                    color: #aaa;
                    margin-bottom: 30px;
                }
                #launchtube-modal .modal-hint {
                    font-size: 13px;
                    color: #666;
                }
                #launchtube-modal .spinner {
                    width: 40px;
                    height: 40px;
                    border: 3px solid #333;
                    border-top-color: #00a4dc;
                    border-radius: 50%;
                    animation: launchtube-spin 1s linear infinite;
                    margin: 0 auto 20px;
                }
                @keyframes launchtube-spin {
                    to { transform: rotate(360deg); }
                }
            </style>
            <div class="modal-box">
                <div class="spinner"></div>
                <div class="modal-title">Playing in External Player</div>
                <div class="modal-status">${message}</div>
                <div class="modal-hint">Press <strong>Escape</strong> to stop playback</div>
            </div>
        `;
        document.body.appendChild(modalElement);
        statusElement = modalElement.querySelector('.modal-status');

        document.addEventListener('keydown', handleModalKeydown, true);
        startStatusPolling();
    }

    function updateModalStatus(message) {
        if (statusElement) {
            statusElement.textContent = message;
        }
    }

    function hideModal(stopPlayer = true) {
        if (pollInterval) {
            clearInterval(pollInterval);
            pollInterval = null;
        }
        if (dialogObserver) {
            dialogObserver.disconnect();
            dialogObserver = null;
        }
        document.removeEventListener('keydown', handleModalKeydown, true);
        if (modalElement) {
            modalElement.remove();
            modalElement = null;
            statusElement = null;
        }
        if (stopPlayer) {
            console.log('Launch Tube: Stopping player...');
            fetch(`${LAUNCH_TUBE_URL}/api/1/player/stop`, { method: 'POST' })
                .then(r => console.log('Launch Tube: Stop response:', r.status))
                .catch(e => console.error('Launch Tube: Stop failed:', e));
        }
    }

    function handleModalKeydown(event) {
        if (event.key === 'Escape') {
            console.log('Launch Tube: Escape pressed during playback, stopping player');
            event.preventDefault();
            event.stopPropagation();
            event.stopImmediatePropagation();
            hideModal(true); // Stop playback
        }
    }

    // Global escape handler for when not playing
    function handleGlobalEscape(event) {
        if (event.key === 'Escape' && !modalElement && !confirmationElement) {
            event.preventDefault();
            event.stopPropagation();
            showExitConfirmation();
        }
    }

    let confirmationElement = null;

    function showExitConfirmation() {
        if (confirmationElement) return;

        confirmationElement = document.createElement('div');
        confirmationElement.id = 'launchtube-confirm';
        confirmationElement.innerHTML = `
            <style>
                #launchtube-confirm {
                    position: fixed !important;
                    top: 0 !important;
                    left: 0 !important;
                    right: 0 !important;
                    bottom: 0 !important;
                    background: rgba(0, 0, 0, 0.8) !important;
                    z-index: 2147483647 !important;
                    display: flex !important;
                    align-items: center;
                    justify-content: center;
                }
                #launchtube-confirm .confirm-box {
                    background: #1a1a1a;
                    border: 1px solid #333;
                    border-radius: 8px;
                    padding: 30px 40px;
                    text-align: center;
                    color: #fff;
                    font-family: system-ui, sans-serif;
                }
                #launchtube-confirm .confirm-title {
                    font-size: 20px;
                    margin-bottom: 25px;
                }
                #launchtube-confirm .confirm-buttons {
                    display: flex;
                    gap: 15px;
                    justify-content: center;
                }
                #launchtube-confirm button {
                    padding: 10px 30px;
                    border: none;
                    border-radius: 4px;
                    font-size: 16px;
                    cursor: pointer;
                    transition: background 0.2s;
                }
                #launchtube-confirm .btn-cancel {
                    background: #333;
                    color: #fff;
                }
                #launchtube-confirm .btn-cancel:hover {
                    background: #444;
                }
                #launchtube-confirm .btn-exit {
                    background: #c62828;
                    color: #fff;
                }
                #launchtube-confirm .btn-exit:hover {
                    background: #d32f2f;
                }
            </style>
            <div class="confirm-box">
                <div class="confirm-title">Exit and return to launcher?</div>
                <div class="confirm-buttons">
                    <button class="btn-cancel">Cancel</button>
                    <button class="btn-exit">Exit</button>
                </div>
            </div>
        `;
        document.body.appendChild(confirmationElement);

        const cancelBtn = confirmationElement.querySelector('.btn-cancel');
        const exitBtn = confirmationElement.querySelector('.btn-exit');

        cancelBtn.addEventListener('click', hideExitConfirmation);
        exitBtn.addEventListener('click', doExit);

        // Also handle keyboard in confirmation dialog
        document.addEventListener('keydown', handleConfirmKeydown, true);
    }

    function hideExitConfirmation() {
        document.removeEventListener('keydown', handleConfirmKeydown, true);
        if (confirmationElement) {
            confirmationElement.remove();
            confirmationElement = null;
        }
    }

    function handleConfirmKeydown(event) {
        if (event.key === 'Escape' || event.key === 'Enter') {
            // Both Escape and Enter confirm exit
            event.preventDefault();
            event.stopPropagation();
            doExit();
        }
    }

    function doExit() {
        console.log('[LaunchTube] doExit called');
        hideExitConfirmation();
        // Call server API to close the browser - window.close() doesn't work due to browser security
        fetch(`${LAUNCH_TUBE_URL}/api/1/browser/close`, { method: 'POST' })
            .then(r => {
                console.log('[LaunchTube] Browser close response:', r.status);
            })
            .catch(e => {
                console.error('[LaunchTube] Browser close failed:', e);
            });
    }

    function startStatusPolling() {
        // Wait a bit before first poll to give mpv time to start
        setTimeout(() => {
            pollInterval = setInterval(async () => {
                try {
                    const response = await fetch(`${LAUNCH_TUBE_URL}/api/1/player/status`);
                    const status = await response.json();
                    console.log('Launch Tube: Poll status:', status);

                if (!status.playing) {
                    console.log('Launch Tube: Player stopped, hiding modal');
                    hideModal(false);
                } else {
                    if (status.position !== undefined && status.duration !== undefined && status.duration > 0) {
                        const posMin = Math.floor(status.position / 60);
                        const posSec = Math.floor(status.position % 60);
                        const durMin = Math.floor(status.duration / 60);
                        const durSec = Math.floor(status.duration % 60);
                        updateModalStatus(`${posMin}:${posSec.toString().padStart(2, '0')} / ${durMin}:${durSec.toString().padStart(2, '0')}`);
                    } else if (status.position !== undefined) {
                        const mins = Math.floor(status.position / 60);
                        const secs = Math.floor(status.position % 60);
                        updateModalStatus(`Playing... ${mins}:${secs.toString().padStart(2, '0')}`);
                    }
                }
            } catch (err) {
                hideModal(false);
            }
        }, 1000);
        }, 2000); // Initial delay before first poll
    }

    // Get Jellyfin auth info from ApiClient
    function getServerInfo() {
        const serverUrl = window.location.origin;
        const userId = window.ApiClient?.getCurrentUserId?.() || '';
        const token = window.ApiClient?.accessToken?.() || '';
        return { serverUrl, userId, token };
    }

    // Get item details from Jellyfin API
    async function getItemDetails(itemId) {
        const { serverUrl, userId, token } = getServerInfo();
        if (!userId || !token) throw new Error('Not authenticated');

        const url = `${serverUrl}/Users/${userId}/Items/${itemId}?api_key=${encodeURIComponent(token)}`;
        const response = await fetch(url);
        if (!response.ok) throw new Error(`API error: ${response.status}`);
        return response.json();
    }

    // Build stream URL for item
    function buildStreamUrl(itemId) {
        const { serverUrl, token } = getServerInfo();
        return `${serverUrl}/Videos/${itemId}/stream?static=true&api_key=${encodeURIComponent(token)}`;
    }

    // Build onComplete callback for an item
    function buildOnComplete(itemId, mediaSourceId) {
        const { serverUrl, token } = getServerInfo();
        const playSessionId = `launchtube-${Date.now()}`;
        return {
            url: `${serverUrl}/Sessions/Playing/Stopped`,
            method: 'POST',
            headers: { 'X-Emby-Token': token },
            bodyTemplate: {
                ItemId: itemId,
                MediaSourceId: mediaSourceId || itemId,
                PositionTicks: '${positionTicks}',
                PlaySessionId: playSessionId,
            },
        };
    }

    // Video types we should play externally
    const VIDEO_TYPES = ['Movie', 'Episode', 'MusicVideo', 'Video', 'Trailer'];
    // Container types that expand into playlists
    const CONTAINER_TYPES = ['Season', 'Series', 'Playlist', 'BoxSet'];

    // Fetch child episodes for a container
    async function getChildEpisodes(itemId) {
        const { serverUrl, userId, token } = getServerInfo();
        if (!userId || !token) throw new Error('Not authenticated');

        let url = `${serverUrl}/Users/${userId}/Items?api_key=${encodeURIComponent(token)}`;
        url += `&ParentId=${encodeURIComponent(itemId)}`;
        url += `&IncludeItemTypes=Episode`;
        url += `&Recursive=true`;
        url += `&SortBy=SortName`;
        url += `&SortOrder=Ascending`;
        url += `&Fields=Path,MediaSources`;

        const response = await fetch(url);
        if (!response.ok) throw new Error(`API error: ${response.status}`);
        const data = await response.json();
        return data.Items || [];
    }

    // Play a playlist of items
    async function playPlaylist(items, startPositionTicks = 0) {
        if (!items || items.length === 0) return false;

        showModal(`Loading playlist (${items.length} items)...`);

        try {
            const playlistItems = items.map(item => ({
                url: buildStreamUrl(item.Id),
                itemId: item.Id,
                onComplete: buildOnComplete(item.Id, item.MediaSources?.[0]?.Id),
            }));

            const startPosition = startPositionTicks / 10000000;

            console.log('Launch Tube: Playing playlist:', playlistItems.length, 'items');

            const response = await fetch(`${LAUNCH_TUBE_URL}/api/1/player/playlist`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ items: playlistItems, startPosition }),
            });

            if (!response.ok) throw new Error(`Player API error: ${response.status}`);
            console.log('Launch Tube: Playlist started');
            updateModalStatus(`Playing 1 of ${items.length}...`);
            return true;
        } catch (e) {
            console.error('Launch Tube: Failed to play playlist:', e);
            updateModalStatus('Failed to start player: ' + e.message);
            setTimeout(() => hideModal(false), 3000);
            return false;
        }
    }

    // Play item(s) in external player - handles single items and containers
    async function playExternal(itemId, startPositionTicks = 0) {
        showModal('Loading...');

        try {
            const item = await getItemDetails(itemId);
            console.log('Launch Tube: Item type:', item.Type, 'Name:', item.Name);

            // Container types - expand to playlist
            if (CONTAINER_TYPES.includes(item.Type)) {
                const episodes = await getChildEpisodes(itemId);
                if (episodes.length > 0) {
                    console.log('Launch Tube: Expanded container to', episodes.length, 'episodes');
                    return await playPlaylist(episodes, startPositionTicks);
                } else {
                    throw new Error('No episodes found');
                }
            }

            // Video types - play single item
            if (VIDEO_TYPES.includes(item.Type)) {
                const streamUrl = buildStreamUrl(itemId);
                const title = item.Name || 'Jellyfin Video';
                const startPosition = startPositionTicks / 10000000;
                const onComplete = buildOnComplete(itemId, item.MediaSources?.[0]?.Id);

                console.log('Launch Tube: Playing single item:', { streamUrl, title, startPosition });

                const response = await fetch(`${LAUNCH_TUBE_URL}/api/1/player/play`, {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ url: streamUrl, title, startPosition, onComplete }),
                });

                if (!response.ok) throw new Error(`Player API error: ${response.status}`);
                console.log('Launch Tube: Player started');
                updateModalStatus('Playing...');
                return true;
            }

            // Unknown type - don't handle
            console.log('Launch Tube: Skipping non-video type:', item.Type);
            hideModal(false);
            return false;
        } catch (e) {
            console.error('Launch Tube: Failed to play externally:', e);
            updateModalStatus('Failed to start player: ' + e.message);
            setTimeout(() => hideModal(false), 3000);
            return false;
        }
    }

    // Extract item ID from element or URL
    function extractItemId(element) {
        // From element's data attributes
        if (element.dataset?.id) return element.dataset.id;

        // From parent with data-id
        let parent = element.closest('[data-id]');
        if (parent?.dataset.id) return parent.dataset.id;

        // From card element
        const card = element.closest('.card');
        if (card) {
            if (card.dataset.id) return card.dataset.id;
            if (card.dataset.itemid) return card.dataset.itemid;

            const inner = card.querySelector('[data-id], [data-itemid]');
            if (inner) return inner.dataset.id || inner.dataset.itemid;

            const img = card.querySelector('img[src*="/Items/"]');
            if (img) {
                const imgMatch = img.src.match(/\/Items\/([0-9a-f]+)\//i);
                if (imgMatch) return imgMatch[1];
            }
        }

        // From action button
        const actionBtn = element.closest('[data-itemid], [data-id]');
        if (actionBtn) return actionBtn.dataset.itemid || actionBtn.dataset.id;

        // From URL hash
        const urlMatch = window.location.hash.match(/id=([0-9a-f]+)/i);
        if (urlMatch) return urlMatch[1];

        // From element href
        if (element.href) {
            const hrefMatch = element.href.match(/id=([0-9a-f]+)/i);
            if (hrefMatch) return hrefMatch[1];
        }

        return null;
    }

    // Store the last clicked item ID for video.play() intercept
    let lastClickedItemId = null;

    // Intercept clicks on play buttons
    // Intercept clicks on play buttons and directly start external playback
    function attachPlayListeners() {
        const playSelectors = [
            '.btnPlay',
            '.btnReplay',
            '.btnResume',
            '.playButton',
            'button[data-action="play"]',
            '[data-action="resume"]',
            '.detailButton-primary',
            '.cardOverlayPlayButton',
            '.itemAction[data-action="play"]'
        ];

        document.addEventListener('click', async function(event) {
            const target = event.target.closest(playSelectors.join(','));
            if (target) {
                const itemId = extractItemId(target);
                if (itemId) {
                    console.log('Launch Tube: Play button clicked, itemId:', itemId);
                    // Prevent Jellyfin from starting its player
                    event.preventDefault();
                    event.stopPropagation();
                    event.stopImmediatePropagation();
                    // Get item details to check for resume position
                    try {
                        const item = await getItemDetails(itemId);
                        const startPositionTicks = item.UserData?.PlaybackPositionTicks || 0;
                        console.log('Launch Tube: Resume position:', startPositionTicks);
                        await playExternal(itemId, startPositionTicks);
                    } catch (err) {
                        console.error('Launch Tube: Failed to get item details, starting from beginning:', err);
                        playExternal(itemId, 0);
                    }
                }
            }
        }, true);
    }

    // Intercept video playback by overriding HTMLVideoElement.play
    function interceptVideoPlayback() {
        // Listen for intercept messages from injected script
        window.addEventListener('message', async function(e) {
            if (e.data?.type === 'launchtube-intercept') {
                const { itemId } = e.data;
                console.log('Launch Tube: Handling video intercept, itemId:', itemId);

                // Hide Jellyfin's video player UI
                document.querySelectorAll('.videoPlayerContainer, .videoOsdBottom, .videoOsd').forEach(el => {
                    el.style.display = 'none';
                });

                if (itemId) {
                    try {
                        const item = await getItemDetails(itemId);
                        const startPositionTicks = item.UserData?.PlaybackPositionTicks || 0;
                        await playExternal(itemId, startPositionTicks);
                    } catch (err) {
                        console.error('Launch Tube: Error:', err);
                    }
                }
            }
        });

        // Inject script to always block HTMLVideoElement.play - we always use external player
        const script = document.createElement('script');
        script.textContent = `
        (function() {
            const originalPlay = HTMLVideoElement.prototype.play;

            HTMLVideoElement.prototype.play = function() {
                const src = this.src || '';
                console.log('Launch Tube: Blocking video.play(), src:', src);
                this.pause();
                this.src = '';
                return Promise.reject(new Error('Blocked by Launch Tube - use external player'));
            };

            console.log('Launch Tube: Installed video.play() blocker');
        })();
        `;
        document.documentElement.appendChild(script);
        script.remove();
    }

    // Hide menu items that don't work with external player
    function hidePlayMenuItems() {
        const style = document.createElement('style');
        style.textContent = `
            /* Hide play options in context menus that don't trigger external player */
            .actionSheetMenuItem[data-id="play"],
            .actionSheetMenuItem[data-id="playallfromhere"],
            .actionSheetMenuItem[data-id="queue"],
            .actionSheetMenuItem[data-id="queuenext"],
            .listItem[data-action="play"],
            .listItem[data-action="playallfromhere"],
            /* Hide menu items with play icon */
            .actionSheetMenuItem:has(.play_arrow),
            .listItem:has(.play_arrow) {
                display: none !important;
            }
        `;
        document.head.appendChild(style);
    }

    // Hook PlaybackManager.play to intercept before Jellyfin starts loading
    function hookPlaybackManager() {
        const script = document.createElement('script');
        script.textContent = `
        (function() {
            let hooked = false;

            function doHook(playbackManager) {
                if (hooked) return;
                const originalPlay = playbackManager.play.bind(playbackManager);
                playbackManager.play = async function(options) {
                    console.log('Launch Tube: Intercepted PlaybackManager.play', options);

                    let itemId = null;
                    if (options && options.ids && options.ids.length > 0) {
                        itemId = options.ids[0];
                    } else if (options && options.items && options.items.length > 0) {
                        itemId = options.items[0].Id;
                    }

                    if (itemId) {
                        const startPositionTicks = options && options.startPositionTicks ? options.startPositionTicks : 0;
                        window.postMessage({
                            type: 'launchtube-playback-manager',
                            itemId: itemId,
                            startPositionTicks: startPositionTicks
                        }, '*');
                        return; // Don't call original - prevents spinner
                    }

                    return originalPlay(options);
                };
                hooked = true;
                console.log('Launch Tube: Hooked PlaybackManager.play');
            }

            function tryHook() {
                if (window.PlaybackManager && window.PlaybackManager.play && !hooked) {
                    doHook(window.PlaybackManager);
                    return true;
                }
                return false;
            }

            if (!tryHook()) {
                // Install trap to catch when PlaybackManager is set
                if (typeof window.PlaybackManager === 'undefined' || window.PlaybackManager === null) {
                    let _pm = undefined;
                    Object.defineProperty(window, 'PlaybackManager', {
                        get: function() { return _pm; },
                        set: function(val) {
                            _pm = val;
                            if (val && val.play) doHook(val);
                        },
                        configurable: true
                    });
                }

                // Also poll as fallback
                let attempts = 0;
                const interval = setInterval(() => {
                    if (tryHook() || ++attempts > 60) {
                        clearInterval(interval);
                    }
                }, 500);
            }
        })();
        `;
        document.documentElement.appendChild(script);
        script.remove();

        // Listen for PlaybackManager intercepts
        window.addEventListener('message', async function(e) {
            if (e.data?.type === 'launchtube-playback-manager') {
                const { itemId, startPositionTicks } = e.data;
                console.log('Launch Tube: PlaybackManager intercept, itemId:', itemId);
                await playExternal(itemId, startPositionTicks);
            }
        });
    }

    // Initialize
    function init() {
        console.log('Launch Tube: Initializing Jellyfin integration');
        hidePlayMenuItems();
        hookPlaybackManager();
        attachPlayListeners();
        interceptVideoPlayback();
        // Global escape to exit when not playing
        document.addEventListener('keydown', handleGlobalEscape, true);
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        setTimeout(init, 500);
    }
    } // end initJellyfin()
})();
