// The text breakpoints' judge (cmux-debugger-text.js): formats values and matches them off the
// page's thread, so the page can stop a pattern that never finishes. Written for cmux.
/* global importScripts, cmuxTextMatch */
importScripts('cmux-formats.js', 'cmux-textmatch.js');
self.onmessage = (e) => {
  const { id, spec, values } = e.data || {};
  try {
    const mask = cmuxTextMatch.judge(spec, values);
    self.postMessage({ id, mask }, [mask.buffer]);
  } catch (error) {
    self.postMessage({ id, error: String(error && error.message || error) });
  }
};
