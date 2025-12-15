import './style.css';
import { GetProfiles, GetApps, GetBrowsers, LaunchApp, Quit, SaveApps, GetServerPort, GetVersion, CreateProfile, UpdateProfile, DeleteProfile, GetProfilePhotos, GetLogoPath, LaunchBrowserAdmin, GetMpvPaths, GetSelectedMpv, SetSelectedMpv, GetMpvOptions, SetMpvOptions, CloseBrowser } from '../wailsjs/go/main/App';

// State
let currentProfile = null;
let profiles = [];
let apps = [];
let browsers = [];
let serviceLibrary = [];
let profilePhotos = [];
let logoPath = '';
let selectedBrowser = null;
let serverPort = 8765;
let editMode = false;
let manageProfilesMode = false;
let editingProfile = null; // null = selecting, 'new' = creating, or profile object = editing
let currentScreen = 'loading'; // loading, profiles, launcher, library, profileEdit
let moveMode = false; // For reordering apps with M key
let profileMoveMode = false; // For reordering profiles with M key
let keyboardMode = false; // Track if using keyboard navigation

// On-screen keyboard settings
let oskEnabled = localStorage.getItem('oskEnabled') !== 'false'; // Default enabled
let oskLayout = localStorage.getItem('oskLayout') || 'qwerty'; // 'qwerty' or 'alpha'
let oskFullKeyboard = localStorage.getItem('oskFullKeyboard') === 'true'; // Full keyboard with all symbols
let oskIsOpen = false; // Track if OSK is currently open

// Color palette
const colors = [
  { name: 'Black', value: 0xFF000000 },
  { name: 'White', value: 0xFFFFFFFF },
  { name: 'Red', value: 0xFFE50914 },
  { name: 'Blue', value: 0xFF00A4DC },
  { name: 'Yellow', value: 0xFFFFD000 },
  { name: 'Pink', value: 0xFFE91E63 },
  { name: 'Green', value: 0xFF4CAF50 },
  { name: 'Purple', value: 0xFF9C27B0 },
  { name: 'Orange', value: 0xFFFF5722 },
  { name: 'Cyan', value: 0xFF00BCD4 },
];

// Initialize
async function init() {
  render('<div class="loading">Loading...</div>');

  try {
    serverPort = await GetServerPort();
    profiles = await GetProfiles();
    browsers = await GetBrowsers();
    profilePhotos = await GetProfilePhotos();
    logoPath = await GetLogoPath();
    selectedBrowser = localStorage.getItem('selectedBrowser') || (browsers.length > 0 ? browsers[0].name : null);

    // Load service library
    const res = await fetch(`http://localhost:${serverPort}/api/1/services`);
    serviceLibrary = await res.json();

    if (profiles.length === 0) {
      // No profiles - show create profile screen
      showProfileEdit('new');
    } else if (profiles.length === 1) {
      currentProfile = profiles[0];
      showLauncher();
    } else {
      showProfileSelector();
    }
  } catch (err) {
    console.error('Init error:', err);
    render(`<div class="loading">Error: ${err}</div>`);
  }
}

function render(html) {
  document.querySelector('#app').innerHTML = html;
}

function imageUrl(path) {
  if (!path) return '';
  return `http://localhost:${serverPort}/api/1/image?path=${encodeURIComponent(path)}`;
}

function intToColor(value) {
  if (!value) return '#333333';
  const hex = (value & 0xFFFFFF).toString(16).padStart(6, '0');
  return '#' + hex;
}

// ========== PROFILE SELECTOR ==========
function showProfileSelector() {
  currentScreen = 'profiles';
  const html = `
    <div class="profile-screen">
      <img src="${imageUrl(logoPath)}" alt="LaunchTube" class="profile-logo">
      <h1>Who's watching?</h1>
      <div class="profile-grid">
        ${profiles.map((p, i) => `
          <div class="profile-tile" tabindex="0" data-index="${i}">
            <div class="profile-avatar-wrapper">
              <div class="profile-avatar" style="background-color: ${intToColor(p.colorValue)}">
                ${p.photoPath ? `<img src="${imageUrl(p.photoPath)}" alt="">` : p.displayName.charAt(0).toUpperCase()}
              </div>
              <button class="profile-edit-btn" data-edit="${i}" tabindex="-1">⚙</button>
            </div>
            <div class="profile-name">${escapeHtml(p.displayName)}</div>
          </div>
        `).join('')}
        <div class="profile-tile add-user-tile" tabindex="0" data-action="add">
          <div class="profile-avatar-wrapper">
            <div class="profile-avatar add-avatar">+</div>
          </div>
          <div class="profile-name">Add User</div>
        </div>
      </div>
    </div>
  `;
  render(html);

  // Bind events - profile tiles select profile
  document.querySelectorAll('.profile-tile').forEach((tile) => {
    const idx = tile.dataset.index !== undefined ? parseInt(tile.dataset.index) : -1;
    const action = tile.dataset.action;

    tile.addEventListener('click', (e) => {
      // Don't select if clicking the edit button
      if (e.target.closest('.profile-edit-btn')) return;

      if (action === 'add') {
        showProfileEdit('new');
      } else {
        selectProfile(idx);
      }
    });
    tile.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') {
        if (profileMoveMode) {
          // Exit move mode, don't select
          e.preventDefault();
          profileMoveMode = false;
          updateProfileMoveIndicator();
          return;
        }
        if (action === 'add') {
          showProfileEdit('new');
        } else {
          selectProfile(idx);
        }
      }
    });
  });

  // Edit buttons
  document.querySelectorAll('.profile-edit-btn').forEach(btn => {
    btn.addEventListener('click', (e) => {
      e.stopPropagation();
      const idx = parseInt(btn.dataset.edit);
      showProfileEdit(profiles[idx]);
    });
  });

  const firstTile = document.querySelector('.profile-tile');
  if (firstTile) firstTile.focus();

  document.removeEventListener('keydown', globalKeyHandler);
  document.addEventListener('keydown', profileKeyHandler);
}

function profileKeyHandler(e) {
  const tiles = Array.from(document.querySelectorAll('.profile-tile'));
  if (tiles.length === 0) return;

  let idx = tiles.findIndex(t => t === document.activeElement);
  if (idx === -1) idx = 0;

  const isAddTile = tiles[idx]?.classList.contains('add-user-tile');

  // Profile move mode
  if (profileMoveMode && !isAddTile && idx < profiles.length) {
    if (e.key === 'ArrowLeft' && idx > 0) {
      e.preventDefault();
      [profiles[idx - 1], profiles[idx]] = [profiles[idx], profiles[idx - 1]];
      saveProfileOrder();
      showProfileSelector();
      setTimeout(() => {
        const newTiles = document.querySelectorAll('.profile-tile');
        newTiles[idx - 1]?.focus();
      }, 50);
      return;
    } else if (e.key === 'ArrowRight' && idx < profiles.length - 1) {
      e.preventDefault();
      [profiles[idx], profiles[idx + 1]] = [profiles[idx + 1], profiles[idx]];
      saveProfileOrder();
      showProfileSelector();
      setTimeout(() => {
        const newTiles = document.querySelectorAll('.profile-tile');
        newTiles[idx + 1]?.focus();
      }, 50);
      return;
    } else if (e.key === 'Escape' || e.key === 'Enter') {
      e.preventDefault();
      e.stopPropagation();
      profileMoveMode = false;
      updateProfileMoveIndicator();
      return;
    }
  }

  // Navigation
  if (e.key === 'ArrowLeft') { e.preventDefault(); idx = Math.max(0, idx - 1); tiles[idx].focus(); }
  else if (e.key === 'ArrowRight') { e.preventDefault(); idx = Math.min(tiles.length - 1, idx + 1); tiles[idx].focus(); }
  // Add user (+)
  else if (e.key === '+') {
    showProfileEdit('new');
  }
  // Configure user (C)
  else if ((e.key === 'c' || e.key === 'C') && !isAddTile && idx < profiles.length) {
    showProfileEdit(profiles[idx]);
  }
  // Move user (M)
  else if ((e.key === 'm' || e.key === 'M') && !isAddTile && idx < profiles.length) {
    profileMoveMode = !profileMoveMode;
    updateProfileMoveIndicator();
  }
  // Delete user (Delete) - only if more than one profile
  else if ((e.key === 'Delete' || e.key === 'Backspace') && !isAddTile && idx < profiles.length && profiles.length > 1) {
    e.preventDefault();
    (async () => {
      if (await showConfirmDialog(`Delete "${profiles[idx].displayName}" and all their data?`)) {
        await DeleteProfile(profiles[idx].id);
        profiles = await GetProfiles();
        showProfileSelector();
      }
    })();
  }
  // Help (?)
  else if (e.key === '?') {
    showProfileHelpDialog();
  }
  // Escape
  else if (e.key === 'Escape') {
    if (profileMoveMode) {
      profileMoveMode = false;
      updateProfileMoveIndicator();
    } else if (profiles.length === 1) {
      selectProfile(0);
    }
  }
  // Ctrl+Q - Quit app
  else if (e.ctrlKey && !e.shiftKey && (e.key === 'q' || e.key === 'Q')) {
    e.preventDefault();
    Quit();
  }
}

