// Adapted from VaporView (https://github.com/Lramseyer/vaporview, GPL-3.0), src/webview/vscode_wrapper.ts@59107c6.
//
// Stands in for VS Code's acquireVsCodeApi() inside the viewer frame.
// Webview -> host: a direct call into the parent page (same origin).
// Host -> webview: the parent posts to this window, the way VS Code delivers
// messages (a window 'message' event), so vscode_wrapper.ts needs no change.
(function () {
  const host = window.parent && window.parent.cmuxWaveform;
  // Apply the panel theme before webview.js reads the CSS variables.
  if (host) { host.applyThemeTo(document); }
  let state;
  let acquired = false;
  window.acquireVsCodeApi = function () {
    if (acquired) { throw new Error('acquireVsCodeApi already called'); }
    acquired = true;
    return {
      postMessage(msg) { if (host) { host.fromWebview(msg); } },
      getState() { return state; },
      setState(s) { state = s; return s; },
    };
  };
})();
