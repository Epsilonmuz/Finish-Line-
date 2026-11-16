// Finish Line lab: offline support. The page is fetched fresh when online;
// sounds and icons come from the cache.
const CACHE = 'fl-lab-v2';
const ASSETS = ['./', './index.html', './manifest.webmanifest', './icon.png', './apple-touch-icon.png', './icon-192.png', './icon-512.png',
  './sounds/FL_HardStop_A_880_bell.mp3', './sounds/FL_HardStop_B_740_knock.mp3', './sounds/FL_HardStop_C_988_bell.mp3',
  './sounds/FL_HardStop_D_660_knock.mp3', './sounds/FL_Snooze_E_830_bell.mp3', './sounds/FL_WrapUp.mp3'];
self.addEventListener('install', e => { e.waitUntil(caches.open(CACHE).then(c => c.addAll(ASSETS))); self.skipWaiting(); });
self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k)))));
  self.clients.claim();
});
self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET' || new URL(req.url).origin !== location.origin) return;
  if (req.mode === 'navigate') {
    e.respondWith(fetch(req).then(r => { caches.open(CACHE).then(c => c.put('./index.html', r.clone())); return r; })
      .catch(() => caches.match('./index.html')));
    return;
  }
  e.respondWith(caches.match(req).then(hit => hit || fetch(req)));
});