function updateProfileMoveIndicator() {
  const tiles = document.querySelectorAll('.profile-tile:not(.add-user-tile)');
  tiles.forEach(tile => {
    if (profileMoveMode) {
      tile.classList.add('move-mode');
    } else {
      tile.classList.remove('move-mode');
    }
  });
}

async function saveProfileOrder() {
  for (let i = 0; i < profiles.length; i++) {
    profiles[i].order = i;
    await UpdateProfile(profiles[i].id, profiles[i].displayName, profiles[i].colorValue, profiles[i].photoPath || '', i);
  }
}

function selectProfile(index) {
  document.removeEventListener('keydown', profileKeyHandler);
  currentProfile = profiles[index];
  showLauncher();
}

// ========== PROFILE EDIT DIALOG ==========
function showProfileEdit(profile) {
  editingProfile = profile;

  const isNew = profile === 'new';
  const title = isNew ? 'Add User' : 'Configure User';
  const name = isNew ? '' : profile.displayName;
  const colorValue = isNew ? colors[Math.floor(Math.random() * colors.length)].value : profile.colorValue;
  const photoPath = isNew ? '' : (profile.photoPath || '');

  // Create modal overlay
  const overlay = document.createElement('div');
  overlay.className = 'dialog-overlay';
  overlay.innerHTML = `
    <div class="dialog" id="profileDialog">
      <div class="dialog-title">${title}</div>

      <div class="dialog-field">
        <input type="text" id="profileName" class="dialog-input" value="${escapeHtml(name)}" placeholder="Name" maxlength="20">
      </div>

      <div class="avatar-pickers">
        ${profilePhotos.length > 0 ? `
          <div class="avatar-picker" id="photoPicker" tabindex="0">
            <div class="avatar-circle photo-circle" id="photoPreview">
              ${photoPath ? `<img src="${imageUrl(photoPath)}" alt="">` : '<span class="photo-icon">📷</span>'}
            </div>
            <div class="avatar-label">
              <span>Photo</span>
              ${photoPath ? '<span class="check">✓</span>' : ''}
            </div>
          </div>
        ` : ''}
        <div class="avatar-picker" id="colorPicker" tabindex="0">
          <div class="avatar-circle color-circle" id="colorPreview" style="background-color: ${intToColor(colorValue)}">
            <span id="colorInitial">${name ? name.charAt(0).toUpperCase() : '?'}</span>
          </div>
          <div class="avatar-label">
            <span>Color</span>
            ${!photoPath ? '<span class="check">✓</span>' : ''}
          </div>
        </div>
      </div>

      <div class="dialog-buttons">
        ${!isNew && profiles.length > 1 ? `
          <button class="dialog-btn delete-btn" id="deleteBtn">Delete</button>
        ` : ''}
        <div class="dialog-spacer"></div>
        <button class="dialog-btn" id="cancelBtn">Cancel</button>
        <button class="dialog-btn primary-btn" id="saveBtn">${isNew ? 'Add' : 'Save'}</button>
      </div>
    </div>
  `;

  document.body.appendChild(overlay);

  // State
  let selectedColor = colorValue;
  let selectedPhoto = photoPath;

  function updatePreviews() {
    const nameVal = document.getElementById('profileName').value.trim();
    const colorPreview = document.getElementById('colorPreview');
    const colorInitial = document.getElementById('colorInitial');
    const photoPreview = document.getElementById('photoPreview');

    colorPreview.style.backgroundColor = intToColor(selectedColor);
    colorInitial.textContent = nameVal ? nameVal.charAt(0).toUpperCase() : '?';

    if (photoPreview) {
      if (selectedPhoto) {
        photoPreview.innerHTML = `<img src="${imageUrl(selectedPhoto)}" alt="">`;
      } else {
        photoPreview.innerHTML = '<span class="photo-icon">📷</span>';
      }
    }

    // Update check marks
    document.querySelectorAll('.avatar-label .check').forEach(c => c.remove());
    if (selectedPhoto && document.querySelector('#photoPicker .avatar-label')) {
      document.querySelector('#photoPicker .avatar-label').innerHTML = '<span>Photo</span><span class="check">✓</span>';
      document.querySelector('#colorPicker .avatar-label').innerHTML = '<span>Color</span>';
    } else {
      if (document.querySelector('#photoPicker .avatar-label')) {
        document.querySelector('#photoPicker .avatar-label').innerHTML = '<span>Photo</span>';
      }
      document.querySelector('#colorPicker .avatar-label').innerHTML = '<span>Color</span><span class="check">✓</span>';
    }
  }

  // Get all focusable elements in the dialog
  function getFocusableElements() {
    const all = overlay.querySelectorAll('input, button, [tabindex="0"]');
    return Array.from(all).filter(el => el.offsetParent !== null);
  }

  // Capture all keydown events to prevent bubbling to parent handlers
  async function handleDialogKey(e) {
    // Don't handle keys if OSK is open
    if (oskIsOpen) return;

    e.stopPropagation();

    if (e.key === 'Escape') {
      closeDialog();
      return;
    }

    // Handle Enter on text input - show OSK if enabled
    if (e.key === 'Enter' && document.activeElement?.tagName === 'INPUT' && document.activeElement?.type === 'text') {
      if (oskEnabled) {
        e.preventDefault();
        const input = document.activeElement;
        const result = await showOnScreenKeyboard(input);
        input.value = result;
        updatePreviews();
        input.focus();
      }
      return;
    }

    // Arrow key navigation between fields
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      const focusable = getFocusableElements();
      const currentIdx = focusable.indexOf(document.activeElement);

      if (currentIdx !== -1) {
        e.preventDefault();
        let nextIdx;
        if (e.key === 'ArrowDown') {
          nextIdx = currentIdx < focusable.length - 1 ? currentIdx + 1 : 0;
        } else {
          nextIdx = currentIdx > 0 ? currentIdx - 1 : focusable.length - 1;
        }
        focusable[nextIdx].focus();
      }
    }
  }
  document.addEventListener('keydown', handleDialogKey, true);

  function closeDialog() {
    document.removeEventListener('keydown', handleDialogKey, true);
    document.body.removeChild(overlay);
  }

  // Name input
  document.getElementById('profileName').addEventListener('input', updatePreviews);

  // Photo picker
  document.getElementById('photoPicker')?.addEventListener('click', () => {
    showPhotoPicker(selectedPhoto, (photo) => {
      selectedPhoto = photo;
      updatePreviews();
    });
  });

  // Color picker
  document.getElementById('colorPicker').addEventListener('click', () => {
    showColorPicker(selectedColor, (color) => {
      selectedColor = color;
      selectedPhoto = ''; // Clear photo when color is picked
      updatePreviews();
    });
  });

  // Cancel
  document.getElementById('cancelBtn').addEventListener('click', closeDialog);

  // Delete
  document.getElementById('deleteBtn')?.addEventListener('click', async () => {
    closeDialog();
    if (await showConfirmDialog(`Delete "${profile.displayName}" and all their data?`)) {
      try {
        await DeleteProfile(profile.id);
        profiles = await GetProfiles();
        if (profiles.length === 0) {
          showProfileEdit('new');
        } else {
          showProfileSelector();
        }
      } catch (err) {
        alert('Failed to delete: ' + err);
      }
    }
  });

  // Save
  document.getElementById('saveBtn').addEventListener('click', async () => {
    const nameVal = document.getElementById('profileName').value.trim();
    if (!nameVal) return;

    try {
      if (isNew) {
        const newProfile = await CreateProfile(nameVal, selectedColor);
        if (selectedPhoto) {
          await UpdateProfile(newProfile.id, nameVal, selectedColor, selectedPhoto, newProfile.order);
        }
      } else {
        await UpdateProfile(profile.id, nameVal, selectedColor, selectedPhoto, profile.order);
      }
      profiles = await GetProfiles();
      closeDialog();
      showProfileSelector();
    } catch (err) {
      alert('Failed to save: ' + err);
    }
  });

  // Focus name input
  setTimeout(() => document.getElementById('profileName').focus(), 100);
}

