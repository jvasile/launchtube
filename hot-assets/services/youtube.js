// Launch Tube: YouTube - TV-style navigation, external player via mpv
(function() {
    'use strict';
    const LAUNCH_TUBE_PORT = window.LAUNCH_TUBE_PORT || 8765;
    const LAUNCH_TUBE_URL = `http://localhost:${LAUNCH_TUBE_PORT}`;

    let confirmationElement = null;
    let modalElement = null;
    let statusElement = null;
    let pollInterval = null;
    let selectedElement = null;
    let ignoreMouseUntil = 0;

    function serverLog(message) {
        console.log(`[LaunchTube] ${message}`);
        if (typeof window.launchTubeLog === 'function') {
            window.launchTubeLog(message, 'info');
        }
    }

    serverLog('YouTube script loaded');

    // === External Player Modal ===
    function showModal(message) {
        if (modalElement) return;

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
                    border-top-color: #ff0000;
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
        document.removeEventListener('keydown', handleModalKeydown, true);
        if (modalElement) {
            modalElement.remove();
            modalElement = null;
            statusElement = null;
        }
        if (stopPlayer) {
            serverLog('Stopping player...');
            fetch(`${LAUNCH_TUBE_URL}/api/1/player/stop`, { method: 'POST' })
                .then(r => serverLog('Stop response: ' + r.status))
                .catch(e => serverLog('Stop failed: ' + e));
        }
    }

    function handleModalKeydown(event) {
        if (event.key === 'Escape') {
            serverLog('Escape pressed during playback, stopping player');
            event.preventDefault();
            event.stopPropagation();
            event.stopImmediatePropagation();
            hideModal(true);
        }
    }

    function startStatusPolling() {
        setTimeout(() => {
            pollInterval = setInterval(async () => {
                try {
                    const response = await fetch(`${LAUNCH_TUBE_URL}/api/1/player/status`);
                    const status = await response.json();

                    if (!status.playing) {
                        serverLog('Player stopped, hiding modal');
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
        }, 2000);
    }

    // Extract video URL from a video card element
    function extractVideoUrl(element) {
        // Look for the thumbnail link or video title link
        const link = element.querySelector('a#thumbnail, a#video-title-link, a[href*="/watch"]');
        if (link && link.href) {
            return link.href;
        }
        // Check if element itself is a link
        if (element.href && element.href.includes('/watch')) {
            return element.href;
        }
        return null;
    }

    // Extract video title from a video card element
    function extractVideoTitle(element) {
        const titleEl = element.querySelector('#video-title, #title, yt-formatted-string#video-title');
        return titleEl?.textContent?.trim() || 'YouTube Video';
    }

    // Play video in external player
    async function playExternal(url, title) {
        showModal('Loading...');

        try {
            serverLog(`Playing externally: ${url}`);
            const response = await fetch(`${LAUNCH_TUBE_URL}/api/1/player/play`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ url, title, startPosition: 0 }),
            });

            if (!response.ok) throw new Error(`Player API error: ${response.status}`);
            serverLog('Player started');
            updateModalStatus('Playing...');
            return true;
        } catch (e) {
            serverLog('Failed to play externally: ' + e.message);
            updateModalStatus('Failed to start player: ' + e.message);
            setTimeout(() => hideModal(false), 3000);
            return false;
        }
    }

    // === Highlight Style ===
    const navStyle = document.createElement('style');
    navStyle.textContent = `
        .launchtube-selected {
            outline: 4px solid #ffeb3b !important;
            outline-offset: 2px !important;
            z-index: 1000 !important;
        }
        .launchtube-selected ytd-thumbnail,
        .launchtube-selected #thumbnail {
            outline: 4px solid #ffeb3b !important;
            outline-offset: -4px !important;
        }
        #launchtube-nav-hint {
            position: fixed;
            bottom: 20px;
            left: 20px;
            background: rgba(0,0,0,0.8);
            color: #fff;
            padding: 10px 15px;
            border-radius: 4px;
            font-family: system-ui, sans-serif;
            font-size: 14px;
            z-index: 2147483647;
            opacity: 0;
            transition: opacity 0.3s;
        }
        #launchtube-nav-hint.visible {
            opacity: 1;
        }
        /* Hide Shorts */
        ytd-rich-shelf-renderer[is-shorts],
        ytd-reel-shelf-renderer,
        ytd-rich-section-renderer:has(ytd-rich-shelf-renderer[is-shorts]),
        ytd-rich-shelf-renderer:has([href*="/shorts/"]),
        ytd-rich-item-renderer:has([href*="/shorts/"]),
        ytd-grid-video-renderer:has([href*="/shorts/"]) {
            display: none !important;
        }
        /* Hide Shorts from left menu */
        ytd-guide-entry-renderer:has([title="Shorts"]),
        ytd-mini-guide-entry-renderer:has([title="Shorts"]) {
            display: none !important;
        }
        /* Hide Shorts tab on channel pages */
        yt-tab-shape[tab-title="Shorts"] {
            display: none !important;
        }
        /* Hide sponsored/promoted content */
        ytd-ad-slot-renderer,
        ytd-promoted-sparkles-web-renderer,
        ytd-promoted-video-renderer,
        ytd-display-ad-renderer,
        ytd-in-feed-ad-layout-renderer,
        ytd-banner-promo-renderer,
        ytd-statement-banner-renderer,
        ytd-brand-video-singleton-renderer,
        #masthead-ad,
        #player-ads,
        .ytp-ad-module,
        .video-ads {
            display: none !important;
        }
    `;
    document.head.appendChild(navStyle);

    // === TV-Style Navigation ===
    function getNavigableElements() {
        const elements = [];
        const seen = new Set();

        // Video and playlist cards on homepage and search results
        const videoSelectors = [
            'ytd-rich-item-renderer',           // Homepage grid
            'ytd-video-renderer',               // Search results
            'ytd-compact-video-renderer',       // Sidebar recommendations
            'ytd-grid-video-renderer',          // Grid layout
            'ytd-playlist-video-renderer',      // Playlist items
            'ytd-shelf-renderer ytd-video-renderer', // Shelf rows
            'ytd-playlist-renderer',            // Playlist cards
            'ytd-compact-playlist-renderer',    // Compact playlist cards
            'ytd-grid-playlist-renderer',       // Grid playlist cards
        ];

        document.querySelectorAll(videoSelectors.join(',')).forEach(el => {
            const rect = el.getBoundingClientRect();
            if (rect.width < 50 || rect.height < 50) return;
            if (rect.top > window.innerHeight * 1.5 || rect.bottom < -100) return;
            if (seen.has(el)) return;
            seen.add(el);
            elements.push({ el, rect, type: 'video' });
        });

        // Chip bar (filter buttons)
        document.querySelectorAll('yt-chip-cloud-chip-renderer, ytd-feed-filter-chip-bar-renderer yt-chip-cloud-chip-renderer').forEach(el => {
            const rect = el.getBoundingClientRect();
            if (rect.width < 20 || rect.height < 20) return;
            if (seen.has(el)) return;
            seen.add(el);
            elements.push({ el, rect, type: 'chip' });
        });

        // Guide menu items (left sidebar when expanded)
        document.querySelectorAll('ytd-guide-entry-renderer a').forEach(el => {
            const rect = el.getBoundingClientRect();
            if (rect.width < 20 || rect.height < 20) return;
            if (rect.left > 300) return; // Only left sidebar
            if (seen.has(el)) return;
            seen.add(el);
            elements.push({ el, rect, type: 'guide' });
        });

        // Channel tabs (Videos, Playlists, etc.)
        document.querySelectorAll('yt-tab-shape, yt-chip-cloud-chip-renderer[chip-style="STYLE_HOME_FILTER"]').forEach(el => {
            const rect = el.getBoundingClientRect();
            if (rect.width < 20 || rect.height < 20) return;
            if (seen.has(el)) return;
            seen.add(el);
            elements.push({ el, rect, type: 'tabs' });
        });

        // Top navigation bar
        const topnavSelectors = [
            'ytd-masthead #logo a',              // YouTube logo
            'ytd-masthead ytd-searchbox',        // Search box
            'ytd-masthead #voice-search-button', // Voice search
            'ytd-masthead #buttons > ytd-topbar-menu-button-renderer', // Right-side buttons
        ];
        document.querySelectorAll(topnavSelectors.join(',')).forEach(el => {
            const rect = el.getBoundingClientRect();
            if (rect.width < 20 || rect.height < 20) return;
            if (seen.has(el)) return;
            seen.add(el);
            elements.push({ el, rect, type: 'topnav' });
        });

        // Sort by position
        elements.sort((a, b) => {
            const rowDiff = a.rect.top - b.rect.top;
            if (Math.abs(rowDiff) > 30) return rowDiff;
            return a.rect.left - b.rect.left;
        });

        return elements;
    }

    function selectElement(element) {
        if (selectedElement) {
            selectedElement.classList.remove('launchtube-selected');
        }
        selectedElement = element;
        if (element) {
            element.classList.add('launchtube-selected');
            ensureVisible(element);
            const title = element.querySelector('#video-title, #title')?.textContent?.trim()?.substring(0, 40) || 'item';
            serverLog(`Selected: ${title}`);
        }
    }

    function ensureVisible(element) {
        const rect = element.getBoundingClientRect();
        const navHeight = 60;

        if (rect.top < navHeight) {
            window.scrollBy({ top: rect.top - navHeight - 20, behavior: 'smooth' });
        } else if (rect.bottom > window.innerHeight - 20) {
            window.scrollBy({ top: rect.bottom - window.innerHeight + 40, behavior: 'smooth' });
        }
    }

    function navigate(direction) {
        const elements = getNavigableElements();
        if (elements.length === 0) return;

        if (!selectedElement || !document.body.contains(selectedElement)) {
            selectElement(elements[0].el);
            return;
        }

        // Find current element's type
        const currentInfo = elements.find(e => e.el === selectedElement);
        const currentType = currentInfo?.type;

        const currentRect = selectedElement.getBoundingClientRect();
        const cx = currentRect.left + currentRect.width / 2;
        const cy = currentRect.top + currentRect.height / 2;

        let best = null;
        let bestDist = Infinity;

        for (const { el, rect, type } of elements) {
            if (el === selectedElement) continue;

            // For up/down, stay within same type (video grid, guide menu, etc)
            // Exception: allow video/chip <-> tabs <-> topnav transitions
            const isVertical = direction === 'up' || direction === 'down';
            if (isVertical && currentType && type !== currentType) {
                const contentTypes = ['video', 'chip'];
                const allowedTransition =
                    // video/chip -> tabs (up) or tabs -> video/chip (down)
                    (direction === 'up' && type === 'tabs' && contentTypes.includes(currentType)) ||
                    (direction === 'down' && currentType === 'tabs' && contentTypes.includes(type)) ||
                    // tabs -> topnav (up) or topnav -> tabs (down)
                    (direction === 'up' && type === 'topnav' && currentType === 'tabs') ||
                    (direction === 'down' && currentType === 'topnav' && type === 'tabs') ||
                    // video/chip -> topnav (up) when no tabs, or topnav -> video/chip (down) when no tabs
                    (direction === 'up' && type === 'topnav' && contentTypes.includes(currentType)) ||
                    (direction === 'down' && currentType === 'topnav' && contentTypes.includes(type));
                if (!allowedTransition) continue;
            }

            const ex = rect.left + rect.width / 2;
            const ey = rect.top + rect.height / 2;

            let valid = false;
            switch (direction) {
                case 'left':
                    valid = ex < cx - 20 && Math.abs(ey - cy) < rect.height;
                    break;
                case 'right':
                    valid = ex > cx + 20 && Math.abs(ey - cy) < rect.height;
                    break;
                case 'up':
                    valid = ey < cy - 20;
                    break;
                case 'down':
                    valid = ey > cy + 20;
                    break;
            }

            if (valid) {
                const dist = isVertical
                    ? Math.abs(ey - cy) + Math.abs(ex - cx) * 0.3
                    : Math.abs(ex - cx) + Math.abs(ey - cy) * 3;
                if (dist < bestDist) {
                    bestDist = dist;
                    best = el;
                }
            }
        }

        if (best) {
            ignoreMouseUntil = Date.now() + 500;
            selectElement(best);
        }
    }

    function activateElement() {
        if (!selectedElement) return;

        // Check if this is a playlist card
        const isPlaylist = selectedElement.matches('ytd-playlist-renderer, ytd-compact-playlist-renderer, ytd-grid-playlist-renderer');
        if (isPlaylist) {
            const link = selectedElement.querySelector('a[href*="/playlist"]');
            if (link && link.href) {
                const title = selectedElement.querySelector('#video-title, #title, .title')?.textContent?.trim() || 'YouTube Playlist';
                serverLog(`Playing playlist: ${title} - ${link.href}`);
                playExternal(link.href, title);
                return;
            }
        }

        // Check if this is a video card
        const isVideo = selectedElement.matches('ytd-rich-item-renderer, ytd-video-renderer, ytd-compact-video-renderer, ytd-grid-video-renderer, ytd-playlist-video-renderer');
        serverLog(`Activating: isVideo=${isVideo}, isPlaylist=${isPlaylist}`);

        if (isVideo) {
            // Extract video URL and play externally
            const url = extractVideoUrl(selectedElement);
            const title = extractVideoTitle(selectedElement);
            if (url) {
                serverLog(`Playing video: ${title} - ${url}`);
                playExternal(url, title);
                return;
            }
        }

        // For non-video elements (chips, guide menu), click normally
        const link = selectedElement.querySelector('a#thumbnail, a#video-title, a') || selectedElement;
        if (link) {
            serverLog('Clicking link');
            link.click();
        }
    }

    function focusSearch() {
        const searchInput = document.querySelector('input#search, input[name="search_query"]');
        if (searchInput) {
            searchInput.focus();
            serverLog('Focused search');
        }
    }

    function autoSelectFirst() {
        // Don't auto-select on video watch page
        if (location.pathname === '/watch') return;

        const elements = getNavigableElements();
        const videos = elements.filter(e => e.type === 'video');
        if (videos.length > 0 && !selectedElement) {
            selectElement(videos[0].el);
            serverLog('Auto-selected first video');
        }
    }

    // Navigation key handler
    function handleNavKeydown(event) {
        if (confirmationElement) return;

        // Skip if typing in search or comments
        if (event.target.matches('input, textarea, [contenteditable]')) {
            // But allow Escape to blur
            if (event.key === 'Escape') {
                event.target.blur();
                event.preventDefault();
            }
            return;
        }

        const key = event.key;

        // Arrow navigation
        if (['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown'].includes(key)) {
            // Don't hijack arrows on video player
            if (document.activeElement?.closest('#movie_player')) return;

            event.preventDefault();
            navigate(key.replace('Arrow', '').toLowerCase());
        }
        // Enter to activate
        else if (key === 'Enter' && selectedElement) {
            event.preventDefault();
            activateElement();
        }
        // Search shortcuts
        else if (key === '/' || key === 's') {
            event.preventDefault();
            focusSearch();
        }
    }

    // Watch for URL changes (YouTube SPA)
    let lastUrl = location.href;
    function checkUrlChange() {
        if (location.href !== lastUrl) {
            serverLog(`URL changed: ${lastUrl} -> ${location.href}`);
            lastUrl = location.href;
            if (selectedElement) {
                selectedElement.classList.remove('launchtube-selected');
                selectedElement = null;
            }
            setTimeout(autoSelectFirst, 500);
        }
    }

    // === Exit Confirmation ===
    function handleGlobalEscape(event) {
        if (event.key === 'Escape' && !confirmationElement && !modalElement) {
            event.preventDefault();
            event.stopPropagation();
            showExitConfirmation();
        }
    }

    function showExitConfirmation() {
        if (confirmationElement) return;

        confirmationElement = document.createElement('div');
        confirmationElement.id = 'launchtube-confirm';
        Object.assign(confirmationElement.style, {
            position: 'fixed', top: '0', left: '0', right: '0', bottom: '0',
            background: 'rgba(0,0,0,0.8)', zIndex: '2147483647',
            display: 'flex', alignItems: 'center', justifyContent: 'center'
        });

        const box = document.createElement('div');
        Object.assign(box.style, {
            background: '#1a1a1a', border: '1px solid #333', borderRadius: '8px',
            padding: '30px 40px', textAlign: 'center', color: '#fff', fontFamily: 'system-ui, sans-serif'
        });

        const title = document.createElement('div');
        title.textContent = 'Exit and return to launcher?';
        Object.assign(title.style, { fontSize: '20px', marginBottom: '25px' });

        const buttons = document.createElement('div');
        Object.assign(buttons.style, { display: 'flex', gap: '15px', justifyContent: 'center' });

        const cancelBtn = document.createElement('button');
        cancelBtn.textContent = 'Cancel';
        Object.assign(cancelBtn.style, {
            padding: '10px 30px', border: 'none', borderRadius: '4px',
            fontSize: '16px', cursor: 'pointer', background: '#333', color: '#fff'
        });
        cancelBtn.addEventListener('click', hideExitConfirmation);

        const exitBtn = document.createElement('button');
        exitBtn.textContent = 'Exit';
        Object.assign(exitBtn.style, {
            padding: '10px 30px', border: 'none', borderRadius: '4px',
            fontSize: '16px', cursor: 'pointer', background: '#c62828', color: '#fff'
        });
        exitBtn.addEventListener('click', doExit);

        buttons.appendChild(cancelBtn);
        buttons.appendChild(exitBtn);
        box.appendChild(title);
        box.appendChild(buttons);
        confirmationElement.appendChild(box);
        confirmationElement._buttons = [cancelBtn, exitBtn];
        confirmationElement._focusIndex = 1;
        document.body.appendChild(confirmationElement);

        confirmationElement.addEventListener('click', (e) => {
            if (e.target === confirmationElement) hideExitConfirmation();
        });
        document.addEventListener('keydown', handleConfirmKeydown, true);
        exitBtn.focus();
        updateButtonFocus();
    }

    function updateButtonFocus() {
        if (!confirmationElement) return;
        const btns = confirmationElement._buttons;
        const idx = confirmationElement._focusIndex;
        btns.forEach((btn, i) => {
            btn.style.outline = i === idx ? '2px solid #fff' : 'none';
            btn.style.outlineOffset = '2px';
        });
        btns[idx].focus();
    }

    function hideExitConfirmation() {
        document.removeEventListener('keydown', handleConfirmKeydown, true);
        if (confirmationElement) {
            confirmationElement.remove();
            confirmationElement = null;
        }
    }

    function handleConfirmKeydown(event) {
        event.preventDefault(); event.stopPropagation(); event.stopImmediatePropagation();
        if (event.key === 'Escape') {
            hideExitConfirmation();
        } else if (event.key === 'Enter') {
            if (confirmationElement._focusIndex === 0) hideExitConfirmation();
            else doExit();
        } else if (event.key === 'ArrowLeft' || event.key === 'ArrowRight') {
            confirmationElement._focusIndex = confirmationElement._focusIndex === 0 ? 1 : 0;
            updateButtonFocus();
        }
    }

    function doExit() {
        hideExitConfirmation();
        if (typeof window.launchTubeCloseTab === 'function') {
            window.launchTubeCloseTab();
        } else {
            fetch(`${LAUNCH_TUBE_URL}/api/1/browser/close`, { method: 'POST' }).catch(() => {});
        }
    }

    // === Initialize ===
    function init() {
        serverLog('Initializing YouTube integration (external player mode)');

        // Intercept clicks on video thumbnails and links - play externally
        document.addEventListener('click', (e) => {
            // Check for playlist card first
            const playlistCard = e.target.closest('ytd-playlist-renderer, ytd-compact-playlist-renderer, ytd-grid-playlist-renderer');
            if (playlistCard) {
                const link = playlistCard.querySelector('a[href*="/playlist"]');
                if (link && link.href) {
                    const title = playlistCard.querySelector('#video-title, #title, .title')?.textContent?.trim() || 'YouTube Playlist';
                    e.preventDefault();
                    e.stopPropagation();
                    e.stopImmediatePropagation();
                    serverLog(`Playlist click intercepted: ${title} - ${link.href}`);
                    playExternal(link.href, title);
                    return;
                }
            }

            // Find the video card container
            const videoCard = e.target.closest('ytd-rich-item-renderer, ytd-video-renderer, ytd-compact-video-renderer, ytd-grid-video-renderer, ytd-playlist-video-renderer');
            if (videoCard) {
                const url = extractVideoUrl(videoCard);
                const title = extractVideoTitle(videoCard);
                if (url) {
                    e.preventDefault();
                    e.stopPropagation();
                    e.stopImmediatePropagation();
                    serverLog(`Click intercepted: ${title} - ${url}`);
                    playExternal(url, title);
                    return;
                }
            }

            // Also intercept direct clicks on watch links (e.g., video title text)
            const link = e.target.closest('a[href*="/watch"]');
            if (link && link.href) {
                // Find title from nearby elements
                const card = link.closest('ytd-rich-item-renderer, ytd-video-renderer, ytd-compact-video-renderer, ytd-grid-video-renderer, ytd-playlist-video-renderer');
                const title = card ? extractVideoTitle(card) : 'YouTube Video';
                e.preventDefault();
                e.stopPropagation();
                e.stopImmediatePropagation();
                serverLog(`Link click intercepted: ${title} - ${link.href}`);
                playExternal(link.href, title);
                return;
            }

            // Intercept direct playlist link clicks
            const playlistLink = e.target.closest('a[href*="/playlist"]');
            if (playlistLink && playlistLink.href) {
                const title = 'YouTube Playlist';
                e.preventDefault();
                e.stopPropagation();
                e.stopImmediatePropagation();
                serverLog(`Playlist link click intercepted: ${playlistLink.href}`);
                playExternal(playlistLink.href, title);
            }
        }, true);

        // Navigation
        document.addEventListener('keydown', handleNavKeydown, true);
        document.addEventListener('keydown', handleGlobalEscape, true);

        // URL change detection
        const observer = new MutationObserver(checkUrlChange);
        observer.observe(document.body, { childList: true, subtree: true });

        // Auto-select first video after page loads
        setTimeout(autoSelectFirst, 1000);
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }
})();
