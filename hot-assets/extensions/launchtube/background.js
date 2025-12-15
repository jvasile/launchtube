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

chrome.tabs.onUpdated.addListener(async (tabId, changeInfo, tab) => {
    if (changeInfo.status === 'complete' && tab.url && tab.windowId) {
        // Check if we already showed the prompt this session
        const { focusPromptShown } = await chrome.storage.session.get('focusPromptShown');
        if (focusPromptShown) return;

        // Check if this URL has focus alert enabled
        try {
            const response = await fetch(`http://localhost:${SERVER_PORT}/api/1/focus-alert?url=${encodeURIComponent(tab.url)}`);
            const data = await response.json();
            if (data.focusAlert) {
                await chrome.storage.session.set({ focusPromptShown: true });
                serverLog(`Showing focus prompt for ${tab.url.substring(0, 30)}`);
                chrome.scripting.executeScript({
                    target: { tabId: tabId },
                    func: () => {
                        const overlay = document.createElement('div');
                        overlay.style.cssText = 'position:fixed;top:0;left:0;width:100%;height:100%;background:rgba(0,0,0,0.8);display:flex;align-items:center;justify-content:center;z-index:999999';
                        overlay.innerHTML = '<div style="color:white;font-size:32px;font-family:sans-serif;text-align:center">LaunchTube in effect.<br>Press Enter to launch the tubes!</div>';
                        document.body.appendChild(overlay);
                        const handler = (e) => {
                            if (e.key === 'Enter') {
                                overlay.remove();
                                document.removeEventListener('keydown', handler);
                                document.body.tabIndex = -1;
                                document.body.focus();
                            }
                        };
                        document.addEventListener('keydown', handler);
                    },
                    world: 'MAIN'
                }).catch((err) => {
                    serverLog(`Focus script failed: ${err.message}`);
                });
            }
        } catch (e) {}
    }
});
