// ==UserScript==
// @name         Launch Tube Loader
// @namespace    com.launchtube
// @version      1.4
// @description  Loads service-specific scripts from Launch Tube app
// @match        *://*/*
// @grant        GM.xmlHttpRequest
// @grant        GM_xmlhttpRequest
// @connect      localhost
// @connect      127.0.0.1
// @run-at       document-start
// ==/UserScript==

(function() {
    'use strict';

    const PORTS = [8765, 8766, 8767, 8768, 8769];

    // Compatibility wrapper for GM.xmlHttpRequest (Greasemonkey 4+) and GM_xmlhttpRequest (Tampermonkey)
    function gmFetch(options) {
        return new Promise((resolve, reject) => {
            // Greasemonkey 4+ style (returns promise)
            if (typeof GM !== 'undefined' && GM.xmlHttpRequest) {
                GM.xmlHttpRequest({
                    ...options,
                    onload: resolve,
                    onerror: reject,
                    ontimeout: reject,
                });
            }
            // Tampermonkey / Greasemonkey 3 style
            else if (typeof GM_xmlhttpRequest !== 'undefined') {
                GM_xmlhttpRequest({
                    ...options,
                    onload: resolve,
                    onerror: reject,
                    ontimeout: reject,
                });
            }
            else {
                reject(new Error('No userscript HTTP API available'));
            }
        });
    }

    // Map hostnames to service IDs
    const SERVICE_MAP = {
        'tv.apple.com': 'appletv',
        'britbox.com': 'britbox',
        'www.britbox.com': 'britbox',
        'crackle.com': 'crackle',
        'www.crackle.com': 'crackle',
        'crunchyroll.com': 'crunchyroll',
        'www.crunchyroll.com': 'crunchyroll',
        'curiositystream.com': 'curiosity',
        'www.curiositystream.com': 'curiosity',
        'disneyplus.com': 'disney',
        'www.disneyplus.com': 'disney',
        'espn.com': 'espn',
        'www.espn.com': 'espn',
        'hulu.com': 'hulu',
        'www.hulu.com': 'hulu',
        'max.com': 'max',
        'play.max.com': 'max',
        'www.max.com': 'max',
        'plus.nasa.gov': 'nasaplus',
        'netflix.com': 'netflix',
        'www.netflix.com': 'netflix',
        'nfl.com': 'nfl',
        'www.nfl.com': 'nfl',
        'paramountplus.com': 'paramount',
        'www.paramountplus.com': 'paramount',
        'pbs.org': 'pbs',
        'www.pbs.org': 'pbs',
        'peacocktv.com': 'peacock',
        'www.peacocktv.com': 'peacock',
        'pluto.tv': 'pluto-tv',
        'www.pluto.tv': 'pluto-tv',
        'primevideo.com': 'prime',
        'www.primevideo.com': 'prime',
        'amazon.com': 'prime', // for /video paths
        'www.amazon.com': 'prime',
        'soundcloud.com': 'soundcloud',
        'www.soundcloud.com': 'soundcloud',
        'spotify.com': 'spotify',
        'open.spotify.com': 'spotify',
        'tubitv.com': 'tubi',
        'www.tubitv.com': 'tubi',
        'youtube.com': 'youtube',
        'www.youtube.com': 'youtube',
        'music.youtube.com': 'youtube-music',
    };


    // Detect service from current hostname
    function detectService() {
        const hostname = location.hostname;

        // Direct match
        if (SERVICE_MAP[hostname]) {
            // Special case for Amazon - only match video paths
            if (hostname.includes('amazon.com') && !location.pathname.startsWith('/video')) {
                return null;
            }
            return SERVICE_MAP[hostname];
        }

        // Try without www
        const noWww = hostname.replace(/^www\./, '');
        if (SERVICE_MAP[noWww]) {
            return SERVICE_MAP[noWww];
        }

        // Try matching domain suffix
        for (const [domain, serviceId] of Object.entries(SERVICE_MAP)) {
            if (hostname.endsWith('.' + domain) || hostname === domain) {
                return serviceId;
            }
        }

        return null;
    }

    // Try to connect to a specific port
    async function tryPort(port) {
        console.log(`Launch Tube: Trying port ${port}...`);
        try {
            const response = await gmFetch({
                method: 'GET',
                url: `http://localhost:${port}/api/ping`,
                timeout: 1000,
            });
            console.log(`Launch Tube: Port ${port} response: ${response.status}`);
            if (response.status === 200) {
                const data = JSON.parse(response.responseText);
                if (data.app === 'launchtube') {
                    return port;
                }
            }
        } catch (e) {
            console.log(`Launch Tube: Port ${port} failed:`, e);
        }
        throw new Error('Not Launch Tube');
    }

    // Find the Launch Tube server
    async function findServer() {
        for (const port of PORTS) {
            try {
                return await tryPort(port);
            } catch (e) {
                // Try next port
            }
        }
        return null;
    }

    // Fetch and execute the service script
    async function loadServiceScript(port, serviceId) {
        try {
            const response = await gmFetch({
                method: 'GET',
                url: `http://localhost:${port}/api/service/${serviceId}`,
            });
            if (response.status === 200 && response.responseText) {
                const script = document.createElement('script');
                script.textContent = response.responseText;
                (document.head || document.documentElement).appendChild(script);
                console.log(`Launch Tube: Loaded script for ${serviceId}`);
            } else {
                console.log(`Launch Tube: No script found for ${serviceId}`);
            }
        } catch (e) {
            console.error(`Launch Tube: Failed to load script for ${serviceId}:`, e);
        }
    }

    // Main entry point
    async function main() {
        const serviceId = detectService();
        console.log(`Launch Tube: Detected service: ${serviceId} (hostname: ${location.hostname})`);

        if (!serviceId) {
            return; // Not a recognized service
        }

        const port = await findServer();
        if (!port) {
            console.log('Launch Tube: Server not found');
            return;
        }

        console.log(`Launch Tube: Found server on port ${port}, loading script for ${serviceId}`);
        loadServiceScript(port, serviceId);
    }

    main();
})();
