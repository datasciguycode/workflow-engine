// Focuses the chat textarea in direct response to a button tap. iOS Safari only opens the
// keyboard (and the dictation mic icon on it) when .focus() is called synchronously inside a
// real user-gesture handler like this one -- it ignores autofocus and any .focus() call made on
// page load/render (2026-10-25). fluent-text-area is a web component; its host element exposes
// its own focus() which delegates into the internal shadow-DOM <textarea>.
window.focusChatInput = () => document.getElementById('chat-input')?.focus();
