// LaunchTube Background Service Worker
// Focuses page content when tab loads so keyboard works immediately

const SERVER_PORT = 8765;
const VERSION = '1.8';

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
    if (changeInfo.status === 'complete' && tab.url && tab.windowId) {
        const isYouTube = tab.url.includes('youtube.com');
        const showPrompt = isYouTube && !focusPromptShown;

        if (showPrompt) {
            focusPromptShown = true;
            serverLog(`Showing focus prompt for YouTube`);
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
    }
});