// Photo picker dialog
function showPhotoPicker(currentPhoto, onSelect) {
  const overlay = document.createElement('div');
  overlay.className = 'dialog-overlay';
  overlay.innerHTML = `
    <div class="dialog picker-dialog">
      <div class="dialog-title">Select Photo</div>
      <div class="picker-grid">
        ${profilePhotos.map(p => `
          <div class="picker-item ${currentPhoto === p ? 'selected' : ''}" data-photo="${escapeHtml(p)}" tabindex="0">
            <img src="${imageUrl(p)}" alt="">
          </div>
        `).join('')}
      </div>
      <div class="dialog-buttons">
        <div class="dialog-spacer"></div>
        <button class="dialog-btn" id="pickerCancelBtn">Cancel</button>
      </div>
    </div>
  `;

  document.body.appendChild(overlay);

  document.querySelectorAll('.picker-item').forEach(item => {
    item.addEventListener('click', () => {
      onSelect(item.dataset.photo);
      document.body.removeChild(overlay);
    });
  });

  document.getElementById('pickerCancelBtn').addEventListener('click', () => {
    document.body.removeChild(overlay);
  });
}

// Color picker dialog
function showColorPicker(currentColor, onSelect) {
  const overlay = document.createElement('div');
  overlay.className = 'dialog-overlay';
  overlay.innerHTML = `
    <div class="dialog picker-dialog">
      <div class="dialog-title">Select Color</div>
      <div class="picker-grid color-grid">
        ${colors.map(c => `
          <div class="picker-item color-item ${c.value === currentColor ? 'selected' : ''}" data-color="${c.value}" tabindex="0" style="background-color: ${intToColor(c.value)}">
          </div>
        `).join('')}
      </div>
      <div class="dialog-buttons">
        <div class="dialog-spacer"></div>
        <button class="dialog-btn" id="pickerCancelBtn">Cancel</button>
      </div>
    </div>
  `;

  document.body.appendChild(overlay);

  document.querySelectorAll('.picker-item').forEach(item => {
    item.addEventListener('click', () => {
      onSelect(parseInt(item.dataset.color));
      document.body.removeChild(overlay);
    });
  });

  document.getElementById('pickerCancelBtn').addEventListener('click', () => {
    document.body.removeChild(overlay);
  });
}

// ========== LAUNCHER ==========
async function showLauncher() {
  currentScreen = 'launcher';
  render('<div class="loading">Loading apps...</div>');

  try {
    apps = await GetApps(currentProfile.id) || [];
  } catch (err) {
    console.error('Failed to load apps:', err);
    apps = [];
  }

  renderLauncher();
}

function renderLauncher() {
  moveMode = false;
  const html = `
    <div class="launcher-screen">
      <div class="launcher-header">
        <div class="header-left">
          <button class="menu-btn" id="menuBtn" tabindex="0">☰</button>
        </div>
        <img src="${imageUrl(logoPath)}" alt="LaunchTube" class="header-logo">
        <div class="header-right"></div>
      </div>

      <div class="app-grid" id="appGrid">
        ${apps.map((app, i) => `
          <div class="app-tile"
               tabindex="0"
               data-index="${i}"
               style="background-color: ${intToColor(app.colorValue)}">
            ${app.imagePath ? `<img src="${imageUrl(app.imagePath)}" alt="${escapeHtml(app.name)}">` : ''}
            ${app.showName || !app.imagePath ? `<div class="app-name">${escapeHtml(app.name)}</div>` : ''}
            <button class="app-edit-btn" data-edit="${i}" tabindex="-1">⚙</button>
          </div>
        `).join('')}
        <div class="app-tile add-tile" tabindex="0" data-action="add">
          <span class="add-icon">+</span>
          <div class="app-name">Add App</div>
        </div>
      </div>
    </div>

    <!-- Popup Menu -->
    <div class="popup-menu" id="popupMenu">
      <div class="popup-item" id="settingsBtn" tabindex="-1">
        <span class="popup-icon">&#9881;</span>
        <span>Settings</span>
      </div>
      ${browsers.map((b, i) => `
        <div class="popup-item browser-admin-item" data-browser="${i}" tabindex="-1">
          <span class="popup-icon">&#9874;</span>
          <span>Administer ${escapeHtml(b.name)}</span>
        </div>
      `).join('')}
      <div class="popup-divider"></div>
      <div class="popup-item" id="switchUserBtn" tabindex="-1">
        <span class="popup-icon">&#9679;</span>
        <span>Switch User</span>
      </div>
      <div class="popup-divider"></div>
      <div class="popup-item" id="aboutBtn" tabindex="-1">
        <span class="popup-icon">&#9432;</span>
        <span>About</span>
      </div>
      <div class="popup-item" id="exitBtn" tabindex="-1">
        <span class="popup-icon">&#10006;</span>
        <span>Exit</span>
      </div>
    </div>
    <div class="popup-overlay" id="popupOverlay"></div>
  `;

  render(html);
  bindLauncherEvents();
  setTileGlowColors();

  document.removeEventListener('keydown', profileKeyHandler);
  document.removeEventListener('keydown', globalKeyHandler);
  document.addEventListener('keydown', globalKeyHandler);

  // Focus first app or add button
  const firstApp = document.querySelector('.app-tile');
  const addBtn = document.querySelector('#addAppBtn');
  if (firstApp) firstApp.focus();
  else if (addBtn) addBtn.focus();

  // Load version
  GetVersion().then(v => {
    const el = document.getElementById('versionInfo');
    if (el) el.textContent = `${v.version} (${v.commit})`;
  });
}

function setTileGlowColors() {
  // Set CSS variable for tile glow color based on each tile's background
  document.querySelectorAll('.app-tile:not(.add-tile)').forEach((tile, i) => {
    if (apps[i]) {
      const color = apps[i].colorValue;
      const r = (color >> 16) & 0xFF;
      const g = (color >> 8) & 0xFF;
      const b = color & 0xFF;
      tile.style.setProperty('--tile-glow-color', `rgba(${r}, ${g}, ${b}, 0.6)`);
    }
  });
}

function bindLauncherEvents() {
  // Menu toggle
  const menuBtn = document.getElementById('menuBtn');
  menuBtn?.addEventListener('click', () => togglePopupMenu(true));
  document.getElementById('popupOverlay')?.addEventListener('click', togglePopupMenu);

  // Menu button keyboard navigation
  menuBtn?.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') {
      e.preventDefault();
      togglePopupMenu(true);
    } else if (e.key === 'ArrowDown') {
      e.preventDefault();
      e.stopPropagation();
      const tiles = document.querySelectorAll('.app-tile');
      if (tiles.length > 0) {
        tiles[0].focus();
      }
    }
  });

  // Menu keyboard navigation
  document.getElementById('popupMenu')?.addEventListener('keydown', handleMenuKeydown);

  // Popup menu items
  document.getElementById('settingsBtn')?.addEventListener('click', () => {
    togglePopupMenu();
    showSettingsDialog();
  });
  document.getElementById('switchUserBtn')?.addEventListener('click', () => {
    togglePopupMenu();
    showProfileSelector();
  });
  document.getElementById('aboutBtn')?.addEventListener('click', () => {
    togglePopupMenu();
    showAboutDialog();
  });
  document.getElementById('exitBtn')?.addEventListener('click', () => Quit());

  // Browser admin items
  document.querySelectorAll('.browser-admin-item').forEach(item => {
    item.addEventListener('click', () => {
      const idx = parseInt(item.dataset.browser);
      togglePopupMenu();
      openBrowserAdmin(browsers[idx]);
    });
  });

  // App tiles - click to launch
  document.querySelectorAll('.app-tile:not(.add-tile)').forEach((tile) => {
    const idx = parseInt(tile.dataset.index);
    tile.addEventListener('click', (e) => {
      if (e.target.closest('.app-edit-btn')) return;
      launchAppAt(idx);
    });
  });

  // App edit buttons
  document.querySelectorAll('.app-edit-btn').forEach(btn => {
    btn.addEventListener('click', (e) => {
      e.stopPropagation();
      const idx = parseInt(btn.dataset.edit);
      showAppEditDialog(idx);
    });
  });

  // Add tile
  document.querySelector('.add-tile')?.addEventListener('click', showLibrary);
}

function togglePopupMenu(focusFirst = false) {
  const menu = document.getElementById('popupMenu');
  const overlay = document.getElementById('popupOverlay');
  const isOpen = menu?.classList.contains('open');
  menu?.classList.toggle('open');
  overlay?.classList.toggle('open');

  // Focus first menu item when opening
  if (!isOpen && focusFirst) {
    setTimeout(() => {
      const firstItem = menu?.querySelector('.popup-item');
      firstItem?.focus();
    }, 50);
  }
}

