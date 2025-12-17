// Launch Tube: YouTube - TV-style navigation, SponsorBlock, Escape to exit
(function() {
    'use strict';
    const LAUNCH_TUBE_PORT = window.LAUNCH_TUBE_PORT || 8765;
    const LAUNCH_TUBE_URL = `http://localhost:${LAUNCH_TUBE_PORT}`;
    const SPONSORBLOCK_API = 'https://sponsor.ajay.app/api';

    let confirmationElement = null;
    let currentVideoId = null;
    let sponsorSegments = [];
    let lastSkipTime = 0;
    let selectedElement = null;
    let ignoreMouseUntil = 0;

    function serverLog(message) {
        console.log(`[LaunchTube] ${message}`);
        if (typeof window.launchTubeLog === 'function') {
            window.launchTubeLog(message, 'info');
        }
    }

    serverLog('YouTube script loaded');

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
        [page-subtype="subscriptions"] ytd-rich-item-renderer:has([href*="/shorts/"]) {
            display: none !important;
        }
    `;
    document.head.appendChild(navStyle);

    // === SponsorBlock Integration ===
    function getVideoId() {
        const url = new URL(location.href);
        return url.searchParams.get('v') || url.pathname.split('/').pop();
    }

    async function fetchSponsorSegments(videoId) {
        try {
            const categories = ['sponsor', 'selfpromo', 'interaction', 'intro', 'outro', 'preview', 'music_offtopic'];
            const url = `${SPONSORBLOCK_API}/skipSegments?videoID=${videoId}&categories=${JSON.stringify(categories)}`;
            const response = await fetch(url);
            if (response.ok) {
                const segments = await response.json();
                serverLog(`SponsorBlock: Found ${segments.length} segments for ${videoId}`);
                return segments;
            } else if (response.status === 404) {
                return [];
            }
        } catch (e) {
            serverLog(`SponsorBlock: Error: ${e.message}`);
        }
        return [];
    }

    function checkAndSkipSponsors(video) {
        if (!video || sponsorSegments.length === 0) return;
        const currentTime = video.currentTime;
        const now = Date.now();
        if (now - lastSkipTime < 1000) return;

        for (const seg of sponsorSegments) {
            const [start, end] = seg.segment;
            if (currentTime >= start && currentTime < end - 0.5) {
                serverLog(`SponsorBlock: Skipping ${seg.category}`);
                video.currentTime = end;
                lastSkipTime = now;
                showNotification(`Skipped: ${seg.category}`);
                break;
            }
        }
    }

    function showNotification(message) {
        const existing = document.getElementById('launchtube-notification');
        if (existing) existing.remove();

        const notification = document.createElement('div');
        notification.id = 'launchtube-notification';
        notification.textContent = message;
        Object.assign(notification.style, {
            position: 'fixed', bottom: '80px', right: '20px',
            background: 'rgba(0,0,0,0.8)', color: '#0f0', padding: '10px 20px',
            borderRadius: '4px', fontSize: '14px', zIndex: '2147483647',
            fontFamily: 'system-ui, sans-serif'
        });
        document.body.appendChild(notification);
        setTimeout(() => notification.remove(), 2000);
    }

    async function onVideoChange() {
        const videoId = getVideoId();
        if (videoId && videoId !== currentVideoId && videoId.length === 11) {
            currentVideoId = videoId;
            sponsorSegments = await fetchSponsorSegments(videoId);
        }
    }

    function enableTheaterModeIfNeeded() {
        const player = document.querySelector('#movie_player');
        if (!player) return;
        if (player.classList.contains('ytp-fullscreen')) return; // Already fullscreen
        if (player.classList.contains('ytp-big-mode')) return; // Already theater mode

        const theaterBtn = document.querySelector('.ytp-size-button');
        if (theaterBtn) {
            serverLog('Enabling theater mode');
            theaterBtn.click();
        }
    }

    function initSponsorBlock() {
        const video = document.querySelector('video');
        if (video) {
            video.addEventListener('timeupdate', () => checkAndSkipSponsors(video));
            serverLog('SponsorBlock: Attached to video');
        }

        let lastUrl = location.href;
        const observer = new MutationObserver(() => {
            if (location.href !== lastUrl) {
                lastUrl = location.href;
                onVideoChange();
            }
        });
        observer.observe(document.body, { childList: true, subtree: true });
        onVideoChange();
    }

    // === TV-Style Navigation ===
    function getNavigableElements() {
        const elements = [];
        const seen = new Set();

        // Video cards on homepage and search results
        const videoSelectors = [
            'ytd-rich-item-renderer',           // Homepage grid
            'ytd-video-renderer',               // Search results
            'ytd-compact-video-renderer',       // Sidebar recommendations
            'ytd-grid-video-renderer',          // Grid layout
            'ytd-playlist-video-renderer',      // Playlist items
            'ytd-shelf-renderer ytd-video-renderer', // Shelf rows
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

        const currentRect = selectedElement.getBoundingClientRect();
        const cx = currentRect.left + currentRect.width / 2;
        const cy = currentRect.top + currentRect.height / 2;

        let best = null;
        let bestDist = Infinity;

        for (const { el, rect } of elements) {
            if (el === selectedElement) continue;
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
                const dist = (direction === 'up' || direction === 'down')
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

        // Check if this is a video card
        const isVideo = selectedElement.matches('ytd-rich-item-renderer, ytd-video-renderer, ytd-compact-video-renderer, ytd-grid-video-renderer, ytd-playlist-video-renderer');
        serverLog(`Activating: isVideo=${isVideo}`);

        // Go fullscreen immediately if activating a video
        if (isVideo && !document.fullscreenElement) {
            serverLog('Requesting fullscreen before navigation');
            document.documentElement.requestFullscreen()
                .then(() => serverLog('Fullscreen success'))
                .catch(err => serverLog(`Fullscreen failed: ${err.message}`));
        }

        // Find the clickable link or the element itself
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

            // Fullscreen YouTube player when navigating to video page
            if (location.pathname === '/watch') {
                setTimeout(() => {
                    const player = document.querySelector('#movie_player');
                    if (!player) return;

                    // If fullscreen was requested, click YouTube's fullscreen button
                    if (window._launchtubeFullscreenPlayer) {
                        window._launchtubeFullscreenPlayer = false;
                        const fullscreenBtn = document.querySelector('.ytp-fullscreen-button');
                        if (fullscreenBtn && !player.classList.contains('ytp-fullscreen')) {
                            serverLog('Clicking YouTube fullscreen button');
                            fullscreenBtn.click();
                            return;
                        }
                    }

                    // Otherwise enable theater mode if not fullscreen
                    enableTheaterModeIfNeeded();
                }, 1000);
            }
        }
    }

    // === Exit Confirmation ===
    function handleGlobalEscape(event) {
        if (event.key === 'Escape' && !confirmationElement) {
            // Let video player handle fullscreen exit
            if (document.fullscreenElement) return;

            // If on video page and not in fullscreen, go back
            if (location.pathname === '/watch') {
                event.preventDefault();
                event.stopPropagation();
                showExitConfirmation();
                return;
            }

            // On homepage, show exit confirmation
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
        serverLog('Initializing YouTube integration');

        // Intercept clicks on video links - set flag to fullscreen player after navigation
        document.addEventListener('click', (e) => {
            const link = e.target.closest('a[href*="/watch"]');
            if (link) {
                serverLog('Video link click - will fullscreen player');
                window._launchtubeFullscreenPlayer = true;
            }
        }, true);

        // Enable theater mode when on video page (if not fullscreen)
        if (location.pathname === '/watch') {
            setTimeout(enableTheaterModeIfNeeded, 1000);
        }

        // Enable theater mode when exiting fullscreen
        document.addEventListener('fullscreenchange', () => {
            if (!document.fullscreenElement && location.pathname === '/watch') {
                setTimeout(enableTheaterModeIfNeeded, 500);
            }
        });

        // Navigation
        document.addEventListener('keydown', handleNavKeydown, true);
        document.addEventListener('keydown', handleGlobalEscape, true);

        // URL change detection
        const observer = new MutationObserver(checkUrlChange);
        observer.observe(document.body, { childList: true, subtree: true });

        // Auto-select first video after page loads
        setTimeout(autoSelectFirst, 1000);

        // SponsorBlock
        function waitForVideo() {
            const video = document.querySelector('video');
            if (video) {
                initSponsorBlock();
            } else {
                setTimeout(waitForVideo, 500);
            }
        }
        waitForVideo();
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }
})();
