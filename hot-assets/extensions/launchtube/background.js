// LaunchTube Background Service Worker
// Focuses page content when tab loads so keyboard works immediately

const SERVER_PORT = 8765;
const VERSION = '2.3';

function serverLog(message) {
    console.log('[LaunchTube Background]', message);
    fetch(`http://localhost:${SERVER_PORT}/api/1/log`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ message: `[Background SW] ${message}`, level: 'info' })
    }).catch(() => {});
}

serverLog(`Service worker started v${VERSION}`);

// Export YouTube cookies to server for yt-dlp
async function exportYouTubeCookies() {
    try {
        const cookies = await chrome.cookies.getAll({ domain: '.youtube.com' });
        if (cookies.length === 0) {
            serverLog('No YouTube cookies found');
            return;
        }

        // Convert to Netscape format
        const lines = ['# Netscape HTTP Cookie File'];
        for (const c of cookies) {
            const domain = c.domain.startsWith('.') ? c.domain : '.' + c.domain;
            const flag = c.domain.startsWith('.') ? 'TRUE' : 'FALSE';
            const secure = c.secure ? 'TRUE' : 'FALSE';
            const expiry = c.expirationDate ? Math.floor(c.expirationDate) : 0;
            lines.push(`${domain}\t${flag}\t${c.path}\t${secure}\t${expiry}\t${c.name}\t${c.value}`);
        }

        const response = await fetch(`http://localhost:${SERVER_PORT}/api/1/cookies`, {
            method: 'POST',
            headers: { 'Content-Type': 'text/plain' },
            body: lines.join('\n')
        });

        if (response.ok) {
            serverLog(`Exported ${cookies.length} YouTube cookies`);
        } else {
            serverLog(`Failed to export cookies: ${response.status}`);
        }
    } catch (e) {
        serverLog(`Cookie export error: ${e.message}`);
    }
}

// Export cookies on startup and periodically
exportYouTubeCookies();
setInterval(exportYouTubeCookies, 5 * 60 * 1000); // Every 5 minutes

// Overlay disabled - using CDP focus instead
// chrome.tabs.onUpdated.addListener(async (tabId, changeInfo, tab) => {
//     ...
// });
