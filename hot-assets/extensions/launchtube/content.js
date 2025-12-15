// LaunchTube Loader - Content Script (runs in MAIN world)
(function() {
    'use strict';

    const VERSION = '2.1';
    const PORTS = [8765, 8766, 8767, 8768, 8769];
    let detectedPort = null;
    let activeProfileId = null;

    // Bridge for fetch requests (bypasses CSP via background service worker)
    const pendingRequests = new Map();
    let requestId = 0;

    window.addEventListener('message', (event) => {
        if (event.source !== window) return;
        if (!event.data || event.data.direction !== 'launchtube-from-bridge') return;

        const { id, response } = event.data;
        const pending = pendingRequests.get(id);
        if (pending) {
            pendingRequests.delete(id);
            pending.resolve(response);
        }
    });

    function bridgedFetch(url, options) {
        return new Promise((resolve, reject) => {
            const id = ++requestId;
            const timeout = setTimeout(() => {
                pendingRequests.delete(id);
                reject(new Error('Bridge fetch timeout'));
            }, 5000);

            pendingRequests.set(id, {
                resolve: (response) => {
                    clearTimeout(timeout);
                    resolve(response);
                }
            });

            window.postMessage({
                direction: 'launchtube-to-bridge',
                id: id,
                type: 'fetch',
                url: url,
                options: options
            }, '*');
        });
    }

    // Try to connect to a specific port
    async function tryPort(port) {
        const response = await bridgedFetch(`http://localhost:${port}/api/1/ping`);
        if (response.ok) {
            try {
                const data = JSON.parse(response.text);
                if (data.app === 'launchtube') {
                    return port;
                }
            } catch (e) {}
        }
        throw new Error('Not LaunchTube');
    }

    // Find the LaunchTube server
    async function findServer() {
        for (const port of PORTS) {
            try {
                return await tryPort(port);
            } catch (e) {}
        }
        return null;
    }

    // Log to server
    function serverLog(message, level = 'info') {
        console.log(`[LaunchTube] ${message}`);
        if (detectedPort) {
            bridgedFetch(`http://localhost:${detectedPort}/api/1/log`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ message: `[Loader] ${message}`, level })
            }).catch(() => {});
        }
    }

    // Get active profile from server
    async function fetchActiveProfile(port) {
        try {
            const response = await bridgedFetch(`http://localhost:${port}/api/1/profile`);
            if (response.ok) {
                const data = JSON.parse(response.text);
                if (data.profileId) {
                    activeProfileId = data.profileId;
                    serverLog(`Active profile: ${activeProfileId}`);
                }
            }
        } catch (e) {
            serverLog(`Failed to fetch profile: ${e.message}`, 'warn');
        }
    }

    // Load and execute script
    async function loadScript(port) {
        try {
            let url = `http://localhost:${port}/api/1/match?url=${encodeURIComponent(location.href)}`;
            if (activeProfileId) {
                url += `&profile=${encodeURIComponent(activeProfileId)}`;
            }
            const response = await bridgedFetch(url);
            if (response.ok && response.text) {
                const code = response.text;
                serverLog(`Got script (${code.length} chars), executing...`);
                window.LAUNCH_TUBE_PORT = port;
                try {
                    eval(code);
                    serverLog('Script executed successfully');
                } catch (e) {
                    serverLog(`Script error: ${e.message}`, 'error');
                }
            }
        } catch (e) {
            serverLog(`Failed to load script: ${e.message}`, 'error');
        }
    }

    // Set up helper functions
    function setupHelpers(port) {
        window.LAUNCH_TUBE_PORT = port;
        window.launchTubeCloseTab = function() {
            bridgedFetch(`http://localhost:${port}/api/1/browser/close`, { method: 'POST' }).catch(() => {});
        };
        window.launchTubeLog = function(message, level) {
            bridgedFetch(`http://localhost:${port}/api/1/log`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ message: message, level: level || 'info' })
            }).catch(() => {});
        };
    }

    // Main
    async function main() {
        console.log(`[LaunchTube] Content v${VERSION} starting on ${location.hostname}`);

        const port = await findServer();
        if (!port) {
            console.log('[LaunchTube] Server not found');
            return;
        }
        detectedPort = port;
        serverLog('Found server on port ' + port);

        // Fetch active profile before loading script
        await fetchActiveProfile(port);

        setupHelpers(port);

        // Announce ready
        window.postMessage({ type: 'launchtube-loader-ready', port: port, version: 1 }, '*');

        loadScript(port);
    }

    main();
})();
