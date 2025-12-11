// ==UserScript==
// @name         Launch Tube Loader
// @namespace    com.launchtube
// @version      2.0
// @description  Loads service-specific scripts from Launch Tube app
// @match        *://*/*
// @grant        GM.xmlHttpRequest
// @grant        GM_xmlhttpRequest
// @grant        GM_closeTab
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
    async function loadScript(port) {
        try {
            const response = await gmFetch({
                method: 'GET',
                url: `http://localhost:${port}/api/1/match?url=${encodeURIComponent(location.href)}`,
            });
            if (response.status === 200 && response.responseText) {
                const script = document.createElement('script');
                script.textContent = response.responseText;
                // Make the port available to the script
                script.textContent = `window.LAUNCH_TUBE_PORT = ${port};\n` + script.textContent;
                (document.head || document.documentElement).appendChild(script);
                console.log('Launch Tube: Loaded script for', location.hostname);
            }
        } catch (e) {
            console.error('Launch Tube: Failed to load script:', e);
        }
    }

    // Expose GM_closeTab to page scripts via a global function
    function exposeCloseTab() {
        const script = document.createElement('script');
        script.textContent = `window.launchTubeCloseTab = function() { window.postMessage({ type: 'launchtube-close-tab' }, '*'); };`;
        document.documentElement.appendChild(script);
        script.remove();
    }

    // Main entry point
    async function main() {
        console.log('Launch Tube: Loader running on', location.hostname);

        // Listen for close tab requests from page scripts
        window.addEventListener('message', (e) => {
            if (e.data?.type === 'launchtube-close-tab') {
                console.log('Launch Tube: Close tab requested');
                console.log('Launch Tube: GM_closeTab type:', typeof GM_closeTab);
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

        // Expose the close function to page scripts
        exposeCloseTab();

        const port = await findServer();
        if (!port) {
            console.log('Launch Tube: Server not found on ports', PORTS.join(', '));
            return;
        }
        console.log('Launch Tube: Found server on port', port);

        // Announce to setup page that we're working
        window.postMessage({ type: 'launchtube-loader-ready', port: port }, '*');

        loadScript(port);
    }

    main();
})();
