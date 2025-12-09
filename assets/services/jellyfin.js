// Launch Tube: Jellyfin External Player Integration
// Intercepts video playback and sends it to an external player (mpv)

(function() {
    'use strict';

    console.log('Launch Tube: Jellyfin script loaded');

    const LAUNCH_TUBE_PORT = window.LAUNCH_TUBE_PORT || 8765;
    const LAUNCH_TUBE_URL = `http://localhost:${LAUNCH_TUBE_PORT}`;

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
            fetch(`${LAUNCH_TUBE_URL}/api/player/stop`, { method: 'POST' }).catch(() => {});
        }
    }

    function handleModalKeydown(event) {
        if (event.key === 'Escape') {
            event.preventDefault();
            event.stopPropagation();
            hideModal(true);
        }
    }

    function startStatusPolling() {
        pollInterval = setInterval(async () => {
            try {
                const response = await fetch(`${LAUNCH_TUBE_URL}/api/player/status`);
                const status = await response.json();

                if (!status.playing) {
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

    // Play item in external player
    async function playExternal(itemId, startPositionTicks = 0) {
        const { serverUrl, token } = getServerInfo();

        showModal('Launching player...');

        try {
            const item = await getItemDetails(itemId);
            const title = item.Name || 'Jellyfin Video';
            const streamUrl = buildStreamUrl(itemId);
            const startPosition = startPositionTicks / 10000000;

            // Build onComplete callback to save progress back to Jellyfin
            const onComplete = {
                url: `${serverUrl}/Sessions/Playing/Stopped`,
                method: 'POST',
                headers: { 'X-Emby-Token': token },
                bodyTemplate: {
                    ItemId: itemId,
                    MediaSourceId: item.MediaSources?.[0]?.Id || itemId,
                    PositionTicks: '${positionTicks}',
                },
            };

            console.log('Launch Tube: Playing in external player:', { streamUrl, title, startPosition });

            const response = await fetch(`${LAUNCH_TUBE_URL}/api/player/play`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ url: streamUrl, title, startPosition, onComplete }),
            });

            if (!response.ok) throw new Error(`Player API error: ${response.status}`);
            console.log('Launch Tube: Player started');
            updateModalStatus('Playing...');
            return true;
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

        document.addEventListener('click', function(event) {
            const target = event.target.closest(playSelectors.join(','));
            if (target) {
                const itemId = extractItemId(target);
                if (itemId) {
                    console.log('Launch Tube: Play button clicked, itemId:', itemId);
                    lastClickedItemId = itemId;
                    window.launchTubeLastClickedItemId = itemId;
                    // Clear after a few seconds in case video.play() doesn't fire
                    setTimeout(() => {
                        lastClickedItemId = null;
                        window.launchTubeLastClickedItemId = null;
                    }, 5000);
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

                // Go back from player view
                history.back();

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

        // Inject script to override HTMLVideoElement.prototype.play
        const script = document.createElement('script');
        script.textContent = `
        (function() {
            let intercepting = false;
            const originalPlay = HTMLVideoElement.prototype.play;

            HTMLVideoElement.prototype.play = function() {
                const src = this.src || '';
                console.log('Launch Tube: Video.play() called, src:', src);

                if (intercepting) {
                    return Promise.reject(new Error('Intercepted by Launch Tube'));
                }

                // Check if this looks like Jellyfin video playback
                if (src.includes('blob:') || src.includes('/Videos/')) {
                    intercepting = true;

                    let itemId = null;

                    // From video src (e.g., /Videos/12345/stream)
                    const srcMatch = src.match(/\\/Videos\\/([0-9a-f]+)[\\/\\?]/i);
                    if (srcMatch) itemId = srcMatch[1];

                    // From URL hash
                    if (!itemId) {
                        const urlMatch = window.location.hash.match(/(?:id|itemId)=([0-9a-f]+)/i);
                        if (urlMatch) itemId = urlMatch[1];
                    }

                    // From image URLs on the page
                    if (!itemId) {
                        const img = document.querySelector('img[src*="/Items/"]');
                        if (img) {
                            const imgMatch = img.src.match(/\\/Items\\/([0-9a-f]+)\\//i);
                            if (imgMatch) itemId = imgMatch[1];
                        }
                    }

                    // From PlaybackManager state
                    if (!itemId && window.PlaybackManager) {
                        try {
                            const nowPlaying = window.PlaybackManager.currentItem && window.PlaybackManager.currentItem();
                            if (nowPlaying && nowPlaying.Id) itemId = nowPlaying.Id;
                        } catch(e) {}
                    }

                    // From last clicked play button (stored by attachPlayListeners)
                    if (!itemId && window.launchTubeLastClickedItemId) {
                        itemId = window.launchTubeLastClickedItemId;
                    }

                    console.log('Launch Tube: Intercepting playback, itemId:', itemId);

                    window.postMessage({ type: 'launchtube-intercept', itemId: itemId, src: src }, '*');

                    this.pause();
                    this.src = '';

                    setTimeout(() => { intercepting = false; }, 3000);

                    return Promise.reject(new Error('Intercepted by Launch Tube'));
                }

                return originalPlay.call(this);
            };

            console.log('Launch Tube: Installed video.play() interceptor');
        })();
        `;
        document.documentElement.appendChild(script);
        script.remove();
    }

    // Initialize
    function init() {
        console.log('Launch Tube: Initializing Jellyfin integration');
        attachPlayListeners();
        interceptVideoPlayback();
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        setTimeout(init, 500);
    }
})();
