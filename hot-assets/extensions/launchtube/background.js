// LaunchTube Loader - Background Service Worker
// Handles fetch requests to localhost (bypasses page CSP)

const VERSION = '2.0';
console.log(`[LaunchTube] Background service worker v${VERSION} loaded`);

chrome.runtime.onMessage.addListener((request, sender, sendResponse) => {
    if (request.type === 'fetch') {
        const { url, options } = request;

        fetch(url, {
            method: options?.method || 'GET',
            headers: options?.headers,
            body: options?.body
        })
        .then(async (response) => {
            const text = await response.text();
            sendResponse({
                ok: response.ok,
                status: response.status,
                text: text
            });
        })
        .catch((error) => {
            sendResponse({
                ok: false,
                error: error.message
            });
        });

        return true; // Keep channel open for async response
    }
});
