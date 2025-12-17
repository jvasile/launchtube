// Launch Tube: Pluto TV - Escape to exit, G for Guide
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

    serverLog('Pluto TV script loaded');

    // Attach click listener to Guide button when it appears, then click it
    function attachGuideButtonListener() {
        const guideBtn = Array.from(document.querySelectorAll('button, [role="button"], a'))
            .find(el => el.textContent.trim().toLowerCase() === 'guide');
        if (guideBtn && !guideBtn._launchTubeListener) {
            guideBtn._launchTubeListener = true;
            guideBtn.addEventListener('click', () => {
                serverLog('Guide button clicked');
                maximizeGuide();
            });
            serverLog('Attached listener to Guide button');
            // Auto-click to go straight to guide
            guideBtn.click();
        } else if (!guideBtn) {
            setTimeout(attachGuideButtonListener, 500);
        }
    }
    attachGuideButtonListener();

    let guideObserver = null;
    let hasFocusedProgram = false;

    // Watch for video play and go fullscreen
    function setupVideoFullscreen() {
        const video = document.querySelector('video');
        if (video && !video._launchTubeListener) {
            video._launchTubeListener = true;
            video.addEventListener('play', () => {
                serverLog('Video started playing, requesting fullscreen');
                const player = document.querySelector('[class*="videoPlayerContainer"]') || video;
                if (player.requestFullscreen) {
                    player.requestFullscreen().catch(e => serverLog('Fullscreen error: ' + e));
                } else if (video.requestFullscreen) {
                    video.requestFullscreen().catch(e => serverLog('Fullscreen error: ' + e));
                }
            });
            serverLog('Attached video play listener');
        }
    }

    // When exiting fullscreen, click highlighted program to restore keyboard nav
    document.addEventListener('fullscreenchange', () => {
        if (!document.fullscreenElement) {
            serverLog('Exited fullscreen, restoring keyboard nav');
            // Small delay for DOM to update after fullscreen exit
            setTimeout(() => {
                const currentProgram = document.querySelector('[role="gridcell"][aria-selected="true"] a[tabindex="0"]');
                if (currentProgram) {
                    currentProgram.click();
                    serverLog('Clicked current program after fullscreen exit');
                } else {
                    serverLog('No current program found after fullscreen exit');
                }
            }, 100);
        }
    });

    // If user clicks/enters on a program that's already playing, go fullscreen
    function goFullscreenIfPlaying() {
        const video = document.querySelector('video');
        if (video && !video.paused && !document.fullscreenElement) {
            serverLog('Video already playing, requesting fullscreen');
            const player = document.querySelector('[class*="videoPlayerContainer"]') || video;
            if (player.requestFullscreen) {
                player.requestFullscreen().catch(e => serverLog('Fullscreen error: ' + e));
            }
        }
    }

    // Listen for Enter key on guide to trigger fullscreen for already-playing video (only firstColumn)
    document.addEventListener('keydown', (event) => {
        if (event.key === 'Enter' && !document.fullscreenElement) {
            const active = document.activeElement;
            const gridcell = active?.closest('[role="gridcell"]');
            if (gridcell) {
                const timeline = gridcell.querySelector('[class*="timeline"]');
                const classes = timeline?.className || 'no timeline';
                const hasFirstColumn = classes.includes('firstColumn');
                serverLog(`Enter: activeElement gridcell, firstColumn=${hasFirstColumn}`);
                serverLog(`  classes=${classes.substring(0, 70)}`);
                if (hasFirstColumn) {
                    serverLog('Enter on firstColumn, going fullscreen');
                    setTimeout(goFullscreenIfPlaying, 100);
                }
            } else {
                serverLog(`Enter: activeElement is ${active?.tagName} (not in gridcell)`);
            }
        }
    });

    // Listen for clicks on guide items (only firstColumn - currently playing)
    document.addEventListener('click', (event) => {
        const gridcell = event.target.closest('[role="gridcell"]');
        if (gridcell) {
            const classes = gridcell.querySelector('[class*="timeline"]')?.className || 'no timeline';
            serverLog(`Clicked gridcell, timeline classes: ${classes.substring(0, 80)}`);
        }
        const clickedItem = event.target.closest('.firstColumn');
        if (clickedItem && !document.fullscreenElement) {
            serverLog('Clicked firstColumn, going fullscreen');
            setTimeout(goFullscreenIfPlaying, 100);
        }
    });

    function hidePromoElements() {
        const container = document.querySelector('main [class*="liveTVLayoutContainer"]');
        if (!container) return false;

        let hiddenAny = false;
        Array.from(container.children).forEach((child, i) => {
            if (!child.className || !child.className.includes('liveTVGuideLayoutContainer')) {
                if (child.style.display !== 'none') {
                    child.style.cssText = 'display: none !important';
                    serverLog(`Hidden element [${i}]`);
                    hiddenAny = true;
                }
            }
        });

        const guide = document.querySelector('[class*="liveTVGuideLayoutContainer"]');
        if (guide && !guide.style.height) {
            guide.style.cssText = 'overflow: auto !important; height: calc(100vh - 64px) !important';
            serverLog('Expanded guide');

        }

        // Click the currently selected program in the guide to enable keyboard nav (once)
        if (!hasFocusedProgram) {
            const currentProgram = document.querySelector('[role="gridcell"][aria-selected="true"] a[tabindex="0"]');
            if (currentProgram) {
                currentProgram.click();
                hasFocusedProgram = true;
                serverLog('Clicked current program');
            }
        }

        // Setup video fullscreen listener
        setupVideoFullscreen();

        return hiddenAny;
    }

    function maximizeGuide() {
        hidePromoElements();

        // Watch body for any DOM changes and hide promo elements when they appear
        if (!guideObserver) {
            guideObserver = new MutationObserver(() => {
                hidePromoElements();
            });
            guideObserver.observe(document.body, { childList: true, subtree: true });
            serverLog('Started observing body for promo elements');
        }

        serverLog('Guide maximized');
    }

    function handleKeydown(event) {
        // G key - click Guide button and maximize guide view
        if ((event.key === 'g' || event.key === 'G') && !confirmationElement) {
            const guideBtn = Array.from(document.querySelectorAll('button, [role="button"], a'))
                .find(el => el.textContent.trim().toLowerCase() === 'guide');
            if (guideBtn) {
                serverLog('Clicking Guide button');
                guideBtn.click();
                maximizeGuide();
            }
            return;
        }

        // Escape key - close detail modal if open, otherwise show exit confirmation
        if (event.key === 'Escape' && !confirmationElement) {
            if (document.fullscreenElement) return;

            // Check for detail modal close button
            const closeModal = document.querySelector('.closeModalButton-0-2-452, [class*="closeModalButton"]');
            if (closeModal) {
                event.preventDefault();
                event.stopPropagation();
                closeModal.click();
                serverLog('Closed detail modal');
                return;
            }

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
        confirmationElement._buttons = [cancelBtn, exitBtn];
        confirmationElement._focusIndex = 1; // Start on Exit
        document.body.appendChild(confirmationElement);
        confirmationElement.addEventListener('click', (e) => {
            if (e.target === confirmationElement) hideExitConfirmation();
        });
        document.addEventListener('keydown', handleConfirmKeydown, true);
        exitBtn.focus();
        updateButtonFocus();
    }

    function updateButtonFocus() {
        if (!confirmationElement) return;
        const buttons = confirmationElement._buttons;
        const idx = confirmationElement._focusIndex;
        buttons.forEach((btn, i) => {
            btn.style.outline = i === idx ? '2px solid #fff' : 'none';
            btn.style.outlineOffset = '2px';
        });
        buttons[idx].focus();
    }

    function hideExitConfirmation() {
        document.removeEventListener('keydown', handleConfirmKeydown, true);
        if (confirmationElement) { confirmationElement.remove(); confirmationElement = null; }
    }

    function handleConfirmKeydown(event) {
        event.preventDefault(); event.stopPropagation(); event.stopImmediatePropagation();
        if (event.key === 'Escape') {
            hideExitConfirmation();
        } else if (event.key === 'Enter') {
            const idx = confirmationElement._focusIndex;
            if (idx === 0) hideExitConfirmation();
            else doExit();
        } else if (event.key === 'ArrowLeft' || event.key === 'ArrowRight') {
            confirmationElement._focusIndex = confirmationElement._focusIndex === 0 ? 1 : 0;
            updateButtonFocus();
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

    document.addEventListener('keydown', handleKeydown, true);
})();
