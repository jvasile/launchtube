// LaunchTube Loader - Bridge Script (runs in ISOLATED world)
// Relays messages between MAIN world (content.js) and background service worker

const VERSION = '2.0';
console.log(`[LaunchTube] Bridge v${VERSION} loaded`);

window.addEventListener('message', (event) => {
    if (event.source !== window) return;
    if (!event.data || event.data.direction !== 'launchtube-to-bridge') return;

    const { id, type, url, options } = event.data;

    if (type === 'fetch') {
        chrome.runtime.sendMessage({ type: 'fetch', url, options }, (response) => {
            window.postMessage({
                direction: 'launchtube-from-bridge',
                id: id,
                response: response
            }, '*');
        });
    }
});
