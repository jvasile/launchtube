// ==UserScript==
// @name         Launch Tube Loader
// @namespace    com.launchtube
// @version      8
// @description  Loads service-specific scripts from Launch Tube app
// NOTE: When modifying this file, bump @version to trigger browsers to load the new version
// @match        *://*/*
// @grant        GM.xmlHttpRequest
// @grant        GM_xmlhttpRequest
// @grant        GM_closeTab
// @grant        GM_addElement
// @grant        unsafeWindow
// @connect      localhost
// @connect      127.0.0.1
// @run-at       document-start
// ==/UserScript==

(function() {
    'use strict';

    const PORTS = [8765, 8766, 8767, 8768, 8769];
    let detectedPort = null;

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

    // Try to connect to a specific port
    async function tryPort(port) {
        try {
            const response = await gmFetch({
                method: 'GET',
                url: `http://localhost:${port}/api/1/ping`,
                timeout: 1000,
            });
            if (response.status === 200) {
                const data = JSON.parse(response.responseText);
                if (data.app === 'launchtube') {
                    return port;
                }
            }
        } catch (e) {
            // Port not available
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

    // Ask server to match current URL and return script
    // Uses GM_addElement to bypass Trusted Types CSP (e.g., YouTube)
    async function loadScript(port) {
        try {
            const response = await gmFetch({
                method: 'GET',
                url: `http://localhost:${port}/api/1/match?url=${encodeURIComponent(location.href)}`,
            });
            if (response.status === 200 && response.responseText) {
                const code = `window.LAUNCH_TUBE_PORT = ${port};\n` + response.responseText;
                if (typeof GM_addElement !== 'undefined') {
                    // Tampermonkey: use GM_addElement to bypass Trusted Types
                    GM_addElement('script', { textContent: code });
                } else {
                    // Fallback for other userscript managers
                    const script = document.createElement('script');
                    script.textContent = code;
                    (document.head || document.documentElement).appendChild(script);
                }
                console.log('Launch Tube: Loaded script for', location.hostname);
            }
        } catch (e) {
            console.error('Launch Tube: Failed to load script:', e);
        }
    }

    // Expose functions to page scripts via unsafeWindow
    // Uses unsafeWindow to bypass Trusted Types CSP (e.g., YouTube)
    function exposePageFunctions() {
        if (typeof unsafeWindow !== 'undefined') {
            unsafeWindow.launchTubeCloseTab = function() {
                window.postMessage({ type: 'launchtube-close-tab' }, '*');
            };
            unsafeWindow.launchTubeLog = function(message, level) {
                window.postMessage({ type: 'launchtube-log', message: message, level: level || 'info' }, '*');
            };
        }
    }

    // Main entry point
    async function main() {
        console.log('Launch Tube: Loader running on', location.hostname);

        // Listen for requests from page scripts
        window.addEventListener('message', async (e) => {
            // Log relay - forwards logs to server via gmFetch (bypasses mixed content)
            if (e.data?.type === 'launchtube-log' && detectedPort) {
                gmFetch({
                    method: 'POST',
                    url: `http://localhost:${detectedPort}/api/1/log`,
                    headers: { 'Content-Type': 'application/json' },
                    data: JSON.stringify({ message: e.data.message, level: e.data.level || 'info' }),
                }).catch(() => {});
            }
            // Close tab request
            if (e.data?.type === 'launchtube-close-tab') {
                console.log('Launch Tube: Close tab requested');
                // Call server to close browser (using gmFetch to bypass mixed content blocking)
                if (detectedPort) {
                    try {
                        await gmFetch({
                            method: 'POST',
                            url: `http://localhost:${detectedPort}/api/1/browser/close`,
                        });
                        console.log('Launch Tube: Browser close request sent');
                    } catch (err) {
                        console.log('Launch Tube: Browser close request failed:', err);
                    }
                }
                // Then close the tab
                if (typeof GM_closeTab === 'function') {
                    try {
                        GM_closeTab();
                        console.log('Launch Tube: GM_closeTab called');
                    } catch (err) {
                        console.log('Launch Tube: GM_closeTab error:', err);
                        window.close();
                    }
                } else {
                    console.log('Launch Tube: GM_closeTab not available, trying window.close');
                    window.close();
                }
            }
        });

        // Expose functions to page scripts
        exposePageFunctions();

        const port = await findServer();
        if (!port) {
            console.log('Launch Tube: Server not found on ports', PORTS.join(', '));
            return;
        }
        detectedPort = port;
        console.log('Launch Tube: Found server on port', port);

        // Announce to setup page that we're working (version must match @version above)
        window.postMessage({ type: 'launchtube-loader-ready', port: port, version: 8 }, '*');

        loadScript(port);
    }

    main();
})();
