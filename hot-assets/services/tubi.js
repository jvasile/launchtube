// Launch Tube: Tubi - Escape to exit
(function() {
    'use strict';
    const LAUNCH_TUBE_PORT = window.LAUNCH_TUBE_PORT || 8765;
    let confirmationElement = null;

    function serverLog(message) {
        console.log(`[LaunchTube] ${message}`);
        if (typeof window.launchTubeLog === 'function') {
            window.launchTubeLog(message, 'info');
        }
    }

    serverLog('Tubi script loaded');

    function handleGlobalEscape(event) {
        if (event.key === 'Escape' && !confirmationElement) {
            if (document.fullscreenElement) return;
            event.preventDefault();
            event.stopPropagation();
            showExitConfirmation();
        }
    }

    function showExitConfirmation() {
        if (confirmationElement) return;

        confirmationElement = document.createElement('div');
        confirmationElement.id = 'launchtube-confirm';
        Object.assign(confirmationElement.style, {
            position: 'fixed', top: '0', left: '0', right: '0', bottom: '0',
            background: 'rgba(0,0,0,0.8)', zIndex: '2147483647',
            display: 'flex', alignItems: 'center', justifyContent: 'center'
        });

        const box = document.createElement('div');
        Object.assign(box.style, {
            background: '#1a1a1a', border: '1px solid #333', borderRadius: '8px',
            padding: '30px 40px', textAlign: 'center', color: '#fff', fontFamily: 'system-ui, sans-serif'
        });

        const title = document.createElement('div');
        title.textContent = 'Exit and return to launcher?';
        Object.assign(title.style, { fontSize: '20px', marginBottom: '25px' });

        const buttons = document.createElement('div');
        Object.assign(buttons.style, { display: 'flex', gap: '15px', justifyContent: 'center' });

        const cancelBtn = document.createElement('button');
        cancelBtn.textContent = 'Cancel';
        Object.assign(cancelBtn.style, {
            padding: '10px 30px', border: 'none', borderRadius: '4px',
            fontSize: '16px', cursor: 'pointer', background: '#333', color: '#fff'
        });
        cancelBtn.addEventListener('click', hideExitConfirmation);

        const exitBtn = document.createElement('button');
        exitBtn.textContent = 'Exit';
        Object.assign(exitBtn.style, {
            padding: '10px 30px', border: 'none', borderRadius: '4px',
            fontSize: '16px', cursor: 'pointer', background: '#c62828', color: '#fff'
        });
        exitBtn.addEventListener('click', doExit);

        buttons.appendChild(cancelBtn);
        buttons.appendChild(exitBtn);
        box.appendChild(title);
        box.appendChild(buttons);
        confirmationElement.appendChild(box);
        document.body.appendChild(confirmationElement);
        document.addEventListener('keydown', handleConfirmKeydown, true);
    }

    function hideExitConfirmation() {
        document.removeEventListener('keydown', handleConfirmKeydown, true);
        if (confirmationElement) { confirmationElement.remove(); confirmationElement = null; }
    }

    function handleConfirmKeydown(event) {
        if (event.key === 'Escape' || event.key === 'Enter') {
            event.preventDefault(); event.stopPropagation(); event.stopImmediatePropagation();
            doExit();
        }
    }

    function doExit() {
        hideExitConfirmation();
        if (typeof window.launchTubeCloseTab === 'function') {
            window.launchTubeCloseTab();
        } else {
            fetch(`http://localhost:${LAUNCH_TUBE_PORT}/api/1/browser/close`, { method: 'POST' }).catch(() => {});
        }
    }

    document.addEventListener('keydown', handleGlobalEscape, true);
})();
