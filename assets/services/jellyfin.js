// Launch Tube: Jellyfin External Player Integration
// Intercepts video playback and sends it to an external player (mpv)

(function() {
    'use strict';

    console.log('Launch Tube: Jellyfin script loaded');

    const LAUNCH_TUBE_PORT = window.LAUNCH_TUBE_PORT || 8765;
    const LAUNCH_TUBE_URL = `http://localhost:${LAUNCH_TUBE_PORT}`;

    // Get Jellyfin server URL and auth info
    function getServerInfo() {
        // Try to get from Jellyfin's stored credentials
        const credentials = JSON.parse(localStorage.getItem('jellyfin_credentials') || '{}');
        const servers = credentials.Servers || [];

        if (servers.length > 0) {
            const server = servers[0];
            return {
                serverUrl: server.ManualAddress || server.LocalAddress || server.RemoteAddress,
                userId: server.UserId,
                accessToken: server.AccessToken,
            };
        }

        // Fallback: derive from current URL
        return {
            serverUrl: window.location.origin,
            userId: null,
            accessToken: null,
        };
    }

    // Extract item ID from URL or element
    function getItemIdFromUrl() {
        // URL patterns: /web/index.html#!/details?id=XXX or /web/#/details?id=XXX
        const hashParams = new URLSearchParams(window.location.hash.split('?')[1] || '');
        let itemId = hashParams.get('id');

        if (!itemId) {
            // Try query string
            const urlParams = new URLSearchParams(window.location.search);
            itemId = urlParams.get('id');
        }

        return itemId;
    }

    // Get item details from Jellyfin API
    async function getItemDetails(serverUrl, itemId, accessToken, userId) {
        const headers = {};
        if (accessToken) {
            headers['X-Emby-Token'] = accessToken;
        }

        const url = userId
            ? `${serverUrl}/Users/${userId}/Items/${itemId}`
            : `${serverUrl}/Items/${itemId}`;

        const response = await fetch(url, { headers });
        if (!response.ok) {
            throw new Error(`Failed to get item details: ${response.status}`);
        }
        return response.json();
    }

    // Build stream URL for item
    function buildStreamUrl(serverUrl, itemId, accessToken, mediaSourceId) {
        let url = `${serverUrl}/Videos/${itemId}/stream`;
        const params = new URLSearchParams();

        if (mediaSourceId) {
            params.set('MediaSourceId', mediaSourceId);
        }
        params.set('Static', 'true');

        if (accessToken) {
            params.set('api_key', accessToken);
        }

        return `${url}?${params.toString()}`;
    }

    // Play item in external player
    async function playExternal(itemId, startPositionTicks = 0) {
        const serverInfo = getServerInfo();
        if (!serverInfo.serverUrl) {
            console.error('Launch Tube: Could not determine Jellyfin server URL');
            return false;
        }

        try {
            // Get item details for title and media source
            const item = await getItemDetails(
                serverInfo.serverUrl,
                itemId,
                serverInfo.accessToken,
                serverInfo.userId
            );

            const title = item.Name || 'Jellyfin Video';
            const mediaSourceId = item.MediaSources?.[0]?.Id || itemId;
            const streamUrl = buildStreamUrl(
                serverInfo.serverUrl,
                itemId,
                serverInfo.accessToken,
                mediaSourceId
            );

            // Convert ticks to seconds (1 tick = 100 nanoseconds)
            const startPosition = startPositionTicks / 10000000;

            // Build onComplete callback to save progress back to Jellyfin
            const onComplete = {
                url: `${serverInfo.serverUrl}/Sessions/Playing/Stopped`,
                method: 'POST',
                headers: {},
                bodyTemplate: {
                    ItemId: itemId,
                    MediaSourceId: mediaSourceId,
                    PositionTicks: '${positionTicks}',
                },
            };

            if (serverInfo.accessToken) {
                onComplete.headers['X-Emby-Token'] = serverInfo.accessToken;
            }

            console.log('Launch Tube: Playing in external player:', {
                url: streamUrl,
                title,
                startPosition,
            });

            // Call Launch Tube player API
            const response = await fetch(`${LAUNCH_TUBE_URL}/api/player/play`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    url: streamUrl,
                    title,
                    startPosition,
                    onComplete,
                }),
            });

            if (!response.ok) {
                throw new Error(`Player API error: ${response.status}`);
            }

            const result = await response.json();
            console.log('Launch Tube: Player started:', result);
            return true;

        } catch (e) {
            console.error('Launch Tube: Failed to play externally:', e);
            return false;
        }
    }

    // Hook into Jellyfin's play buttons
    function setupPlayInterception() {
        // Method 1: Intercept clicks on play buttons
        document.addEventListener('click', async (e) => {
            const target = e.target.closest('[data-action="play"], [data-action="resume"], .btnPlay, .btnResume, .playButton');
            if (!target) return;

            // Check if this is a video item
            const itemId = getItemIdFromUrl() || target.closest('[data-id]')?.dataset.id;
            if (!itemId) return;

            // Get resume position if this is a resume button
            let startPositionTicks = 0;
            if (target.matches('[data-action="resume"], .btnResume')) {
                try {
                    const serverInfo = getServerInfo();
                    const item = await getItemDetails(
                        serverInfo.serverUrl,
                        itemId,
                        serverInfo.accessToken,
                        serverInfo.userId
                    );
                    startPositionTicks = item.UserData?.PlaybackPositionTicks || 0;
                } catch (e) {
                    console.log('Launch Tube: Could not get resume position:', e);
                }
            }

            // Prevent default Jellyfin playback
            e.preventDefault();
            e.stopPropagation();
            e.stopImmediatePropagation();

            // Play in external player
            playExternal(itemId, startPositionTicks);

        }, { capture: true });

        // Method 2: Override HTMLVideoElement.play() as fallback
        const originalPlay = HTMLVideoElement.prototype.play;
        HTMLVideoElement.prototype.play = function() {
            // Check if this is Jellyfin's video player
            if (this.closest('.videoPlayerContainer, .htmlVideoPlayer, #videoPlayer')) {
                const itemId = getItemIdFromUrl();
                if (itemId) {
                    console.log('Launch Tube: Intercepted video.play() for item:', itemId);
                    // Try to get the current position from the video element
                    const startPositionTicks = Math.floor(this.currentTime * 10000000);
                    playExternal(itemId, startPositionTicks);
                    return Promise.resolve();
                }
            }
            return originalPlay.call(this);
        };

        console.log('Launch Tube: Jellyfin play interception ready');
    }

    // Add external player button to detail pages
    function addExternalPlayerButton() {
        // Wait for detail page to load
        const observer = new MutationObserver(() => {
            // Look for button container on detail pages
            const buttonContainer = document.querySelector('.detailButtons, .mainDetailButtons');
            if (buttonContainer && !buttonContainer.querySelector('.launchTubeBtn')) {
                const itemId = getItemIdFromUrl();
                if (!itemId) return;

                const btn = document.createElement('button');
                btn.className = 'launchTubeBtn paper-icon-button-light';
                btn.innerHTML = `
                    <span class="material-icons">open_in_new</span>
                `;
                btn.title = 'Play in External Player';
                btn.style.cssText = 'margin-left: 8px;';

                btn.addEventListener('click', async (e) => {
                    e.preventDefault();
                    e.stopPropagation();

                    // Get resume position
                    let startPositionTicks = 0;
                    try {
                        const serverInfo = getServerInfo();
                        const item = await getItemDetails(
                            serverInfo.serverUrl,
                            itemId,
                            serverInfo.accessToken,
                            serverInfo.userId
                        );
                        startPositionTicks = item.UserData?.PlaybackPositionTicks || 0;
                    } catch (e) {}

                    playExternal(itemId, startPositionTicks);
                });

                buttonContainer.appendChild(btn);
            }
        });

        observer.observe(document.body, { childList: true, subtree: true });
    }

    // Initialize when DOM is ready
    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', () => {
            setupPlayInterception();
            addExternalPlayerButton();
        });
    } else {
        setupPlayInterception();
        addExternalPlayerButton();
    }
})();
