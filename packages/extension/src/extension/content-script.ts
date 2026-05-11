// Content script — injects page-world websocket instrumentation and
// forwards page events to extension runtime.

function injectPageScript() {
  try {
    const script = document.createElement('script');
    script.src = chrome.runtime.getURL('page-inject.js');
    script.async = false;
    script.onload = () => script.remove();
    (document.head || document.documentElement).appendChild(script);
  } catch {}
}

injectPageScript();

// Forward any messages from the page to the extension background
window.addEventListener('message', (event) => {
  if (event.source !== window) return;
  if (event.data?.type === 'AD4M_DEVTOOLS_EVENT') {
    try {
      chrome.runtime.sendMessage(event.data);
    } catch {}
  }
});
