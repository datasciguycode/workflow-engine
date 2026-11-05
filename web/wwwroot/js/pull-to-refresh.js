// Standalone (Home Screen) PWAs on iOS have no Safari chrome, so the native pull-to-refresh
// gesture that lives in Safari's tab UI isn't available there (2026-11-04). This re-implements
// just that gesture, scoped to standalone mode only -- a normal Safari tab already has the real
// one, so this script no-ops there to avoid fighting it.
(function () {
  var isStandalone = window.navigator.standalone === true ||
    window.matchMedia('(display-mode: standalone)').matches;
  if (!isStandalone) return;

  var THRESHOLD = 70;
  var indicator = document.createElement('div');
  indicator.textContent = 'Pull to refresh';
  indicator.style.cssText =
    'position:fixed; top:0; left:0; right:0; text-align:center; font-size:0.85rem; ' +
    'opacity:0.6; padding:6px 0; transform:translateY(-100%); transition:transform 0.15s ease-out; ' +
    'z-index:2000; pointer-events:none;';
  document.body.appendChild(indicator);

  var startY = null;
  var pulling = false;
  var dy = 0;

  document.addEventListener('touchstart', function (e) {
    if (window.scrollY <= 0) {
      startY = e.touches[0].clientY;
      pulling = true;
    } else {
      pulling = false;
    }
  }, { passive: true });

  document.addEventListener('touchmove', function (e) {
    if (!pulling) return;
    dy = e.touches[0].clientY - startY;
    if (dy <= 0) return;
    dy = Math.min(dy, 120);
    indicator.style.transition = 'none';
    indicator.style.transform = 'translateY(' + (dy - 40) + 'px)';
    indicator.textContent = dy > THRESHOLD ? 'Release to refresh' : 'Pull to refresh';
  }, { passive: true });

  document.addEventListener('touchend', function () {
    if (!pulling) return;
    pulling = false;
    indicator.style.transition = 'transform 0.15s ease-out';
    if (dy > THRESHOLD) {
      indicator.textContent = 'Refreshing…';
      indicator.style.transform = 'translateY(0)';
      window.location.reload();
    } else {
      indicator.style.transform = 'translateY(-100%)';
    }
    dy = 0;
  }, { passive: true });
})();