function handleMenuKeydown(e) {
  const menu = document.getElementById('popupMenu');
  if (!menu?.classList.contains('open')) return;

  // Stop all key events from propagating while menu is open
  e.stopPropagation();

  const items = Array.from(menu.querySelectorAll('.popup-item'));
  let idx = items.findIndex(item => item === document.activeElement);

  if (e.key === 'ArrowDown') {
    e.preventDefault();
    idx = idx < items.length - 1 ? idx + 1 : 0;
    items[idx]?.focus();
  } else if (e.key === 'ArrowUp') {
    e.preventDefault();
    idx = idx > 0 ? idx - 1 : items.length - 1;
    items[idx]?.focus();
  } else if (e.key === 'Enter') {
    e.preventDefault();
    document.activeElement?.click();
  } else if (e.key === 'Escape') {
    e.preventDefault();
    togglePopupMenu();
    document.getElementById('menuBtn')?.focus();
  }
}

async function openBrowserAdmin(browser) {
  try {
    await LaunchBrowserAdmin(browser.name);
  } catch (err) {
    alert('Failed to open admin browser: ' + err);
  }
}

async function showSettingsDialog() {
  const mpvPaths = await GetMpvPaths();
  const selectedMpv = await GetSelectedMpv();
  const mpvOptions = await GetMpvOptions();

  const overlay = document.createElement('div');
  overlay.className = 'dialog-overlay';
  overlay.innerHTML = `
    <div class="dialog settings-dialog">
      <div class="dialog-title">Settings</div>

      <div class="dialog-section">
        <div class="dialog-section-title">Browser</div>
        ${browsers.map(b => `
          <label class="radio-option">
            <input type="radio" name="browser" value="${escapeHtml(b.name)}" ${b.name === selectedBrowser ? 'checked' : ''}>
            <span>${escapeHtml(b.name)} (${escapeHtml(b.executable)})</span>
          </label>
        `).join('')}
      </div>

      <div class="dialog-section">
        <div class="dialog-section-title">Media Player (mpv)</div>
        ${mpvPaths.length === 0 ? '<div class="dialog-note">No mpv found</div>' : mpvPaths.map(p => `
          <label class="radio-option">
            <input type="radio" name="mpv" value="${escapeHtml(p)}" ${p === selectedMpv ? 'checked' : ''}>
            <span>${escapeHtml(p)}</span>
          </label>
        `).join('')}
        <div class="dialog-field" style="margin-top: 12px;">
          <label>Custom mpv path</label>
          <input type="text" id="mpvCustomPath" class="dialog-input" value="${mpvPaths.includes(selectedMpv) ? '' : escapeHtml(selectedMpv)}" placeholder="/path/to/mpv">
        </div>
        <div class="dialog-field">
          <label>mpv options</label>
          <input type="text" id="mpvOptionsInput" class="dialog-input" value="${escapeHtml(mpvOptions)}" placeholder="--vo=gpu --hwdec=auto">
        </div>
      </div>

      <div class="dialog-section">
        <div class="dialog-section-title">On-Screen Keyboard</div>
        <label class="checkbox-option">
          <input type="checkbox" id="oskEnabledCheck" ${oskEnabled ? 'checked' : ''}>
          <span>Enable on-screen keyboard for text input</span>
        </label>
      </div>

      <div class="dialog-buttons">
        <div class="dialog-spacer"></div>
        <button class="dialog-btn primary-btn" id="settingsCloseBtn">Close</button>
      </div>
    </div>
  `;
  document.body.appendChild(overlay);

  // Browser selection
  document.querySelectorAll('input[name="browser"]').forEach(radio => {
    radio.addEventListener('change', (e) => {
      selectedBrowser = e.target.value;
      localStorage.setItem('selectedBrowser', selectedBrowser);
    });
  });

  // MPV selection
  document.querySelectorAll('input[name="mpv"]').forEach(radio => {
    radio.addEventListener('change', (e) => {
      SetSelectedMpv(e.target.value);
      document.getElementById('mpvCustomPath').value = '';
    });
  });

  // Custom MPV path
  document.getElementById('mpvCustomPath').addEventListener('change', (e) => {
    const val = e.target.value.trim();
    if (val) {
      SetSelectedMpv(val);
      document.querySelectorAll('input[name="mpv"]').forEach(r => r.checked = false);
    }
  });

  // MPV options
  document.getElementById('mpvOptionsInput').addEventListener('change', (e) => {
    SetMpvOptions(e.target.value);
  });

  // OSK enabled
  document.getElementById('oskEnabledCheck').addEventListener('change', (e) => {
    oskEnabled = e.target.checked;
    localStorage.setItem('oskEnabled', oskEnabled);
  });

  function closeSettings() {
    document.removeEventListener('keydown', handleSettingsKey, true);
    document.body.removeChild(overlay);
  }

  function handleSettingsKey(e) {
    e.stopPropagation();
    if (e.key === 'Escape' || e.key === 'Enter') {
      e.preventDefault();
      closeSettings();
    }
  }
  document.addEventListener('keydown', handleSettingsKey, true);

  document.getElementById('settingsCloseBtn').addEventListener('click', closeSettings);

  // Click outside dialog to close
  overlay.addEventListener('click', (e) => {
    if (e.target === overlay) {
      closeSettings();
    }
  });
}

function showAboutDialog() {
  GetVersion().then(v => {
    const overlay = document.createElement('div');
    overlay.className = 'dialog-overlay';
    overlay.innerHTML = `
      <div class="dialog">
        <div class="dialog-title">About LaunchTube</div>
        <p style="color: white; margin-bottom: 16px;">Version ${v.version} (${v.commit})</p>
        <p style="color: rgba(255,255,255,0.7);">Build: ${v.build}</p>
        <div class="dialog-buttons">
          <div class="dialog-spacer"></div>
          <button class="dialog-btn primary-btn" id="aboutCloseBtn">Close</button>
        </div>
      </div>
    `;
    document.body.appendChild(overlay);
    document.getElementById('aboutCloseBtn').addEventListener('click', () => {
      document.body.removeChild(overlay);
    });
  });
}

