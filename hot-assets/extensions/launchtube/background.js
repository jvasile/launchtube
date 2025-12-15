// LaunchTube Background Service Worker
// Focuses page content when tab loads so keyboard works immediately

const SERVER_PORT = 8765;
const VERSION = '1.9';

let focusPromptShown = false;

function serverLog(message) {
    console.log('[LaunchTube Background]', message);
    fetch(`http://localhost:${SERVER_PORT}/api/1/log`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ message: `[Background SW] ${message}`, level: 'info' })
    }).catch(() => {});
}

serverLog(`Service worker started v${VERSION}`);

chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
    if (changeInfo.status === 'complete' && tab.url && tab.windowId && !focusPromptShown) {
        // Check if this URL has focus alert enabled
        fetch(`http://localhost:${SERVER_PORT}/api/1/focus-alert?url=${encodeURIComponent(tab.url)}`)
            .then(r => r.json())
            .then(data => {
                if (data.focusAlert && !focusPromptShown) {
                    focusPromptShown = true;
                    serverLog(`Showing focus prompt for ${tab.url.substring(0, 30)}`);
                    chrome.scripting.executeScript({
                        target: { tabId: tabId },
                        func: () => {
                            alert('Press Enter to start');
                            document.body.tabIndex = -1;
                            document.body.focus();
                        },
                        world: 'MAIN'
                    }).catch((err) => {
                        serverLog(`Focus script failed: ${err.message}`);
                    });
                }
            })
            .catch(() => {});
    }
});
