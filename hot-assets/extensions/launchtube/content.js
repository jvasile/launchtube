// LaunchTube Loader - Content Script (runs in MAIN world)
(function() {
    'use strict';

    const PORTS = [8765, 8766, 8767, 8768, 8769];
    let detectedPort = null;

    // Try to connect to a specific port
    async function tryPort(port) {
        try {
            const response = await fetch(`http://localhost:${port}/api/1/ping`, {
                method: 'GET',
                signal: AbortSignal.timeout(1000)
            });
            if (response.ok) {
                const data = await response.json();
                if (data.app === 'launchtube') {
                    return port;
                }
            }
        } catch (e) {}
        throw new Error('Not Launch Tube');
    }

    // Find the Launch Tube server
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
            fetch(`http://localhost:${detectedPort}/api/1/log`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ message: `[Loader] ${message}`, level })
            }).catch(() => {});
        }
    }

    // Load and execute script
    async function loadScript(port) {
        try {
            const response = await fetch(
                `http://localhost:${port}/api/1/match?url=${encodeURIComponent(location.href)}`
            );
            if (response.ok) {
                const code = await response.text();
                if (code) {
                    serverLog(`Got script (${code.length} chars), executing...`);
                    window.LAUNCH_TUBE_PORT = port;
                    try {
                        eval(code);
                        serverLog('Script executed successfully');
                    } catch (e) {
                        serverLog(`Script error: ${e.message}`, 'error');
                    }
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
            fetch(`http://localhost:${port}/api/1/browser/close`, { method: 'POST' }).catch(() => {});
        };
        window.launchTubeLog = function(message, level) {
            fetch(`http://localhost:${port}/api/1/log`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ message: message, level: level || 'info' })
            }).catch(() => {});
        };
    }

    // Main
    async function main() {
        console.log('Launch Tube: Loader starting on', location.hostname);

        const port = await findServer();
        if (!port) {
            console.log('Launch Tube: Server not found');
            return;
        }
        detectedPort = port;
        serverLog('Found server on port ' + port);

        setupHelpers(port);

        // Announce ready
        window.postMessage({ type: 'launchtube-loader-ready', port: port, version: 1 }, '*');

        loadScript(port);
    }

    main();
})();
