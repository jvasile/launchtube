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

    // Send log to server for debugging
    function serverLog(message, level = 'info') {
        console.log(`[LaunchTube] ${message}`);
        if (typeof window.launchTubeLog === 'function') {
            window.launchTubeLog(message, level);
        }
    }

    // Base implementation
    function initJellyfin() {
        serverLog('Jellyfin script loaded');

    // Modal state
    let modalElement = null;
    let statusElement = null;
    let pollInterval = null;
    let dialogObserver = null;

    // Navigation state (used by escape handler and nav code)
    let ignoreMouseUntil = 0;

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
            // Check if any menu, dialog, or dropdown is open - let Jellyfin handle closing it
            const openMenu = document.querySelector('.actionSheet, .dialogContainer:not(.hide), .mainDrawer.mainDrawer-visible, .actionSheetContent, .dialogOpened, .menuOpen');
            if (openMenu) {
                serverLog('Escape with open menu, letting Jellyfin close it');
                // Don't prevent default - let Jellyfin's own escape handler close the menu
                return;
            }

            event.preventDefault();
            event.stopPropagation();

            // Check if we're on a detail page or dashboard - go back instead of exit
            const isDetailPage = document.querySelector('.detailPageContent, .itemDetailPage, [data-type="Program"]') ||
                                 window.location.hash.includes('id=');
            const isDashboard = window.location.hash.includes('/dashboard') ||
                               window.location.hash.includes('/configurationpage');
            if (isDetailPage || isDashboard) {
                serverLog(`Escape on ${isDashboard ? 'dashboard' : 'detail page'}, going back`);
                ignoreMouseUntil = Date.now() + 1000;
                history.back();
                return;
            }

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

        // Click outside dialog to dismiss
        confirmationElement.addEventListener('click', (e) => {
            if (e.target === confirmationElement) {
                hideExitConfirmation();
            }
        });

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

    // Parse timestamp from chapter card text (e.g., "Speed Limits7:27" or "Suicide?1:00:26")
    function parseChapterTimestamp(text) {
        // Match timestamp at end: H:MM:SS or M:SS or MM:SS
        const match = text.match(/(\d{1,2}):(\d{2}):(\d{2})$|(\d{1,2}):(\d{2})$/);
        if (!match) return 0;

        let seconds = 0;
        if (match[1] !== undefined) {
            // H:MM:SS format
            seconds = parseInt(match[1]) * 3600 + parseInt(match[2]) * 60 + parseInt(match[3]);
        } else {
            // M:SS format
            seconds = parseInt(match[4]) * 60 + parseInt(match[5]);
        }
        // Convert to ticks (1 second = 10,000,000 ticks)
        return seconds * 10000000;
    }

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
            // Check for chapter card click first
            const chapterCard = event.target.closest('.chapterCard');
            if (chapterCard) {
                const itemId = extractItemId(chapterCard);
                if (itemId) {
                    console.log('Launch Tube: Chapter card clicked, itemId:', itemId);
                    event.preventDefault();
                    event.stopPropagation();
                    event.stopImmediatePropagation();

                    const text = chapterCard.textContent || '';
                    const startPositionTicks = parseChapterTimestamp(text);
                    console.log('Launch Tube: Chapter timestamp:', text, '-> ticks:', startPositionTicks);
                    await playExternal(itemId, startPositionTicks);
                    return;
                }
            }

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

    // === Keyboard Navigation ===
    // Unified navigation across all interactive elements (cards, buttons, etc.)
    let selectedElement = null;
    let pendingEnter = false; // For double-enter detection on cards
    let mouseHasMoved = false; // Only respond to mouse after it actually moves

    // Add highlight style
    const navStyle = document.createElement('style');
    navStyle.textContent = `
        /* Main page cards - inset shadow on image container */
        .launchtube-selected .cardImageContainer {
            box-shadow: inset 0 0 0 0.25vw #ffeb3b, inset 0 0 0 0.45vw #000 !important;
        }
        /* Card text - dark text on bright yellow background when selected */
        .launchtube-selected .cardText,
        .launchtube-selected .cardTextCentered {
            background-color: #ffeb3b !important;
            color: #000 !important;
            font-weight: bold !important;
        }
        /* Dashboard cards (inside MUI drawer layout) - outer shadow since cardImageContainer doesn't work well */
        .MuiBox-root .launchtube-selected.card {
            box-shadow: 0 0 0 0.3vw #ffeb3b, 0 0 0 0.5vw #000 !important;
        }
        .launchtube-nav-highlight {
            box-shadow: inset 0 0 0 4px #ffeb3b !important;
            background-color: rgba(255, 235, 59, 0.3) !important;
        }
        .alphaPickerButton.launchtube-nav-highlight {
            background-color: #ffeb3b !important;
            color: #000 !important;
        }
        /* Disable hover when mouse is idle (prevents scroll-under hover) */
        body.launchtube-mouse-idle .card {
            pointer-events: none !important;
        }
    `;
    document.head.appendChild(navStyle);

    // Track mouse idle state to prevent hover when scrolling under stationary mouse
    let mouseIdleTimer = null;
    function setMouseIdle() {
        document.body.classList.add('launchtube-mouse-idle');
    }
    function setMouseActive() {
        document.body.classList.remove('launchtube-mouse-idle');
        clearTimeout(mouseIdleTimer);
        // Go idle after mouse stops moving for 500ms
        mouseIdleTimer = setTimeout(setMouseIdle, 500);
    }
    document.addEventListener('mousemove', setMouseActive);
    // Start in idle state
    setMouseIdle();

    // Get all navigable elements - navbar, cards, and action buttons
    function getNavigableElements(includeBelow = false) {
        const elements = [];
        const seen = new Set(); // Avoid duplicates

        // Navbar buttons and tabs (require minimum size and visibility)
        // Also check for MUI IconButtons anywhere and buttons with back/arrow icons
        document.querySelectorAll('.headerBackButton, .headerHomeButton, .mainDrawerButton, .headerSyncButton, .headerCastButton, .headerSearchButton, .headerUserButton, .emby-tab-button, .MuiIconButton-root, [class*="BackButton"], [aria-label*="back" i]').forEach(nav => {
            let rect = nav.getBoundingClientRect();
            // Some buttons (like back) have 0 size but contain an icon with size
            if (rect.width < 20 || rect.height < 20) {
                const icon = nav.querySelector('span, i, svg, .material-icons, [class*="Icon"]');
                if (icon) {
                    rect = icon.getBoundingClientRect();
                }
            }
            // Debug MUI buttons
            if (nav.classList.contains('MuiIconButton-root')) {
                serverLog(`MuiIconButton: ${rect.width}x${rect.height} top=${rect.top} aria="${nav.getAttribute('aria-label')}"`);
            }
            if (rect.width < 20 || rect.height < 20) return; // Skip tiny elements
            const style = window.getComputedStyle(nav);
            if (style.opacity === '0' || style.visibility === 'hidden' || style.display === 'none') return;
            // Skip active tab (current page)
            if (nav.classList.contains('emby-tab-button-active')) return;
            if (seen.has(nav)) return;
            seen.add(nav);
            elements.push({ el: nav, rect, type: 'nav' });
        });

        // =========================================================================
        // MENU ITEMS - Settings pages, dashboard sidebar, profile dropdown
        // =========================================================================
        // CRITICAL: Skip items inside .mainDrawer (the hamburger menu sidebar)
        // The drawer is present on ALL pages but hidden off-screen when closed.
        // Drawer items still have non-zero bounding rects even when "closed".
        // If we include drawer items, pressing UP from the first card will
        // navigate to invisible drawer items instead of staying on the card.
        //
        // On dashboard SUBPAGES (like /dashboard/settings), we exclude the sidebar
        // entirely so navigation stays in the content area. User can:
        //   - Press Escape to go back
        //   - Press Left from content to return to sidebar
        // Jellyfin 10.9+ uses Material UI (.MuiListItemButton-root) for dashboard.
        // =========================================================================
        const isDashboardSubpage = window.location.hash.includes('/dashboard/') ||
                                   window.location.hash.includes('/configurationpage?');
        // On subpages, skip MUI sidebar items UNLESS we're currently on a sidebar item
        // (need to be able to navigate within sidebar after pressing Left to get there)
        const currentlyOnSidebar = selectedElement && selectedElement.classList.contains('MuiListItemButton-root');
        const menuSelector = (isDashboardSubpage && !currentlyOnSidebar)
            ? 'a.listItem-border.emby-button:not(.hide), .navMenuOption, .sidebarLink, .listItem-button'
            : '.MuiListItemButton-root, a.listItem-border.emby-button:not(.hide), .navMenuOption, .sidebarLink, .listItem-button';
        document.querySelectorAll(menuSelector).forEach(item => {
            if (item.closest('.mainDrawer')) return; // SKIP - drawer is off-screen when closed
            const rect = item.getBoundingClientRect();
            if (rect.width < 20 || rect.height < 20) return;
            const style = window.getComputedStyle(item);
            if (style.opacity === '0' || style.visibility === 'hidden' || style.display === 'none') return;
            if (seen.has(item)) return;
            seen.add(item);
            elements.push({ el: item, rect, type: 'menu' });
        });

        // Cards (but not the detail page poster)
        document.querySelectorAll('.card').forEach(card => {
            const rect = card.getBoundingClientRect();
            if (rect.width === 0 || rect.height === 0) return;
            if (seen.has(card)) return;
            // Skip poster card on detail pages - clicking it does nothing
            if (card.closest('.detailImageContainer')) return;
            seen.add(card);
            // Include cards slightly off-screen in both directions for smooth scrolling navigation
            const maxTop = includeBelow ? window.innerHeight * 2 : window.innerHeight;
            const minBottom = includeBelow ? -window.innerHeight : 0;
            if (rect.top < maxTop && rect.bottom > minBottom) {
                elements.push({ el: card, rect, type: 'card' });
            }
        });

        // Action buttons - only play/resume, not all detailButtons
        document.querySelectorAll('.btnPlay:not(.hide), .btnResume:not(.hide)').forEach(btn => {
            const rect = btn.getBoundingClientRect();
            if (rect.width === 0 || rect.height === 0) return;
            if (seen.has(btn)) return;
            seen.add(btn);
            if (rect.top < window.innerHeight && rect.bottom > 0) {
                elements.push({ el: btn, rect, type: 'button' });
            }
        });

        // Alpha picker buttons (A-Z navigation on right side of grids)
        document.querySelectorAll('.alphaPicker .alphaPickerButton').forEach(btn => {
            const rect = btn.getBoundingClientRect();
            if (rect.width === 0 || rect.height === 0) return;
            const style = window.getComputedStyle(btn);
            if (style.opacity === '0' || style.visibility === 'hidden' || style.display === 'none') return;
            if (seen.has(btn)) return;
            seen.add(btn);
            if (rect.top < window.innerHeight && rect.bottom > 0) {
                elements.push({ el: btn, rect, type: 'alpha' });
            }
        });

        // Pager controls (next/previous page buttons at bottom of grids)
        document.querySelectorAll('.btnNextPage, .btnPreviousPage, .paging button, [data-action="nextpage"], [data-action="previouspage"]').forEach(btn => {
            const rect = btn.getBoundingClientRect();
            if (rect.width === 0 || rect.height === 0) return;
            const style = window.getComputedStyle(btn);
            if (style.opacity === '0' || style.visibility === 'hidden' || style.display === 'none') return;
            if (seen.has(btn)) return;
            seen.add(btn);
            if (rect.top < window.innerHeight && rect.bottom > 0) {
                elements.push({ el: btn, rect, type: 'pager' });
            }
        });

        // Settings/form elements (for dashboard settings pages)
        // Only include if we're on a dashboard/settings page to avoid cluttering normal navigation
        const isDashboardPage = window.location.hash.includes('/dashboard') ||
                               window.location.hash.includes('/configurationpage');
        if (isDashboardPage) {
            // Form elements and buttons in dashboard content area
            // Also include .listItem for user lists, activity lists, etc.
            document.querySelectorAll('input:not([type="hidden"]), select, button.emby-button:not(.hide), button.fab:not(.hide), .checkboxContainer, .selectContainer, .listItem:not(.MuiListItemButton-root)').forEach(el => {
                if (el.closest('.mainDrawer')) return; // Skip drawer
                // On subpages, also skip the MUI sidebar
                if (isDashboardSubpage && el.closest('.MuiDrawer-root')) return;
                if (seen.has(el)) return;
                const rect = el.getBoundingClientRect();
                if (rect.width < 10 || rect.height < 10) return;
                const style = window.getComputedStyle(el);
                if (style.opacity === '0' || style.visibility === 'hidden' || style.display === 'none') return;
                seen.add(el);
                if (rect.top < window.innerHeight && rect.bottom > 0 && rect.left > 0) {
                    elements.push({ el, rect, type: 'input' });
                }
            });
        }

        // Sort by position: top-to-bottom, then left-to-right
        elements.sort((a, b) => {
            const rowDiff = a.rect.top - b.rect.top;
            if (Math.abs(rowDiff) > 20) return rowDiff; // Different rows
            return a.rect.left - b.rect.left; // Same row, sort by left
        });

        return elements;
    }

    function selectElement(element) {
        // Clear previous selection
        if (selectedElement) {
            selectedElement.classList.remove('launchtube-selected');
            selectedElement.classList.remove('launchtube-nav-highlight');
        }

        selectedElement = element;
        if (!element) {
            serverLog('selectElement called with null/undefined');
        }

        if (element) {
            // Use different highlight styles based on element type
            if (element.classList.contains('card')) {
                element.classList.add('launchtube-selected');
            } else {
                element.classList.add('launchtube-nav-highlight');
            }
            ensureElementVisible(element);

            const label = element.textContent?.trim()?.substring(0, 30) ||
                          element.querySelector('[class*="cardText"]')?.textContent?.trim()?.substring(0, 30) ||
                          element.className?.substring(0, 30) || 'unknown';
            serverLog(`Selected: ${label}`);
        }
    }

    // Ensure element is fully visible on screen
    function ensureElementVisible(element) {
        const rect = element.getBoundingClientRect();
        const navBarHeight = 100; // Approximate nav bar height

        // Vertical scrolling for the main window
        if (rect.top < navBarHeight) {
            window.scrollBy({ top: rect.top - navBarHeight - 20, behavior: 'smooth' });
        } else if (rect.bottom > window.innerHeight) {
            window.scrollBy({ top: rect.bottom - window.innerHeight + 20, behavior: 'smooth' });
        }

        // Horizontal scrolling for card rows (they have their own scroll container)
        if (rect.left < 0 || rect.right > window.innerWidth) {
            // Jellyfin uses a scroller wrapper around scrollSlider - find it
            const scrollSlider = element.closest('.scrollSlider');
            if (scrollSlider) {
                const scroller = scrollSlider.parentElement;
                if (scroller) {
                    const scrollerRect = scroller.getBoundingClientRect();
                    if (rect.left < scrollerRect.left) {
                        scroller.scrollBy({ left: rect.left - scrollerRect.left - 50, behavior: 'smooth' });
                    } else if (rect.right > scrollerRect.right) {
                        scroller.scrollBy({ left: rect.right - scrollerRect.right + 50, behavior: 'smooth' });
                    }
                }
            }
        }
    }

    function navigate(direction) {
        const navElements = getNavigableElements(true);
        if (navElements.length === 0) return;

        // If nothing selected, select first visible element
        if (!selectedElement || !document.body.contains(selectedElement)) {
            selectElement(navElements[0].el);
            return;
        }

        const currentRect = selectedElement.getBoundingClientRect();
        const currentCenterX = currentRect.left + currentRect.width / 2;
        const currentCenterY = currentRect.top + currentRect.height / 2;
        const currentIsAlpha = selectedElement.classList.contains('alphaPickerButton');
        const currentIsCard = selectedElement.classList.contains('card') || !!selectedElement.closest('.card');
        const currentIsSidebar = selectedElement.classList.contains('MuiListItemButton-root');

        let bestElement = null;
        let bestDistance = Infinity;

        navElements.forEach(({ el, rect, type }) => {
            if (el === selectedElement) return;
            const centerX = rect.left + rect.width / 2;
            const centerY = rect.top + rect.height / 2;
            const isAlpha = type === 'alpha';
            const isSidebar = el.classList.contains('MuiListItemButton-root');

            // When on sidebar, up/down should ONLY navigate within sidebar
            // Content area is reached via Right arrow or Enter, not up/down
            if (currentIsSidebar && !isSidebar && (direction === 'up' || direction === 'down')) {
                return; // Skip non-sidebar elements for up/down when on sidebar
            }

            // Alpha picker: up/down stays within, only reachable via Right, exits via Left
            if (direction === 'up' || direction === 'down') {
                if (currentIsAlpha && !isAlpha) {
                    return; // On alpha picker, skip non-alpha elements for up/down
                }
                if (!currentIsAlpha && isAlpha) {
                    return; // Not on alpha picker, skip alpha elements for up/down
                }
            }

            // When on a card navigating up/down, strongly prefer other cards over navbar
            // Navbar is only reachable from the top row when no cards are above
            const isNav = type === 'nav';
            const navPenalty = (currentIsCard && isNav && (direction === 'up' || direction === 'down')) ? 10000 : 0;

            // Check overlap for grid navigation
            const hasVerticalOverlap = currentRect.top < rect.bottom && currentRect.bottom > rect.top;
            const hasHorizontalOverlap = currentRect.left < rect.right && currentRect.right > rect.left;
            const isCard = type === 'card';

            let isValidDirection = false;
            switch (direction) {
                case 'left':
                    // From alpha picker, allow going left to cards without strict vertical overlap
                    if (currentIsAlpha && !isAlpha) {
                        isValidDirection = centerX < currentCenterX - 10;
                    } else {
                        isValidDirection = centerX < currentCenterX - 10 && hasVerticalOverlap;
                    }
                    break;
                case 'right':
                    // From sidebar, Right should activate the menu item (handled below), not navigate
                    if (currentIsSidebar) {
                        return; // Skip all elements - we'll activate instead
                    }
                    // To alpha picker, allow going right without strict vertical overlap
                    if (isAlpha && !currentIsAlpha) {
                        isValidDirection = centerX > currentCenterX + 10;
                    } else {
                        isValidDirection = centerX > currentCenterX + 10 && hasVerticalOverlap;
                    }
                    break;
                case 'up':
                    isValidDirection = centerY < currentCenterY - 10;
                    break;
                case 'down':
                    isValidDirection = centerY > currentCenterY + 10;
                    break;
            }

            if (isValidDirection) {
                let distance;
                if (direction === 'up' || direction === 'down') {
                    // Prefer cards in same column (horizontal overlap) but allow fallback to other columns
                    const columnPenalty = (currentIsCard && isCard && !hasHorizontalOverlap) ? 500 : 0;
                    distance = Math.abs(centerY - currentCenterY) + Math.abs(centerX - currentCenterX) * 0.1 + columnPenalty;
                } else if ((currentIsAlpha && !isAlpha) || (isAlpha && !currentIsAlpha) || (currentIsSidebar && !isSidebar)) {
                    // When navigating to/from alpha picker or sidebar, prioritize vertical proximity
                    distance = Math.abs(centerY - currentCenterY) + Math.abs(centerX - currentCenterX) * 0.5;
                } else {
                    distance = Math.abs(centerX - currentCenterX) + Math.abs(centerY - currentCenterY) * 10;
                }

                // Apply navbar penalty so cards are preferred over navbar when navigating up/down
                distance += navPenalty;

                if (distance < bestDistance) {
                    bestDistance = distance;
                    bestElement = el;
                }
            }
        });

        if (bestElement) {
            ignoreMouseUntil = Date.now() + 500;
            const rect = bestElement.getBoundingClientRect();
            serverLog(`Nav ${direction}: -> "${bestElement.textContent?.trim()?.substring(0,20) || bestElement.className?.substring(0,30)}" at top=${Math.round(rect.top)}`);
            selectElement(bestElement);
        } else {
            // Special case: Right arrow from sidebar -> activate the menu item (like Enter)
            if (direction === 'right' && currentIsSidebar) {
                serverLog('Nav right from sidebar: activating menu item');
                activateElement();
                return;
            }

            // Special case: Left arrow on dashboard subpage with no target -> go to sidebar
            const isDashboardSubpage = window.location.hash.includes('/dashboard/') ||
                                       window.location.hash.includes('/configurationpage?');
            if (direction === 'left' && isDashboardSubpage && currentRect) {
                // Find sidebar item closest to current Y position
                const sidebarItems = document.querySelectorAll('.MuiListItemButton-root');
                let bestItem = null;
                let bestDist = Infinity;
                for (const item of sidebarItems) {
                    const rect = item.getBoundingClientRect();
                    if (rect.width > 0 && rect.height > 0 && rect.top > 0 && rect.top < window.innerHeight) {
                        const dist = Math.abs(rect.top - currentRect.top);
                        if (dist < bestDist) {
                            bestDist = dist;
                            bestItem = item;
                        }
                    }
                }
                if (bestItem) {
                    ignoreMouseUntil = Date.now() + 500;
                    selectElement(bestItem);
                    serverLog(`Nav left: -> sidebar "${bestItem.textContent?.trim()?.substring(0,20)}"`);
                    return;
                }
            }
            serverLog(`Nav ${direction}: no valid target found from "${selectedElement?.textContent?.trim()?.substring(0,20) || 'none'}" at top=${Math.round(currentRect?.top || 0)}`);
        }
    }

    function activateElement() {
        if (!selectedElement) return;

        const isCard = selectedElement.classList.contains('card');

        if (isCard) {
            // Double-enter detection for cards: play directly on second enter
            if (pendingEnter) {
                serverLog('Double-enter detected, playing directly');
                pendingEnter = false;
                const itemId = extractItemId(selectedElement);
                if (itemId) {
                    playExternal(itemId, 0);
                }
                return;
            }

            // First enter: navigate to detail page
            pendingEnter = true;
            setTimeout(() => { pendingEnter = false; }, 1500);

            const link = selectedElement.querySelector('a') || selectedElement;
            if (link) {
                serverLog('Activating card');
                link.click();
            }
        } else if (selectedElement.classList.contains('MuiListItemButton-root')) {
            // Sidebar menu item - check if already on this page
            const isSelected = selectedElement.classList.contains('Mui-selected') ||
                              selectedElement.getAttribute('aria-selected') === 'true' ||
                              selectedElement.closest('.MuiListItem-root')?.classList.contains('Mui-selected');
            if (isSelected) {
                // Already on this page - just move to content area
                serverLog('Sidebar item already active, moving to content');
                const contentElements = document.querySelectorAll('input:not([type="hidden"]), select, button.emby-button:not(.hide), button.fab:not(.hide), .checkboxContainer, .selectContainer, .listItem:not(.MuiListItemButton-root)');
                for (const el of contentElements) {
                    if (el.closest('.mainDrawer') || el.closest('.MuiDrawer-root')) continue;
                    const rect = el.getBoundingClientRect();
                    if (rect.width > 0 && rect.height > 0 && rect.top > 0 && rect.top < window.innerHeight && rect.left > 250) {
                        selectElement(el);
                        serverLog('Moved to content: ' + (el.name || el.className?.substring(0, 20)));
                        return;
                    }
                }
            }
            // Not selected or no content found - click to navigate
            serverLog('Activating sidebar menu item');
            selectedElement.click();
        } else {
            // Button or other element - just click it
            serverLog('Activating button');
            selectedElement.click();
        }
    }

    // Keyboard navigation handler
    function handleNavKeydown(event) {
        if (modalElement || confirmationElement) return;
        if (event.target.matches('input, textarea, select')) return;

        const key = event.key;

        if (['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown'].includes(key)) {
            event.preventDefault();
            const direction = key.replace('Arrow', '').toLowerCase();
            navigate(direction);
        } else if (key === 'Enter' && selectedElement) {
            event.preventDefault();
            activateElement();
        }
    }

    document.addEventListener('keydown', handleNavKeydown, true);

    // Track actual mouse movement (not just position on page load)
    document.addEventListener('mousemove', () => {
        mouseHasMoved = true;
    }, { once: true });

    // Follow mouse - select element on hover (debounced, only after mouse moves)
    let mouseDebounceTimer = null;
    document.addEventListener('mouseover', (event) => {
        if (!mouseHasMoved) return; // Ignore until mouse actually moves
        if (Date.now() < ignoreMouseUntil) return;

        // Check for card, button, tab, navbar element, or alpha picker
        let card = event.target.closest('.card');
        // Skip poster card on detail pages - it's not clickable
        if (card && card.closest('.detailImageContainer')) card = null;
        const button = event.target.closest('.btnPlay, .btnResume, .detailButton');
        let tab = event.target.closest('.emby-tab-button');
        // Skip active tab (current page)
        if (tab && tab.classList.contains('emby-tab-button-active')) tab = null;
        const nav = event.target.closest('.headerBackButton, .headerHomeButton, .mainDrawerButton, .headerSyncButton, .headerCastButton, .headerSearchButton, .headerUserButton');
        const menuItem = event.target.closest('a.listItem-border.emby-button, .navMenuOption, .sidebarLink, .listItem-button');
        const alphaPicker = event.target.closest('.alphaPickerButton');
        const target = card || button || tab || nav || menuItem || alphaPicker;

        if (target && target !== selectedElement) {
            clearTimeout(mouseDebounceTimer);
            mouseDebounceTimer = setTimeout(() => {
                if (Date.now() < ignoreMouseUntil) return;
                selectElement(target);
            }, 200);
        }
    });

    // =========================================================================
    // AUTO-SELECT PRIORITY ORDER - DO NOT CHANGE WITHOUT CAREFUL CONSIDERATION
    // =========================================================================
    // This function runs when a page loads to select the first interactive element.
    // The priority order is CRITICAL and depends on page type:
    //
    // NORMAL PAGES (home, library, etc.):
    //   1. Play/Resume button (on detail pages)
    //   2. Cards - THIS IS THE MAIN CONTENT
    //   3. Menu items (fallback only)
    //
    // DASHBOARD/SETTINGS PAGES:
    //   1. Menu items in the sidebar - THIS IS THE MAIN NAVIGATION
    //   2. Cards (fallback - dashboard has "active devices" card)
    //
    // COMMON REGRESSION: Menu items get selected on the home page because:
    //   - The sidebar drawer (.mainDrawer) has menu items that pass visibility checks
    //   - Drawer items may have non-zero size even when drawer is "closed"
    //   - DO NOT select drawer items - they are NOT the dashboard sidebar
    // =========================================================================
    let hasAutoSelected = false;
    function autoSelectFirst() {
        const isDashboard = window.location.hash.includes('/dashboard') ||
                           window.location.hash.includes('/configurationpage') ||
                           window.location.hash.includes('mypreferencesmenu');

        // PRIORITY 1: Play/Resume button on detail pages (not on dashboard)
        if (!isDashboard) {
            const playBtn = document.querySelector('.btnPlay:not(.hide), .btnResume:not(.hide)');
            if (playBtn) {
                const rect = playBtn.getBoundingClientRect();
                if (rect.width > 0 && rect.height > 0) {
                    const currentIsCard = selectedElement && selectedElement.classList.contains('card');
                    if (!hasAutoSelected || currentIsCard) {
                        hasAutoSelected = true;
                        selectElement(playBtn);
                        serverLog('Auto-selected play button');
                    }
                    return;
                }
            }
        }

        // PRIORITY 2 (dashboard subpages like /dashboard/devices): Content area FIRST
        // When navigating to a specific settings page, select the content, not the sidebar
        const isDashboardSubpage = isDashboard && (
            window.location.hash.includes('/dashboard/') ||
            window.location.hash.includes('/configurationpage?')
        );
        if (isDashboardSubpage && !hasAutoSelected) {
            const contentElements = document.querySelectorAll('.mainDrawerContent input:not([type="hidden"]), .mainDrawerContent select, .mainDrawerContent button:not(.hide), .mainDrawerContent .emby-button:not(.hide), .mainDrawerContent .checkboxContainer, .readOnlyContent input:not([type="hidden"]), .readOnlyContent select, .readOnlyContent button:not(.hide), .content-primary input:not([type="hidden"]), .content-primary select, .content-primary button:not(.hide)');
            for (const el of contentElements) {
                if (el.closest('.mainDrawer')) continue;
                const rect = el.getBoundingClientRect();
                if (rect.width > 0 && rect.height > 0 && rect.top > 0 && rect.top < window.innerHeight) {
                    hasAutoSelected = true;
                    selectElement(el);
                    serverLog('Auto-selected settings content: ' + (el.name || el.className?.substring(0, 20)));
                    return;
                }
            }
        }

        // PRIORITY 2 (dashboard main page): Menu items in sidebar FIRST
        // Dashboard has its own sidebar (NOT .mainDrawer) that should be primary navigation
        // Jellyfin 10.9+ uses Material UI (MuiListItemButton) for dashboard sidebar
        if (isDashboard && !isDashboardSubpage && !hasAutoSelected) {
            // Try MUI buttons first (new Jellyfin), then fall back to older selectors
            const menuItems = document.querySelectorAll('.MuiListItemButton-root, a.listItem-border.emby-button:not(.hide), .navMenuOption, .sidebarLink, .listItem-button');
            serverLog(`Dashboard: found ${menuItems.length} potential menu items`);
            for (const menuItem of menuItems) {
                if (menuItem.closest('.mainDrawer')) continue; // Skip the hidden drawer
                const rect = menuItem.getBoundingClientRect();
                serverLog(`  Menu item: "${menuItem.textContent?.trim()?.substring(0,20)}" top=${rect.top} left=${rect.left} w=${rect.width}`);
                if (rect.width > 0 && rect.height > 0 && rect.top < window.innerHeight && rect.top > 0) {
                    hasAutoSelected = true;
                    selectElement(menuItem);
                    serverLog('Auto-selected dashboard menu item: ' + menuItem.textContent?.trim()?.substring(0, 20));
                    return;
                }
            }
        }

        // PRIORITY 2 (normal pages): First visible card - THIS IS THE MAIN CONTENT
        // Cards should ALWAYS be selected over menu items on non-dashboard pages
        const cards = Array.from(document.querySelectorAll('.card')).filter(card => {
            if (card.closest('.detailImageContainer')) return false;
            const rect = card.getBoundingClientRect();
            return rect.width > 0 && rect.height > 0 && rect.top < window.innerHeight && rect.bottom > 0;
        });
        if (cards.length > 0) {
            if (!hasAutoSelected) {
                hasAutoSelected = true;
                selectElement(cards[0]);
                serverLog('Auto-selected first card');
            }
            return; // IMPORTANT: Return here even if already selected - don't fall through to menu items
        }

        // PRIORITY 3: Menu items - fallback for pages with no cards
        // =========================================================================
        // CRITICAL: The drawer (.mainDrawer) is ALWAYS present in the DOM on every page.
        // It's hidden off-screen (transform: translateX(-100%)) but items still have size.
        // We MUST skip drawer items here, otherwise dashboard/settings pages will select
        // drawer items instead of the actual page menu items.
        // The dashboard has its OWN sidebar (not .mainDrawer) - those ARE selectable.
        // =========================================================================
        if (!hasAutoSelected) {
            const menuItems = document.querySelectorAll('a.listItem-border.emby-button:not(.hide), .navMenuOption:not(.mainDrawer *), .sidebarLink, .listItem-button');
            for (const menuItem of menuItems) {
                if (menuItem.closest('.mainDrawer')) continue; // SKIP drawer items - see comment above
                const rect = menuItem.getBoundingClientRect();
                if (rect.width > 0 && rect.height > 0 && rect.top < window.innerHeight && rect.top > 0) {
                    hasAutoSelected = true;
                    selectElement(menuItem);
                    serverLog('Auto-selected menu item: ' + menuItem.textContent?.trim()?.substring(0, 20));
                    return;
                }
            }
        }

        // Keep existing selection if we have one
        if (selectedElement) return;
    }

    // Watch for page changes
    let lastUrl = location.href;
    const pageObserver = new MutationObserver(() => {
        // Detect URL change (hash navigation)
        if (location.href !== lastUrl) {
            serverLog(`URL changed: ${lastUrl} -> ${location.href}`);
            lastUrl = location.href;
            if (selectedElement) {
                selectedElement.classList.remove('launchtube-selected', 'launchtube-nav-highlight');
            }
            selectedElement = null;
            hasAutoSelected = false;
            mouseHasMoved = false;
            document.addEventListener('mousemove', () => { mouseHasMoved = true; }, { once: true });
            setTimeout(autoSelectFirst, 300);
            return;
        }

        // Check if selected element is gone or no longer visible
        let selectionInvalid = false;
        if (selectedElement) {
            if (!document.body.contains(selectedElement)) {
                serverLog(`Selection invalid: element removed from DOM`);
                selectionInvalid = true;
            } else {
                // Check if still visible (not hidden by tab switch, etc.)
                const rect = selectedElement.getBoundingClientRect();
                if (rect.width === 0 || rect.height === 0) {
                    serverLog(`Selection invalid: element has 0 size (${rect.width}x${rect.height})`);
                    selectionInvalid = true;
                }
            }
        }

        if (selectionInvalid) {
            selectedElement.classList.remove('launchtube-selected', 'launchtube-nav-highlight');
            selectedElement = null;
            hasAutoSelected = false; // Reset for new page
            mouseHasMoved = false; // Reset so mouse doesn't immediately take over
            // Re-add the mousemove listener
            document.addEventListener('mousemove', () => {
                mouseHasMoved = true;
            }, { once: true });
            setTimeout(autoSelectFirst, 100);
        } else if (!selectedElement) {
            setTimeout(autoSelectFirst, 100);
        } else {
            // Still have selection, but check if play button appeared
            autoSelectFirst();
        }
    });
    pageObserver.observe(document.body, { childList: true, subtree: true });

    // Listen for hash changes (Jellyfin uses hash-based routing)
    window.addEventListener('hashchange', () => {
        serverLog(`Hash changed to: ${location.hash}, clearing selection`);
        if (selectedElement) {
            selectedElement.classList.remove('launchtube-selected', 'launchtube-nav-highlight');
        }
        selectedElement = null;
        hasAutoSelected = false;
        mouseHasMoved = false;
        document.addEventListener('mousemove', () => { mouseHasMoved = true; }, { once: true });
        setTimeout(autoSelectFirst, 300);
    });

    // Initial auto-select with retry
    let autoSelectRetries = 0;
    function tryAutoSelect() {
        autoSelectFirst();
        // If nothing selected and we haven't retried too many times, try again
        if (!selectedElement && autoSelectRetries < 5) {
            autoSelectRetries++;
            setTimeout(tryAutoSelect, 500);
        }
    }
    setTimeout(tryAutoSelect, 500);

    // Debug: Log card structure when pressing Ctrl+I
    function logCardStructure() {
        serverLog('=== Card Structure Debug ===');

        // Log navbar elements
        const navSelectors = '.headerTabs, .headerTabs a, .headerButton, .headerRight, .skinHeader, .mainDrawerButton, [class*="header"]';
        const navElements = document.querySelectorAll(navSelectors);
        serverLog(`Found ${navElements.length} potential navbar elements:`);
        Array.from(navElements).slice(0, 15).forEach((el, i) => {
            const rect = el.getBoundingClientRect();
            const classes = el.className?.substring(0, 50) || '';
            const tag = el.tagName;
            const text = el.textContent?.trim()?.substring(0, 20) || '';
            serverLog(`  Nav[${i}]: <${tag}> "${text}" class="${classes}" top=${Math.round(rect.top)} left=${Math.round(rect.left)} w=${Math.round(rect.width)}`);
        });

        // Log all emby-tab-button elements
        const tabButtons = document.querySelectorAll('.emby-tab-button');
        serverLog(`emby-tab-button elements (${tabButtons.length}):`);
        tabButtons.forEach((el, i) => {
            const rect = el.getBoundingClientRect();
            const text = el.textContent?.trim() || '';
            const classes = el.className?.substring(0, 50) || '';
            serverLog(`  TabBtn[${i}]: "${text}" class="${classes}" top=${Math.round(rect.top)} left=${Math.round(rect.left)} w=${Math.round(rect.width)} h=${Math.round(rect.height)}`);
        });

        // Log actual navigable elements
        const navEls = getNavigableElements();
        serverLog(`Actual navigable elements (${navEls.length}):`);
        navEls.filter(n => n.type === 'nav').forEach((n, i) => {
            const text = n.el.textContent?.trim()?.substring(0, 15) || '';
            serverLog(`  NavEl[${i}]: "${text}" left=${Math.round(n.rect.left)} w=${Math.round(n.rect.width)}`);
        });

        // Log play buttons on detail page
        const playButtons = document.querySelectorAll('.btnPlay, .btnResume, .detailButton, [data-action="play"], [data-action="resume"]');
        if (playButtons.length > 0) {
            serverLog(`Found ${playButtons.length} play-related buttons:`);
            playButtons.forEach((btn, i) => {
                const classes = btn.className?.substring(0, 60) || '';
                const text = btn.textContent?.trim()?.substring(0, 30) || '';
                const action = btn.dataset?.action || '';
                serverLog(`  Btn[${i}]: "${text}" class="${classes}" action=${action}`);
            });
        }

        // Find all cards that are visible (have non-zero size and in viewport)
        const allCards = document.querySelectorAll('.card');
        const visibleCards = Array.from(allCards).filter(card => {
            const rect = card.getBoundingClientRect();
            return rect.width > 0 && rect.height > 0 && rect.top < window.innerHeight && rect.bottom > 0;
        });

        serverLog(`Found ${allCards.length} total, ${visibleCards.length} visible .card elements`);

        // Log first few visible cards with their titles
        visibleCards.slice(0, 5).forEach((card, i) => {
            const rect = card.getBoundingClientRect();
            const dataId = card.dataset?.id || card.querySelector('[data-id]')?.dataset?.id || 'none';
            const title = card.querySelector('.cardText, .cardTextCentered, [class*="cardText"]')?.textContent?.trim() || 'no title';
            serverLog(`Card[${i}]: "${title.substring(0, 30)}" id=${dataId.substring(0, 12)} top=${Math.round(rect.top)} left=${Math.round(rect.left)} w=${Math.round(rect.width)}`);
        });

        // Find the parent container of visible cards
        if (visibleCards.length > 0) {
            const parent = visibleCards[0].parentElement;
            serverLog(`Parent: ${parent?.tagName} class="${parent?.className?.substring(0, 60)}"`);
        }

        serverLog('=== End Debug ===');
    }

    // Debug key handler
    document.addEventListener('keydown', (event) => {
        if (event.key === 'i' && event.ctrlKey) {
            event.preventDefault();
            logCardStructure();
        }
    });

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
