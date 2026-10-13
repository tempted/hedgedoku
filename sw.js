// Offline support: the app shell is cached on install. The page is network-first; other same-origin files
// and Google Fonts are served stale-while-revalidate. Leaderboard (Supabase) requests always go to the network.
// Bump VERSION whenever you deploy changed files so returning players get them.
const VERSION = 'hedgedoku-v19';
const SHELL = [
  './',
  './index.html',
  './config.js',
  './manifest.webmanifest',
  './icons/icon.svg',
  './icons/icon-192.png',
  './icons/icon-512.png',
  './icons/apple-touch-icon.png',
];

self.addEventListener('install', event => {
  event.waitUntil(caches.open(VERSION).then(cache => cache.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(k => k !== VERSION).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', event => {
  const req = event.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  const cacheable = url.origin === self.location.origin
    || url.hostname === 'fonts.googleapis.com' || url.hostname === 'fonts.gstatic.com';
  if (!cacheable) return;

  // The page and config.js are network-first, so updates show up on the next visit; the cache is only an offline fallback.
  const isPage = req.mode === 'navigate';
  if (isPage || (url.origin === self.location.origin && url.pathname.endsWith('/config.js'))) {
    const key = isPage ? './index.html' : './config.js';
    // cache: 'no-cache' revalidates with the server instead of trusting the browser's HTTP cache.
    event.respondWith(caches.open(VERSION).then(cache => fetch(req, { cache: 'no-cache' })
      .then(res => { if (res.ok) cache.put(key, res.clone()); return res; })
      .catch(async () => (await cache.match(key)) || Response.error())));
    return;
  }

  event.respondWith(caches.open(VERSION).then(async cache => {
    const hit = await cache.match(req, { ignoreSearch: url.origin === self.location.origin });
    const network = fetch(req).then(res => {
      if (res.ok || res.type === 'opaque') cache.put(req, res.clone());
      return res;
    }).catch(() => hit || (req.mode === 'navigate' ? cache.match('./index.html') : Response.error()));
    return hit || network;
  }));
});
