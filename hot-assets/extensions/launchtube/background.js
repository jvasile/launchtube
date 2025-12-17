// LaunchTube Background Service Worker
// Focuses page content when tab loads so keyboard works immediately

const SERVER_PORT = 8765;
const VERSION = '2.2';

function serverLog(message) {
    console.log('[LaunchTube Background]', message);
    fetch(`http://localhost:${SERVER_PORT}/api/1/log`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ message: `[Background SW] ${message}`, level: 'info' })
    }).catch(() => {});
}

serverLog(`Service worker started v${VERSION}`);

// Overlay disabled - using CDP focus instead
// chrome.tabs.onUpdated.addListener(async (tabId, changeInfo, tab) => {
//     ...
// });