function showAppEditDialog(index) {
  const app = apps[index];
  const isNew = false;

  const overlay = document.createElement('div');
  overlay.className = 'dialog-overlay';
  overlay.innerHTML = `
    <div class="dialog app-dialog">
      <div class="dialog-title">Configure App</div>

      <div class="dialog-field">
        <label>Name</label>
        <input type="text" id="appName" class="dialog-input" value="${escapeHtml(app.name)}" placeholder="App name">
      </div>

      <div class="dialog-field">
        <label>Type</label>
        <select id="appType" class="dialog-select">
          <option value="0" ${app.type === 0 ? 'selected' : ''}>Website</option>
          <option value="1" ${app.type === 1 ? 'selected' : ''}>Native App</option>
        </select>
      </div>

      <div class="dialog-field website-field" ${app.type !== 0 ? 'style="display:none"' : ''}>
        <label>URL</label>
        <input type="text" id="appUrl" class="dialog-input" value="${escapeHtml(app.url || '')}" placeholder="https://...">
      </div>

      <div class="dialog-field website-field" ${app.type !== 0 ? 'style="display:none"' : ''}>
        <label>Match URLs (one per line)</label>
        <textarea id="appMatchUrls" class="dialog-input dialog-textarea" placeholder="Additional URLs to match">${escapeHtml((app.matchUrls || []).join('\n'))}</textarea>
      </div>

      <div class="dialog-field native-field" ${app.type !== 1 ? 'style="display:none"' : ''}>
        <label>Command Line</label>
        <input type="text" id="appCommandLine" class="dialog-input" value="${escapeHtml(app.commandLine || '')}" placeholder="/path/to/app">
      </div>

      <div class="dialog-field">
        <label>Image Path</label>
        <input type="text" id="appImagePath" class="dialog-input" value="${escapeHtml(app.imagePath || '')}" placeholder="/path/to/image.png">
      </div>

      <div class="dialog-field">
        <label>Color</label>
        <div class="color-preview-row">
          <div id="appColorPreview" class="color-preview" style="background-color: ${intToColor(app.colorValue)}"></div>
          <button class="dialog-btn" id="pickColorBtn">Pick Color</button>
        </div>
      </div>

      <div class="dialog-field checkbox-field">
        <label>
          <input type="checkbox" id="appShowName" ${app.showName ? 'checked' : ''}>
          Show name on tile
        </label>
      </div>

      <div class="dialog-buttons">
        <button class="dialog-btn delete-btn" id="appDeleteBtn">Delete</button>
        <div class="dialog-spacer"></div>
        <button class="dialog-btn" id="appCancelBtn">Cancel</button>
        <button class="dialog-btn primary-btn" id="appSaveBtn">Save</button>
      </div>
    </div>
  `;

  document.body.appendChild(overlay);

  let selectedColor = app.colorValue;

  // Get all visible focusable elements in the dialog
  function getFocusableElements() {
    const all = overlay.querySelectorAll('input, select, textarea, button');
    return Array.from(all).filter(el => {
      // Check if element or its parent field is visible
      const field = el.closest('.dialog-field');
      if (field && field.style.display === 'none') return false;
      return el.offsetParent !== null;
    });
  }

  // Capture all keydown events to prevent bubbling to parent handlers
  async function handleDialogKey(e) {
    // Don't handle keys if OSK is open
    if (oskIsOpen) return;

    e.stopPropagation();

    if (e.key === 'Escape') {
      closeDialog();
      return;
    }

    // Handle Enter on text input - show OSK if enabled
    if (e.key === 'Enter' && document.activeElement?.tagName === 'INPUT' && document.activeElement?.type === 'text') {
      if (oskEnabled) {
        e.preventDefault();
        const input = document.activeElement;
        const result = await showOnScreenKeyboard(input);
        input.value = result;
        input.focus();
      }
      return;
    }

    // Arrow key navigation between fields
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      const focusable = getFocusableElements();
      const currentIdx = focusable.indexOf(document.activeElement);

      if (currentIdx !== -1) {
        e.preventDefault();
        let nextIdx;
        if (e.key === 'ArrowDown') {
          nextIdx = currentIdx < focusable.length - 1 ? currentIdx + 1 : 0;
        } else {
          nextIdx = currentIdx > 0 ? currentIdx - 1 : focusable.length - 1;
        }
        focusable[nextIdx].focus();
      }
    }
  }
  document.addEventListener('keydown', handleDialogKey, true);

  function closeDialog() {
    document.removeEventListener('keydown', handleDialogKey, true);
    document.body.removeChild(overlay);
  }

  // Focus first input
  setTimeout(() => document.getElementById('appName').focus(), 50);

  // Type change handler
  document.getElementById('appType').addEventListener('change', (e) => {
    const isWebsite = e.target.value === '0';
    document.querySelectorAll('.website-field').forEach(f => f.style.display = isWebsite ? '' : 'none');
    document.querySelectorAll('.native-field').forEach(f => f.style.display = isWebsite ? 'none' : '');
  });

  // Color picker
  document.getElementById('pickColorBtn').addEventListener('click', () => {
    showColorPicker(selectedColor, (color) => {
      selectedColor = color;
      document.getElementById('appColorPreview').style.backgroundColor = intToColor(color);
    });
  });

  // Delete
  document.getElementById('appDeleteBtn').addEventListener('click', async () => {
    if (await showConfirmDialog(`Delete "${app.name}"?`)) {
      apps.splice(index, 1);
      saveApps();
      closeDialog();
      renderLauncher();
    }
  });

  // Cancel
  document.getElementById('appCancelBtn').addEventListener('click', () => {
    closeDialog();
  });

  // Save
  document.getElementById('appSaveBtn').addEventListener('click', async () => {
    const name = document.getElementById('appName').value.trim();
    if (!name) {
      alert('Name is required');
      return;
    }

    const type = parseInt(document.getElementById('appType').value);

    if (type === 0 && !document.getElementById('appUrl').value.trim()) {
      alert('URL is required for websites');
      return;
    }

    if (type === 1 && !document.getElementById('appCommandLine').value.trim()) {
      alert('Command line is required for native apps');
      return;
    }

    app.name = name;
    app.type = type;
    app.url = type === 0 ? document.getElementById('appUrl').value.trim() : null;
    const matchUrlsText = document.getElementById('appMatchUrls').value.trim();
    app.matchUrls = type === 0 && matchUrlsText ? matchUrlsText.split('\n').map(s => s.trim()).filter(s => s) : null;
    app.commandLine = type === 1 ? document.getElementById('appCommandLine').value.trim() : null;
    app.imagePath = document.getElementById('appImagePath').value.trim() || null;
    app.colorValue = selectedColor;
    app.showName = document.getElementById('appShowName').checked;

    await saveApps();
    closeDialog();
    renderLauncher();
  });
}

function toggleMenu() {
  const menu = document.getElementById('sideMenu');
  const overlay = document.getElementById('menuOverlay');
  menu?.classList.toggle('open');
  overlay?.classList.toggle('open');
}

function getGridColumns(grid) {
  if (!grid) return 1;
  // Get actual column count from CSS grid
  const gridStyle = window.getComputedStyle(grid);
  const columns = gridStyle.getPropertyValue('grid-template-columns').split(' ').length;
  return Math.max(1, columns);
}

function globalKeyHandler(e) {
  // Let popup menu handle its own navigation when open
  const popupMenu = document.getElementById('popupMenu');
  if (popupMenu?.classList.contains('open')) {
    // Menu handles its own keys via handleMenuKeydown
    return;
  }

  // Don't handle arrow navigation when menu button is focused (it has its own handler)
  // But still allow Ctrl+Q etc.
  if (document.activeElement?.id === 'menuBtn' && ['ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight', 'Enter'].includes(e.key)) {
    return;
  }

  // Library screen
  if (currentScreen === 'library') {
    if (e.key === 'Escape') {
      showLauncher();
      return;
    }
  }

  if (currentScreen !== 'launcher') return;

  const tiles = Array.from(document.querySelectorAll('.app-tile'));
  if (tiles.length === 0) return;

  const grid = document.getElementById('appGrid');
  if (!grid) return;

  let idx = tiles.findIndex(t => t === document.activeElement);
  if (idx === -1) idx = 0;

  // Calculate actual columns from CSS grid
  const cols = getGridColumns(grid);
  const isAddTile = tiles[idx]?.classList.contains('add-tile');

  // Move mode navigation
  if (moveMode && !isAddTile && idx < apps.length) {
    if (e.key === 'ArrowLeft' && idx > 0) {
      e.preventDefault();
      [apps[idx - 1], apps[idx]] = [apps[idx], apps[idx - 1]];
      saveApps();
      renderLauncher();
      document.querySelectorAll('.app-tile')[idx - 1]?.focus();
      return;
    } else if (e.key === 'ArrowRight' && idx < apps.length - 1) {
      e.preventDefault();
      [apps[idx], apps[idx + 1]] = [apps[idx + 1], apps[idx]];
      saveApps();
      renderLauncher();
      document.querySelectorAll('.app-tile')[idx + 1]?.focus();
      return;
    } else if (e.key === 'Escape' || e.key === 'Enter') {
      e.preventDefault();
      e.stopPropagation();
      moveMode = false;
      updateMoveIndicator();
      return;
    }
  }

  // Navigation
  if (e.key === 'ArrowLeft') { e.preventDefault(); idx = Math.max(0, idx - 1); tiles[idx].focus(); }
  else if (e.key === 'ArrowRight') { e.preventDefault(); idx = Math.min(tiles.length - 1, idx + 1); tiles[idx].focus(); }
  else if (e.key === 'ArrowUp') {
    e.preventDefault();
    const newIdx = idx - cols;
    if (newIdx < 0) {
      // Top row - navigate to menu button
      document.getElementById('menuBtn')?.focus();
    } else {
      idx = newIdx;
      tiles[idx].focus();
    }
  }
  else if (e.key === 'ArrowDown') { e.preventDefault(); idx = Math.min(tiles.length - 1, idx + cols); tiles[idx].focus(); }
  // Launch
  else if (e.key === 'Enter') {
    if (isAddTile) {
      showLibrary();
    } else if (idx < apps.length) {
      launchAppAt(idx);
    }
  }
  // Add app (+)
  else if (e.key === '+' || e.key === '=') {
    if (e.key === '=' && !e.shiftKey) {
      togglePopupMenu();
    } else {
      showLibrary();
    }
  }
  // Configure app (C)
  else if (e.key === 'c' || e.key === 'C') {
    if (!isAddTile && idx < apps.length) {
      showAppEditDialog(idx);
    }
  }
  // Move mode (M)
  else if (e.key === 'm' || e.key === 'M') {
    if (!isAddTile && idx < apps.length) {
      moveMode = !moveMode;
      updateMoveIndicator();
    }
  }
  // Delete app (Delete)
  else if (e.key === 'Delete' || e.key === 'Backspace') {
    if (!isAddTile && idx < apps.length) {
      e.preventDefault();
      (async () => {
        if (await showConfirmDialog(`Delete "${apps[idx].name}"?`)) {
          apps.splice(idx, 1);
          saveApps();
          renderLauncher();
        }
      })();
    }
  }
  // Switch user (U)
  else if (e.key === 'u' || e.key === 'U') {
    if (!moveMode) {
      showProfileSelector();
    }
  }
  // Escape - cancel move mode if active, otherwise do nothing from app grid
  else if (e.key === 'Escape') {
    if (moveMode) {
      moveMode = false;
      updateMoveIndicator();
    }
    // Do nothing if already in app grid - user must use U to switch users
  }
  // Help (?)
  else if (e.key === '?') {
    showHelpDialog();
  }
  // Ctrl+Shift+R - Restart app (close browser)
  else if (e.ctrlKey && e.shiftKey && (e.key === 'r' || e.key === 'R')) {
    e.preventDefault();
    CloseBrowser();
  }
  // Ctrl+Q - Quit app
  else if (e.ctrlKey && !e.shiftKey && (e.key === 'q' || e.key === 'Q')) {
    e.preventDefault();
    Quit();
  }
}

