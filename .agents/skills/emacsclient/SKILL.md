---
name: emacsclient
description: 'Always use emacsclient instead of emacs. This applies to all Emacs operations: user requests, byte compilation, check-parens, running ERT tests, and any other elisp evaluation.'
allowed-tools: Bash
---

# Always use emacsclient

The user has an Emacs server running. **All** Emacs operations must go through `emacsclient`, never `emacs` or `emacs --batch`. This includes both user-requested actions and agent-initiated operations like byte compilation, syntax checking, or running tests. Run agent-initiated work that changes state or can block in a disposable daemon, not the user's live server; see [Live server or disposable daemon](#live-server-or-disposable-daemon).

## Examples

- Open a file: `emacsclient --no-wait "/path/to/file"`
- Evaluate elisp: `emacsclient --eval '(some-function)'`
- Open at a line: `emacsclient --no-wait +42 "/path/to/file"`
- Byte compile a file in a fresh disposable daemon:
  ```bash
  (
    set -eu
    daemon="skill-compile-$(date +%s)-$$"
    trap 'emacsclient --socket-name="$daemon" --eval "(kill-emacs)" >/dev/null 2>&1 || true' EXIT
    emacsclient --socket-name="$daemon" --alternate-editor="" --eval 't'
    emacsclient --socket-name="$daemon" --eval '
    (unless (byte-compile-file "/path/to/file.el")
      (error "Byte compilation failed"))'
  )
  ```
- Check parentheses:
  ```sh
  emacsclient --eval '
  (with-temp-buffer
    (insert-file-contents "/path/to/file.el")
    (check-parens))'
  ```
- Run focused ERT tests in a fresh disposable daemon. Use the repository's
  isolated test runner when one is available; otherwise:
  ```bash
  (
    set -eu
    daemon="skill-ert-$(date +%s)-$$"
    trap 'emacsclient --socket-name="$daemon" --eval "(kill-emacs)" >/dev/null 2>&1 || true' EXIT
    emacsclient --socket-name="$daemon" --alternate-editor="" --eval 't'
    emacsclient --socket-name="$daemon" --eval '
    (progn
      (require (quote ert))
      (load "/path/to/test-file.el" nil t)
      (let ((stats (ert-run-tests-batch "pattern")))
        (when (zerop (ert-stats-total stats))
          (error "No ERT tests matched"))
        (unless (zerop (ert-stats-completed-unexpected stats))
          (error "ERT tests failed"))
        (list :passed (ert-stats-total stats))))'
  )
  ```

## Live server or disposable daemon

Use the live server (default socket) only when the answer depends on the
user's current session, or when the user asked for an action in their Emacs:
- Read-only queries of session state: open buffers, windows, point, mode,
  variable values, keymaps and advice as actually loaded.
- User-requested actions: open a file, jump to a line, hot-patch a function
  when asked.
- Pure checks with no side effects, such as `check-parens` in a temp buffer.

Use a disposable daemon (`--socket-name=NAME --alternate-editor=""`; it loads
the full config) for everything else, in particular anything that:
- runs tests or byte-compiles;
- loads or evaluates code under development (`load`, `defun`, `setq` on
  globals, `advice-add`, hooks, enabling modes), since that changes the
  user's session;
- can block: network, subprocesses, timers, waiting on input, profiling, or
  loops over all buffers;
- can prompt: `read-*`, `completing-read`, `y-or-n-p`, or any minibuffer use.

Live queries must also finish fast: wrap them in
`(with-timeout (5 (error "probe timeout")) ...)`.

## Rules

- Always use `emacsclient`, never `emacs` or `emacs --batch`.
- Never run ERT in the user's interactive server. Start a fresh named daemon,
  address every test and cleanup call to its socket, and stop only that daemon.
- Do not use `ert-run-tests-batch-and-exit` through `emacsclient`; it exits the
  server. Use `ert-run-tests-batch` and report unexpected results as errors.
- Use `--no-wait` when opening files so the command returns immediately.
- Use `--eval` when evaluating elisp.
- Always format `--eval` elisp across multiple lines with proper indentation.
- Inline `--eval` breaks when the elisp contains `'` (`'sym`, `#'fn`). Write such
  elisp to `/tmp/<name>.el` with a quoted heredoc (`<<'EOF'`) and run
  `emacsclient --eval '(load "/tmp/<name>.el" nil t)'`.
- On macOS, `can't find socket` means the sandbox changed `TMPDIR`; rerun with
  `export TMPDIR=$(getconf DARWIN_USER_TEMP_DIR)`. The first call that starts a
  disposable daemon prints the same message before starting it; that is expected.
- Run `emacsclient` commands via the Bash tool.
