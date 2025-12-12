// Launch Tube: Pluto TV Escape Key Handling
// Allows exiting the app via Escape when not in fullscreen video

(function() {
    'use strict';

    const LAUNCH_TUBE_PORT = window.LAUNCH_TUBE_PORT || 8765;
    const LAUNCH_TUBE_URL = `http://localhost:${LAUNCH_TUBE_PORT}`;

    let confirmationElement = null;

    console.log('Launch Tube: Pluto TV script loaded');

    function handleGlobalEscape(event) {
        if (event.key === 'Escape' && !confirmationElement) {
            // If something is fullscreen (video player), let browser handle it (unfullscreen)
            if (document.fullscreenElement) {
                return;
            }
            // Not in fullscreen - show exit confirmation
            event.preventDefault();
            event.stopPropagation();
            showExitConfirmation();
        }
    }

    function showExitConfirmation() {
        if (confirmationElement) return;

        confirmationElement = document.createElement('div');
        confirmationElement.id = 'launchtube-confirm';
        confirmationElement.innerHTML = `
            <style>
                #launchtube-confirm {
                    position: fixed !important;
                    top: 0 !important;
                    left: 0 !important;
                    right: 0 !important;
                    bottom: 0 !important;
                    background: rgba(0, 0, 0, 0.8) !important;
                    z-index: 2147483647 !important;
                    display: flex !important;
                    align-items: center;
                    justify-content: center;
                }
                #launchtube-confirm .confirm-box {
                    background: #1a1a1a;
                    border: 1px solid #333;
                    border-radius: 8px;
                    padding: 30px 40px;
                    text-align: center;
                    color: #fff;
                    font-family: system-ui, sans-serif;
                }
                #launchtube-confirm .confirm-title {
                    font-size: 20px;
                    margin-bottom: 25px;
                }
                #launchtube-confirm .confirm-buttons {
                    display: flex;
                    gap: 15px;
                    justify-content: center;
                }
                #launchtube-confirm button {
                    padding: 10px 30px;
                    border: none;
                    border-radius: 4px;
                    font-size: 16px;
                    cursor: pointer;
                    transition: background 0.2s;
                }
                #launchtube-confirm .btn-cancel {
                    background: #333;
                    color: #fff;
                }
                #launchtube-confirm .btn-cancel:hover {
                    background: #444;
                }
                #launchtube-confirm .btn-exit {
                    background: #c62828;
                    color: #fff;
                }
                #launchtube-confirm .btn-exit:hover {
                    background: #d32f2f;
                }
            </style>
            <div class="confirm-box">
                <div class="confirm-title">Exit and return to launcher?</div>
                <div class="confirm-buttons">
                    <button class="btn-cancel">Cancel</button>
                    <button class="btn-exit">Exit</button>
                </div>
            </div>
        `;
        document.body.appendChild(confirmationElement);

        const cancelBtn = confirmationElement.querySelector('.btn-cancel');
        const exitBtn = confirmationElement.querySelector('.btn-exit');

        cancelBtn.addEventListener('click', hideExitConfirmation);
        exitBtn.addEventListener('click', doExit);

        document.addEventListener('keydown', handleConfirmKeydown, true);
    }

    function hideExitConfirmation() {
        document.removeEventListener('keydown', handleConfirmKeydown, true);
        if (confirmationElement) {
            confirmationElement.remove();
            confirmationElement = null;
        }
    }

    function handleConfirmKeydown(event) {
        if (event.key === 'Escape' || event.key === 'Enter') {
            event.preventDefault();
            event.stopPropagation();
            event.stopImmediatePropagation();
            doExit();
        }
    }

    function doExit() {
        console.log('[LaunchTube] doExit called');
        hideExitConfirmation();
        if (typeof window.launchTubeCloseTab === 'function') {
            // Use userscript's gmFetch to bypass mixed content blocking (HTTPS -> HTTP)
            window.launchTubeCloseTab();
        } else {
            // Fallback for direct server access (when on localhost origin)
            fetch(`${LAUNCH_TUBE_URL}/api/1/browser/close`, { method: 'POST' })
                .catch(e => console.error('[LaunchTube] Browser close failed:', e));
        }
    }

    function init() {
        console.log('Launch Tube: Initializing Pluto TV escape handler');
        document.addEventListener('keydown', handleGlobalEscape, true);
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }
})();