function updateMoveIndicator() {
  const tiles = document.querySelectorAll('.app-tile:not(.add-tile)');
  tiles.forEach(tile => {
    if (moveMode) {
      tile.classList.add('move-mode');
    } else {
      tile.classList.remove('move-mode');
    }
  });
}

function showHelpDialog() {
  const overlay = document.createElement('div');
  overlay.className = 'dialog-overlay';
  overlay.innerHTML = `
    <div class="dialog">
      <div class="dialog-title">Keyboard Shortcuts</div>
      <div class="help-list">
        <div class="help-row"><span class="help-key">Arrow Keys</span><span>Navigate</span></div>
        <div class="help-row"><span class="help-key">Enter</span><span>Launch app</span></div>
        <div class="help-row"><span class="help-key">+</span><span>Add app</span></div>
        <div class="help-row"><span class="help-key">C</span><span>Configure app</span></div>
        <div class="help-row"><span class="help-key">M</span><span>Move app</span></div>
        <div class="help-row"><span class="help-key">Delete</span><span>Delete app</span></div>
        <div class="help-row"><span class="help-key">U</span><span>Switch user</span></div>
        <div class="help-row"><span class="help-key">=</span><span>Open menu</span></div>
        <div class="help-row"><span class="help-key">Escape</span><span>Cancel</span></div>
        <div class="help-row"><span class="help-key">Ctrl+Shift+R</span><span>Restart app</span></div>
        <div class="help-row"><span class="help-key">Ctrl+Q</span><span>Quit app</span></div>
        <div class="help-row"><span class="help-key">?</span><span>Show this help</span></div>
      </div>
      <div class="dialog-buttons">
        <div class="dialog-spacer"></div>
        <button class="dialog-btn primary-btn" id="helpCloseBtn">Close</button>
      </div>
    </div>
  `;
  document.body.appendChild(overlay);
  document.getElementById('helpCloseBtn').addEventListener('click', () => {
    document.body.removeChild(overlay);
  });
  // Close on Escape or Enter or ?
  function closeHelp(e) {
    if (e.key === 'Escape' || e.key === 'Enter' || e.key === '?') {
      document.body.removeChild(overlay);
      document.removeEventListener('keydown', closeHelp);
    }
  }
  document.addEventListener('keydown', closeHelp);
}

function showProfileHelpDialog() {
  const overlay = document.createElement('div');
  overlay.className = 'dialog-overlay';
  overlay.innerHTML = `
    <div class="dialog">
      <div class="dialog-title">Keyboard Shortcuts</div>
      <div class="help-list">
        <div class="help-row"><span class="help-key">Arrow Keys</span><span>Navigate</span></div>
        <div class="help-row"><span class="help-key">Enter</span><span>Select user</span></div>
        <div class="help-row"><span class="help-key">+</span><span>Add user</span></div>
        <div class="help-row"><span class="help-key">C</span><span>Configure user</span></div>
        <div class="help-row"><span class="help-key">M</span><span>Move user</span></div>
        <div class="help-row"><span class="help-key">Delete</span><span>Delete user</span></div>
        <div class="help-row"><span class="help-key">Ctrl+Q</span><span>Quit app</span></div>
        <div class="help-row"><span class="help-key">Escape</span><span>Cancel / Back</span></div>
        <div class="help-row"><span class="help-key">?</span><span>Show this help</span></div>
      </div>
      <div class="dialog-buttons">
        <div class="dialog-spacer"></div>
        <button class="dialog-btn primary-btn" id="helpCloseBtn">Close</button>
      </div>
    </div>
  `;
  document.body.appendChild(overlay);
  document.getElementById('helpCloseBtn').addEventListener('click', () => {
    document.body.removeChild(overlay);
  });
  function closeHelp(e) {
    if (e.key === 'Escape' || e.key === 'Enter' || e.key === '?') {
      document.body.removeChild(overlay);
      document.removeEventListener('keydown', closeHelp);
    }
  }
  document.addEventListener('keydown', closeHelp);
}

async function launchAppAt(index) {
  const app = apps[index];
  if (!app) return;

  try {
    await LaunchApp(app, currentProfile.id, selectedBrowser);
  } catch (err) {
    console.error('Failed to launch app:', err);
    alert('Failed to launch: ' + err);
  }
}

async function handleEditAction(action, index) {
  if (action === 'delete') {
    if (confirm(`Delete "${apps[index].name}"?`)) {
      apps.splice(index, 1);
      await saveApps();
      renderLauncher();
    }
  } else if (action === 'left' && index > 0) {
    [apps[index - 1], apps[index]] = [apps[index], apps[index - 1]];
    await saveApps();
    renderLauncher();
  } else if (action === 'right' && index < apps.length - 1) {
    [apps[index], apps[index + 1]] = [apps[index + 1], apps[index]];
    await saveApps();
    renderLauncher();
  }
}

async function saveApps() {
  try {
    await SaveApps(currentProfile.id, apps);
  } catch (err) {
    console.error('Failed to save apps:', err);
  }
}

// ========== LIBRARY ==========
function showLibrary() {
  currentScreen = 'library';

  // Filter out already added services
  const addedUrls = new Set(apps.map(a => a.url?.toLowerCase()));
  const available = serviceLibrary.filter(s => !addedUrls.has(s.url?.toLowerCase()));

  const html = `
    <div class="library-screen">
      <div class="library-header">
        <button class="back-btn" id="backBtn">← Back</button>
        <h1>Add App</h1>
      </div>
      <div class="library-grid">
        ${available.map((service, i) => `
          <div class="library-tile" tabindex="0" data-index="${i}" style="background-color: ${intToColor(service.colorValue)}">
            ${service.logoPath ? `<img src="${imageUrl(service.logoPath)}" alt="${escapeHtml(service.name)}">` : `<div class="app-name">${escapeHtml(service.name)}</div>`}
          </div>
        `).join('')}
        ${available.length === 0 ? '<p class="no-services">All available services have been added!</p>' : ''}
      </div>
    </div>
  `;

  render(html);

  // Back button
  const backBtn = document.getElementById('backBtn');
  backBtn?.addEventListener('click', showLauncher);
  backBtn?.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') {
      e.preventDefault();
      e.stopPropagation();
      showLauncher();
    } else if (e.key === 'ArrowDown') {
      e.preventDefault();
      e.stopPropagation();
      const tiles = document.querySelectorAll('.library-tile');
      if (tiles.length > 0) {
        tiles[0].focus();
      }
    }
  });

  // Service tiles
  const availableServices = available;
  document.querySelectorAll('.library-tile').forEach((tile) => {
    const idx = parseInt(tile.dataset.index);
    tile.addEventListener('click', () => addService(availableServices[idx]));
    tile.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') addService(availableServices[idx]);
    });
  });

  // Set glow colors for library tiles
  document.querySelectorAll('.library-tile').forEach((tile, i) => {
    if (available[i]) {
      const color = available[i].colorValue;
      const r = (color >> 16) & 0xFF;
      const g = (color >> 8) & 0xFF;
      const b = color & 0xFF;
      tile.style.setProperty('--tile-glow-color', `rgba(${r}, ${g}, ${b}, 0.6)`);
    }
  });

  const firstTile = document.querySelector('.library-tile');
  if (firstTile) firstTile.focus();

  document.removeEventListener('keydown', globalKeyHandler);
  document.addEventListener('keydown', libraryKeyHandler);
}

