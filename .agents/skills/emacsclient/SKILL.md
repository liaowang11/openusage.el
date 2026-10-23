---
name: emacsclient
description: 'Emacs operations: querying or acting in the user''s running Emacs, running ERT, byte compilation or checkdoc on elisp, evaluating elisp against the user''s config, or starting any Emacs process or daemon.'
allowed-tools: Bash
---

# Emacs through emacsclient, batch, or a disposable daemon

The user has an Emacs server running. Pick the route for each Emacs
operation by asking two questions in order:

1. Does the answer depend on the user's running session (open buffers,
   windows, variable values as they are now), or did the user ask for an
   action in their Emacs? Use the **live server** (`emacsclient`, default
   socket). See [Live server](#live-server).
2. Otherwise, does the work need the user's config: their installed
   packages, the hooks, keymaps and advice their init sets up, or functions
   it defines?
   - No: use **batch Emacs** (`emacs -Q --batch`). This covers ERT, byte
     compilation, checkdoc, and evaluating or debugging a package with
     only its dependencies loaded. It exits when done. See
     [Batch Emacs](#batch-emacs).
   - Yes: use the **disposable daemon** (`scripts/disposable-emacs` in this
     skill's directory). See [Disposable daemon](#disposable-daemon).

Work that can block or prompt is not by itself a reason for a daemon:
batch Emacs with a time limit and stdin from `/dev/null` fails fast on
both.

Start Emacs only through these three routes. A daemon started any other
way (`emacs --daemon`, `emacsclient --alternate-editor=""`) outlives its
shell when the tool call times out or the daemon hangs, and a hung daemon
ignores `(kill-emacs)`.

## Live server

Use the live server only when the answer depends on the user's current
session, or when the user asked for an action in their Emacs:
- Read-only queries of session state: open buffers, windows, point, mode,
  variable values, keymaps and advice as actually loaded.
- User-requested actions: open a file, jump to a line, hot-patch a function
  when asked.
- Pure checks with no side effects, such as `check-parens` in a temp buffer.

Live queries must finish fast: wrap them in
`(with-timeout (5 (error "probe timeout")) ...)`. If a live call times out,
stop and tell the user instead of sending more.

Examples:
- Open a file: `emacsclient --no-wait "/path/to/file"`
- Open at a line: `emacsclient --no-wait +42 "/path/to/file"`
- Evaluate elisp: `emacsclient --eval '(some-function)'`
- Check parentheses:
  ```sh
  emacsclient --eval '
  (with-temp-buffer
    (insert-file-contents "/path/to/file.el")
    (check-parens))'
  ```

## Batch Emacs

Use `emacs -Q --batch` for work that doesn't need the user's config. Prefer
the repository's own test runner when it has one. Otherwise put the
repository first on the load path, then each dependency's directory (where
the user's package manager installed it, for example under `elpa/` or
`straight/build-*/`), and set `load-prefer-newer` so a stale `.elc` doesn't
shadow its source. Run it under `timeout` with `</dev/null`, so a prompt
reads end-of-file and errors out instead of waiting.

Batch Emacs sets `noninteractive` to t, and code may behave differently
because of that. When that matters, use the disposable daemon.

- Run focused ERT tests (the exit code is non-zero on failure):
  ```bash
  emacs -Q --batch -L . -L /path/to/dependency \
    --eval '(setq load-prefer-newer t)' \
    -l ert -l tests/foo-tests.el \
    --eval '(ert-run-tests-batch-and-exit "pattern")'
  ```
- Byte compile:
  ```bash
  emacs -Q --batch -L . -L /path/to/dependency \
    --eval '(setq byte-compile-error-on-warn t)' \
    -f batch-byte-compile foo.el
  ```
  Delete the resulting `.elc` afterwards unless the repository tracks it.
- Checkdoc:
  ```bash
  emacs -Q --batch --eval '(checkdoc-file "foo.el")'
  ```
  The exit code is 0 even when checkdoc warns; read stderr for `foo.el:`
  lines.

## Disposable daemon

Use `scripts/disposable-emacs` when the work needs the user's config but
must not change or block the live session. For example:
- trying a fix or hot-patch against the user's config before applying it
  live;
- reproducing a bug that only shows with the user's packages or settings;
- checking how the user's config sets up a mode, keymap or hook from
  scratch;
- code that behaves differently when `noninteractive` is t.

Write the elisp to one or more files with a quoted heredoc and pass them to
the script. It starts a fresh daemon with the user's config, evaluates each
file's forms in order in that daemon, prints the value of each file's last
form, and then stops the daemon:

```bash
cat >/tmp/probe.el <<'EOF'
(load "/path/to/repo/foo.el" nil t)
(list :mode (foo-mode-p) :hooks foo-mode-hook)
EOF
/path/to/this/skill/scripts/disposable-emacs -i -t 120 /tmp/probe.el
```

Pass `-i` (experimental) unless you have a reason not to. The daemon then
writes its state (histories, bookmarks, workspaces, caches) into a
throwaway copy-on-write clone of the user's Emacs directory instead of the
real one. On macOS a `sandbox-exec` profile also blocks writes under
`$HOME`, except to package build directories, `~/Library/Caches`, and
directories you allow with `-w DIR`. Isolation works for any config.
Doom is detected and gets its `DOOMLOCALDIR` cloned. Other configs get
their `user-emacs-directory` cloned through `--init-directory`, which
needs Emacs 29+. Without `-i`, the daemon reads and writes the user's real
state files while it runs. If a run fails only with `-i`, say so.

- Files share one daemon, so a later file sees what an earlier one defined.
- A failing form makes the script exit non-zero with the error on stderr.
- `-t SECONDS` limits each file (default 300); `-s` limits startup (default
  120); `-l` is the daemon's maximum lifetime (default 3600).
- The script stops the daemon with `(kill-emacs)`, or SIGKILL when that
  fails, and prints how it stopped. The daemon also stops itself when the
  script is gone. Neither way runs `kill-emacs-hook`, so the user's
  bookmarks, workspaces and histories are not saved from the daemon.
- Each run first sweeps up daemons, clones and files left by earlier runs;
  `disposable-emacs sweep` does only that.
- Keep printed values small. `emacsclient` garbles long or multibyte
  results, so write large output to a file from the elisp and read the file.

## Rules

- Keep `ert-run-tests-batch-and-exit` and `kill-emacs` away from the live
  server: both exit it. Batch Emacs and the disposable daemon are where
  they belong.
- Use `--no-wait` when opening files so the command returns immediately.
- Format `--eval` elisp across multiple lines with proper indentation.
- Inline `--eval` breaks when the elisp contains `'` (`'sym`, `#'fn`). Write
  such elisp to `/tmp/<name>.el` with a quoted heredoc (`<<'EOF'`) and run
  `emacsclient --eval '(load "/tmp/<name>.el" nil t)'`.
- On macOS, `can't find socket` from the live server means the sandbox
  changed `TMPDIR`; rerun with `export TMPDIR=$(getconf DARWIN_USER_TEMP_DIR)`.
- Run Emacs commands via the Bash tool.
