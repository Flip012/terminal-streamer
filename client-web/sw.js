// Service Worker for Terminal Streamer PWA

self.addEventListener("install", (event) => {
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(self.clients.claim());
});

self.addEventListener("push", (event) => {
  let data = { title: "Terminal Streamer", body: "Neue Aktivität", tag: "default" };

  if (event.data) {
    try {
      data = event.data.json();
    } catch (e) {
      data.body = event.data.text();
    }
  }

  const options = {
    body: data.body,
    tag: data.tag,
    icon: "icon-192.svg",
    badge: "icon-192.svg",
    vibrate: [200, 100, 200],
    renotify: true,
    actions: [{ action: "open", title: "Öffnen" }],
  };

  event.waitUntil(self.registration.showNotification(data.title, options));
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();

  event.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((clients) => {
      for (const client of clients) {
        if (client.url.includes("/web") && "focus" in client) {
          return client.focus();
        }
      }
      return self.clients.openWindow("/web/");
    })
  );
});