function libraryKeyHandler(e) {
  // Ctrl+Q - Quit app
  if (e.ctrlKey && !e.shiftKey && (e.key === 'q' || e.key === 'Q')) {
    e.preventDefault();
    Quit();
    return;
  }

  if (e.key === 'Escape' || e.key === 'Backspace') {
    e.preventDefault();
    showLauncher();
    return;
  }

  // Help (?)
  if (e.key === '?') {
    showLibraryHelpDialog();
    return;
  }

  // Don't handle arrow keys when back button is the target (it has its own handler)
  if (e.target?.id === 'backBtn') {
    return;
  }

  const tiles = Array.from(document.querySelectorAll('.library-tile'));
  if (tiles.length === 0) return;

  let idx = tiles.findIndex(t => t === document.activeElement);
  if (idx === -1) idx = 0;

  const grid = document.querySelector('.library-grid');
  const cols = getGridColumns(grid);

  if (e.key === 'ArrowLeft') { e.preventDefault(); idx = Math.max(0, idx - 1); tiles[idx].focus(); }
  else if (e.key === 'ArrowRight') { e.preventDefault(); idx = Math.min(tiles.length - 1, idx + 1); tiles[idx].focus(); }
  else if (e.key === 'ArrowUp') {
    e.preventDefault();
    const newIdx = idx - cols;
    if (newIdx < 0) {
      // Top row - navigate to back button
      document.getElementById('backBtn')?.focus();
    } else {
      idx = newIdx;
      tiles[idx].focus();
    }
  }
  else if (e.key === 'ArrowDown') { e.preventDefault(); idx = Math.min(tiles.length - 1, idx + cols); tiles[idx].focus(); }
}

function showLibraryHelpDialog() {
  const overlay = document.createElement('div');
  overlay.className = 'dialog-overlay';
  overlay.innerHTML = `
    <div class="dialog">
      <div class="dialog-title">Keyboard Shortcuts</div>
      <div class="help-list">
        <div class="help-row"><span class="help-key">Arrow Keys</span><span>Navigate</span></div>
        <div class="help-row"><span class="help-key">Enter</span><span>Add app</span></div>
        <div class="help-row"><span class="help-key">Escape</span><span>Back to launcher</span></div>
        <div class="help-row"><span class="help-key">Ctrl+Q</span><span>Quit app</span></div>
        <div class="help-row"><span class="help-key">?</span><span>Show this help</span></div>
      </div>
      <div class="dialog-buttons">
        <div class="dialog-spacer"></div>
        <button class="dialog-btn primary-btn" id="helpCloseBtn">Close</button>
      </div>
    </div>
  `;
  document.body.appendChild(overlay);
  document.getElementById('helpCloseBtn').addEventListener('click', () => {
    document.body.removeChild(overlay);
  });
  function closeHelp(e) {
    if (e.key === 'Escape' || e.key === 'Enter' || e.key === '?') {
      document.body.removeChild(overlay);
      document.removeEventListener('keydown', closeHelp);
    }
  }
  document.addEventListener('keydown', closeHelp);
}

async function addService(service) {
  const newApp = {
    name: service.name,
    url: service.url,
    matchUrls: service.matchUrls || null,
    commandLine: null,
    type: 0, // website
    imagePath: service.logoPath,
    colorValue: service.colorValue || 0xFF333333,
    showName: !service.logoPath,
  };

  apps.push(newApp);
  await saveApps();

  document.removeEventListener('keydown', libraryKeyHandler);
  // Use renderLauncher directly to avoid race condition with re-fetching
  currentScreen = 'launcher';
  renderLauncher();
}

