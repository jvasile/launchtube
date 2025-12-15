// LaunchTube Loader - Content Script (runs in MAIN world at document_start)
(function() {
    'use strict';

    const PORTS = [8765, 8766, 8767, 8768, 8769];
    let detectedPort = null;

    // Create 'default' TrustedTypes policy early (before page CSP kicks in)
    // The 'default' policy is used as fallback for all assignments
    let trustedPolicy = null;
    if (window.trustedTypes && window.trustedTypes.createPolicy) {
        try {
            trustedPolicy = window.trustedTypes.createPolicy('default', {
                createHTML: (s) => s,
                createScript: (s) => s,
                createScriptURL: (s) => s,
            });
            console.log('[LaunchTube] Created default TrustedTypes policy');
        } catch (e) {
            // Default policy may already exist
            console.log('[LaunchTube] Could not create default TrustedTypes policy:', e.message);
            // Try a named policy as fallback
            try {
                trustedPolicy = window.trustedTypes.createPolicy('launchtube', {
                    createHTML: (s) => s,
                    createScript: (s) => s,
                    createScriptURL: (s) => s,
                });
            } catch (e2) {
                console.log('[LaunchTube] Could not create any TrustedTypes policy');
            }
        }
    }

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

                    // Try multiple methods to execute the script
                    let executed = false;

                    // Method 1: Function constructor (may bypass some CSP)
                    if (!executed) {
                        try {
                            const fn = new Function(code);
                            fn();
                            executed = true;
                            serverLog('Script executed via Function()');
                        } catch (e) {
                            serverLog(`Function() failed: ${e.message}`);
                        }
                    }

                    // Method 2: eval with TrustedScript
                    if (!executed && trustedPolicy) {
                        try {
                            eval(trustedPolicy.createScript(code));
                            executed = true;
                            serverLog('Script executed via trusted eval()');
                        } catch (e) {
                            serverLog(`Trusted eval() failed: ${e.message}`);
                        }
                    }

                    // Method 3: Blob URL
                    if (!executed) {
                        try {
                            const blob = new Blob([code], { type: 'application/javascript' });
                            const blobUrl = URL.createObjectURL(blob);
                            const script = document.createElement('script');
                            if (trustedPolicy) {
                                script.src = trustedPolicy.createScriptURL(blobUrl);
                            } else {
                                script.src = blobUrl;
                            }
                            script.onload = () => {
                                URL.revokeObjectURL(blobUrl);
                                serverLog('Script executed via blob URL');
                            };
                            script.onerror = () => {
                                URL.revokeObjectURL(blobUrl);
                                serverLog('Blob URL failed to load', 'error');
                            };
                            (document.head || document.documentElement).appendChild(script);
                        } catch (e) {
                            serverLog(`Blob URL failed: ${e.message}`, 'error');
                        }
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