// ========== UTILITIES ==========
function escapeHtml(str) {
  if (!str) return '';
  return str.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

function showConfirmDialog(message) {
  return new Promise((resolve) => {
    // Save previously focused element to restore later
    const previousFocus = document.activeElement;

    const overlay = document.createElement('div');
    overlay.className = 'dialog-overlay';
    overlay.innerHTML = `
      <div class="dialog confirm-dialog">
        <div class="dialog-title">Confirm</div>
        <p class="confirm-message">${escapeHtml(message)}</p>
        <div class="dialog-buttons">
          <button class="dialog-btn confirm-btn" id="confirmCancel" tabindex="0">Cancel</button>
          <button class="dialog-btn danger-btn confirm-btn" id="confirmOk" tabindex="0">Delete</button>
        </div>
      </div>
    `;
    document.body.appendChild(overlay);

    const cancelBtn = document.getElementById('confirmCancel');
    const okBtn = document.getElementById('confirmOk');
    const buttons = [cancelBtn, okBtn];
    let focusIdx = 0;

    const cleanup = (result) => {
      document.body.removeChild(overlay);
      document.removeEventListener('keydown', handleKey, true);
      // Restore focus to previous element if it still exists in DOM
      if (previousFocus && document.body.contains(previousFocus)) {
        previousFocus.focus();
      } else {
        // Fallback: focus first tile on screen
        const tile = document.querySelector('.app-tile, .profile-tile, .library-tile');
        if (tile) tile.focus();
      }
      resolve(result);
    };

    cancelBtn.addEventListener('click', () => cleanup(false));
    okBtn.addEventListener('click', () => cleanup(true));

    function handleKey(e) {
      // Stop all key events from propagating while dialog is open
      e.stopPropagation();

      if (e.key === 'Escape') {
        e.preventDefault();
        cleanup(false);
      } else if (e.key === 'Enter') {
        e.preventDefault();
        // Confirm whatever button is focused
        cleanup(focusIdx === 1);
      } else if (e.key === 'ArrowLeft' || e.key === 'ArrowRight' || e.key === 'Tab') {
        e.preventDefault();
        focusIdx = focusIdx === 0 ? 1 : 0;
        buttons[focusIdx].focus();
      }
    }
    document.addEventListener('keydown', handleKey, true);

    // Focus cancel button after DOM renders
    setTimeout(() => cancelBtn.focus(), 0);
  });
}

// ========== ON-SCREEN KEYBOARD ==========
function showOnScreenKeyboard(inputElement) {
  return new Promise((resolve) => {
    let currentValue = inputElement.value;
    let shifted = false;
    let showingConfig = false;

    // Keyboard layouts
    const qwertyRows = [
      ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0'],
      ['q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p'],
      ['a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l'],
      ['z', 'x', 'c', 'v', 'b', 'n', 'm']
    ];

    const qwertySymbolRows = [
      ['!', '@', '#', '$', '%', '^', '&', '*', '(', ')'],
      ['`', '~', '-', '_', '=', '+', '[', ']', '{', '}'],
      ['\\', '|', ';', ':', "'", '"', ',', '.', '/'],
      ['<', '>', '?']
    ];

    const alphaRows = [
      ['a', 'b', 'c', 'd', 'e', 'f', 'g'],
      ['h', 'i', 'j', 'k', 'l', 'm', 'n'],
      ['o', 'p', 'q', 'r', 's', 't', 'u'],
      ['v', 'w', 'x', 'y', 'z'],
      ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0']
    ];

    function getRows() {
      if (oskLayout === 'qwerty') {
        return oskFullKeyboard ? [...qwertyRows, ...qwertySymbolRows] : qwertyRows;
      } else {
        return alphaRows;
      }
    }

    function renderKeyboard() {
      const rows = getRows();
      const specialRow = [
        { key: '⇧', action: 'shift', label: 'Shift' },
        { key: '␣', action: 'space', label: 'Space' },
        { key: '⌫', action: 'backspace', label: 'Backspace' },
        { key: '⚙', action: 'config', label: 'Settings' },
        { key: '✗', action: 'cancel', label: 'Cancel', class: 'osk-cancel' },
        { key: '✓', action: 'done', label: 'Done' }
      ];

      return `
        <div class="osk-overlay">
          <div class="osk-container">
            <div class="osk-input-preview">${escapeHtml(currentValue) || '<span class="osk-placeholder">Type here...</span>'}</div>
            <div class="osk-keyboard">
              ${rows.map((row, rowIdx) => `
                <div class="osk-row">
                  ${row.map((key, keyIdx) => `
                    <button class="osk-key" data-key="${escapeHtml(key)}" data-row="${rowIdx}" data-col="${keyIdx}">
                      ${shifted ? key.toUpperCase() : key}
                    </button>
                  `).join('')}
                </div>
              `).join('')}
              <div class="osk-row osk-special-row">
                ${specialRow.map((item, idx) => `
                  <button class="osk-key osk-special ${item.action === 'done' ? 'osk-done' : ''} ${item.action === 'cancel' ? 'osk-cancel' : ''} ${item.action === 'shift' && shifted ? 'osk-active' : ''}"
                          data-action="${item.action}" data-row="${rows.length}" data-col="${idx}"
                          title="${item.label}">
                    ${item.key}
                  </button>
                `).join('')}
              </div>
            </div>
          </div>
        </div>
      `;
    }

    function renderConfig() {
      return `
        <div class="osk-overlay">
          <div class="osk-container osk-config">
            <div class="osk-config-title">Keyboard Settings</div>
            <div class="osk-config-section">
              <div class="osk-config-label">Layout</div>
              <div class="osk-config-option" tabindex="0" data-config="layout-qwerty">
                <span class="osk-config-radio ${oskLayout === 'qwerty' ? 'checked' : ''}"></span>
                <span>QWERTY</span>
              </div>
              <div class="osk-config-option" tabindex="0" data-config="layout-alpha">
                <span class="osk-config-radio ${oskLayout === 'alpha' ? 'checked' : ''}"></span>
                <span>Alphabetical</span>
              </div>
            </div>
            <div class="osk-config-section">
              <div class="osk-config-option" tabindex="0" data-config="full-keyboard">
                <span class="osk-config-checkbox ${oskFullKeyboard ? 'checked' : ''}"></span>
                <span>Full keyboard (include all symbols)</span>
              </div>
            </div>
            <div class="osk-config-buttons">
              <button class="osk-config-btn" id="oskConfigBack" tabindex="0">Back</button>
            </div>
          </div>
        </div>
      `;
    }

    const wrapper = document.createElement('div');
    wrapper.innerHTML = renderKeyboard();
    const oskOverlay = wrapper.firstElementChild;
    document.body.appendChild(oskOverlay);
    oskIsOpen = true;

    let focusRow = 0;
    let focusCol = 0;

    function getKeyAt(row, col) {
      const rows = document.querySelectorAll('.osk-keyboard .osk-row');
      if (row < 0 || row >= rows.length) return null;
      const keys = rows[row].querySelectorAll('.osk-key');
      if (col < 0 || col >= keys.length) return null;
      return keys[col];
    }

    function focusKey(row, col) {
      const rows = document.querySelectorAll('.osk-keyboard .osk-row');
      if (row < 0) row = rows.length - 1;
      if (row >= rows.length) row = 0;

      const keys = rows[row].querySelectorAll('.osk-key');
      if (col < 0) col = keys.length - 1;
      if (col >= keys.length) col = keys.length - 1;

      focusRow = row;
      focusCol = col;
      keys[col]?.focus();
    }

    function updateDisplay() {
      const preview = document.querySelector('.osk-input-preview');
      if (preview) {
        preview.innerHTML = escapeHtml(currentValue) || '<span class="osk-placeholder">Type here...</span>';
      }
      // Update shift state on keys
      document.querySelectorAll('.osk-key[data-key]').forEach(key => {
        const char = key.dataset.key;
        if (char && char.length === 1) {
          key.textContent = shifted ? char.toUpperCase() : char;
        }
      });
      // Update shift button state
      const shiftBtn = document.querySelector('[data-action="shift"]');
      if (shiftBtn) {
        shiftBtn.classList.toggle('osk-active', shifted);
      }
    }

    function handleKeyPress(key, action) {
      if (action === 'shift') {
        shifted = !shifted;
        updateDisplay();
      } else if (action === 'space') {
        currentValue += ' ';
        updateDisplay();
      } else if (action === 'backspace') {
        currentValue = currentValue.slice(0, -1);
        updateDisplay();
      } else if (action === 'config') {
        showingConfig = true;
        const container = document.querySelector('.osk-overlay');
        container.outerHTML = renderConfig();
        setupConfigEvents();
      } else if (action === 'cancel') {
        cleanup(inputElement.value); // Return original value
      } else if (action === 'done') {
        cleanup(currentValue);
      } else if (key) {
        currentValue += shifted ? key.toUpperCase() : key;
        updateDisplay();
      }
    }

    let configFocusIdx = 0;

    function getConfigFocusables() {
      return Array.from(document.querySelectorAll('.osk-config-option, .osk-config-btn'));
    }

    function focusConfigItem(idx) {
      const items = getConfigFocusables();
      if (idx < 0) idx = items.length - 1;
      if (idx >= items.length) idx = 0;
      configFocusIdx = idx;
      items[idx]?.focus();
    }

    function toggleConfigOption(element) {
      const config = element.dataset.config;
      if (config === 'layout-qwerty') {
        oskLayout = 'qwerty';
        localStorage.setItem('oskLayout', oskLayout);
      } else if (config === 'layout-alpha') {
        oskLayout = 'alpha';
        localStorage.setItem('oskLayout', oskLayout);
      } else if (config === 'full-keyboard') {
        oskFullKeyboard = !oskFullKeyboard;
        localStorage.setItem('oskFullKeyboard', oskFullKeyboard);
      }
      // Update visual state
      document.querySelectorAll('.osk-config-radio').forEach(r => r.classList.remove('checked'));
      document.querySelector(`[data-config="layout-${oskLayout}"] .osk-config-radio`)?.classList.add('checked');
      document.querySelector('[data-config="full-keyboard"] .osk-config-checkbox')?.classList.toggle('checked', oskFullKeyboard);
    }

    function closeConfig() {
      showingConfig = false;
      const container = document.querySelector('.osk-overlay');
      container.outerHTML = renderKeyboard();
      setupKeyboardEvents();
      focusKey(0, 0);
    }

    function setupConfigEvents() {
      document.querySelectorAll('.osk-config-option').forEach(option => {
        option.addEventListener('click', () => toggleConfigOption(option));
      });

      document.getElementById('oskConfigBack')?.addEventListener('click', closeConfig);

      // Focus first item
      focusConfigItem(0);
    }

    function setupKeyboardEvents() {
      document.querySelectorAll('.osk-key').forEach(key => {
        key.addEventListener('click', () => {
          const keyChar = key.dataset.key;
          const action = key.dataset.action;
          handleKeyPress(keyChar, action);
        });
      });
    }

    function cleanup(result) {
      oskIsOpen = false;
      document.removeEventListener('keydown', handleOskKey, true);
      const container = document.querySelector('.osk-overlay');
      if (container) container.remove();
      resolve(result);
    }

    function handleOskKey(e) {
      e.stopPropagation();
      e.preventDefault();

      if (showingConfig) {
        if (e.key === 'Escape') {
          closeConfig();
        } else if (e.key === 'Enter') {
          const focused = document.activeElement;
          if (focused?.classList.contains('osk-config-option')) {
            toggleConfigOption(focused);
          } else if (focused?.id === 'oskConfigBack') {
            closeConfig();
          }
        } else if (e.key === 'ArrowUp') {
          focusConfigItem(configFocusIdx - 1);
        } else if (e.key === 'ArrowDown') {
          focusConfigItem(configFocusIdx + 1);
        }
        return;
      }

      if (e.key === 'Escape') {
        cleanup(inputElement.value); // Cancel, return original value
      } else if (e.key === 'Enter') {
        const focused = document.activeElement;
        if (focused?.classList.contains('osk-key')) {
          focused.click();
        }
      } else if (e.key === 'ArrowUp') {
        focusKey(focusRow - 1, focusCol);
      } else if (e.key === 'ArrowDown') {
        focusKey(focusRow + 1, focusCol);
      } else if (e.key === 'ArrowLeft') {
        focusKey(focusRow, focusCol - 1);
      } else if (e.key === 'ArrowRight') {
        focusKey(focusRow, focusCol + 1);
      }
    }

    document.addEventListener('keydown', handleOskKey, true);
    setupKeyboardEvents();
    focusKey(0, 0);
  });
}

// Track keyboard vs mouse mode to prevent dual highlights
document.addEventListener('keydown', (e) => {
  if (!keyboardMode && ['ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight', 'Tab', 'Enter'].includes(e.key)) {
    keyboardMode = true;
    document.body.classList.add('keyboard-mode');
  }
});

document.addEventListener('mousemove', (e) => {
  if (keyboardMode) {
    keyboardMode = false;
    document.body.classList.remove('keyboard-mode');

    // Check if mouse is over a navigable element
    const target = document.elementFromPoint(e.clientX, e.clientY);
    const isNavigable = target && (target.classList.contains('app-tile') ||
        target.classList.contains('library-tile') ||
        target.classList.contains('profile-tile') ||
        target.classList.contains('menu-item') ||
        target.classList.contains('menu-btn') ||
        target.classList.contains('back-btn'));

    // Only change focus if mouse is over a navigable element
    if (isNavigable) {
      target.focus();
    }
    // If not over anything navigable, keep current focus
  }
});

// When mouse enters a navigable element, focus it
document.addEventListener('mouseenter', (e) => {
  const target = e.target;
  if (target.classList.contains('app-tile') ||
      target.classList.contains('library-tile') ||
      target.classList.contains('profile-tile') ||
      target.classList.contains('menu-item') ||
      target.classList.contains('menu-btn') ||
      target.classList.contains('back-btn')) {
    target.focus();
  }
}, true);

// Start
init();
