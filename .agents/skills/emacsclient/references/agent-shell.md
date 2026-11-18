# agent-shell from emacsclient

Checked against the agent-shell fork `liaowang11/agent-shell` at
`de30e79a`. Functions with `--` in their names are private and may
change; recheck them with `grep` in the package source when a recipe
fails.

## Work hidden

Every recipe runs *hidden*: the user's windows, selected buffer, current
workspace and minibuffer stay as they were. Keep changes hidden too:

- Drive the shell through the private functions below with `:no-display t`
  or `:no-focus t`. The interactive commands (`agent-shell`,
  `agent-shell-start`, `agent-shell-insert`, `agent-shell-resume-session`)
  display the shell and can open pickers.
- Act on the shell inside `with-current-buffer`.
- Keep each eval short; the user's Emacs is blocked while it runs. Long
  waits belong in the terminal, on a file a callback writes.

Run each recipe as a file through `load`, as the skill's rules describe.
Results land in `/tmp/agent-shell.out`.

## Where prompts come from

A new shell can open two pickers, which the recipes avoid:

1. **Which agent.** It shows an agent picker unless
   `agent-shell-preferred-agent-config` is a bare identifier such as
   `claude-code`. A `(preselect . ID)` value still shows the picker.
   Passing `:config` skips it.
2. **Which session.** When `agent-shell-session-strategy` is `prompt`,
   the shell lists the agent's earlier sessions for its directory and
   asks "Start shell (default: New shell)". The question comes after the
   agent answers, so `emacsclient` returns first and the picker appears
   later. A failed resume also falls back to this picker. Binding the
   strategy to `new` avoids it in both cases.

A config maker can open its own picker, for example to read a profile
name; pass every argument it needs.

Check the current settings and shells:

```elisp
(require 'agent-shell)
(with-temp-file "/tmp/agent-shell.out"
  (prin1 (list :preferred agent-shell-preferred-agent-config
               :strategy agent-shell-session-strategy
               :agents (mapcar (lambda (config) (map-elt config :identifier))
                               (agent-shell--resolved-agent-configs))
               :shells (mapcar (lambda (shell)
                                 (list (buffer-name shell)
                                       (agent-shell-session-id :shell-buffer shell)
                                       (agent-shell-status :shell-buffer shell)))
                               (agent-shell-buffers)))
         (current-buffer)))
```

## Create a new session

Set `dir` and, optionally, `workspace`. The shell's directory is the
project root containing `dir`, or `dir` itself outside a project. With a
workspace name, the recipe files the shell in that workspace, creating
it hidden, and sets the user's `+agent-shell--origin-workspace` record
when their config has one.

```elisp
(require 'agent-shell)
(let* ((dir "/path/to/project/")
       (workspace nil)                 ; or "workspace-name"
       (config (or (agent-shell--auto-preferred-config)
                   (error "No preferred agent; pass a config")))
       (shell (agent-shell--new-shell :location dir :config config
                                      :no-display t)))
  (when workspace
    (let ((persp (or (+workspace-get workspace t)
                     (+workspace-new workspace))))
      (persp-add-buffer shell persp nil nil)
      (when (boundp '+agent-shell--origin-workspace)
        (with-current-buffer shell
          (setq-local +agent-shell--origin-workspace persp)))))
  (with-temp-file "/tmp/agent-shell.out"
    (insert (buffer-name shell))))
```

To use an agent other than the preferred one, replace the config with
`(agent-shell--resolve-config-designator 'IDENTIFIER)`. A nil config
brings the agent picker back, hence the error.

Done when the settings recipe lists the shell with a non-nil session id,
usually a few seconds later.

## Resume a session

A live shell's id comes from `agent-shell-session-id`. For Claude Code,
saved sessions are the `ID.jsonl` files in
`~/.claude/projects/<directory with / replaced by ->/`.

```elisp
(require 'agent-shell)
(let* ((dir "/path/to/project/")
       (session-id "SESSION-ID")
       (agent-shell-session-strategy 'new)
       (shell (agent-shell--start
               :config (or (agent-shell--auto-preferred-config)
                           (error "No preferred agent; pass a config"))
               :session-id session-id :cwd dir
               :new-session t :no-focus t)))
  (with-temp-file "/tmp/agent-shell.out"
    (insert (buffer-name shell))))
```

Done when the settings recipe lists the shell with the requested id. An
agent that cannot load the session starts a new one with a different id;
report that to the user and stop. To file the shell in a workspace, reuse
the `when workspace` form from the previous recipe.

## Send a prompt

The recipe requires status `ready` and returns at once. A shell still
starting counts as ready; the prompt goes out when its session exists.
When the turn ends, a callback writes the stop reason and reply to
`/tmp/agent-shell.out`, then creates `/tmp/agent-shell.done`.

```elisp
(require 'agent-shell)
(let* ((shell (get-buffer "SHELL-BUFFER-NAME"))
       (prompt "Summarize the README in three bullets.")
       (chunks nil)
       (chunk-sub nil)
       (done-sub nil))
  (unless (memq (agent-shell-status :shell-buffer shell) '(ready))
    (error "Shell is %s" (agent-shell-status :shell-buffer shell)))
  (ignore-errors (delete-file "/tmp/agent-shell.done"))
  (setq chunk-sub
        (agent-shell-subscribe-to
         :shell-buffer shell :event 'agent-message-chunk
         :on-event (lambda (event)
                     (when-let* ((text (map-nested-elt event '(:data :text-chunk))))
                       (push text chunks)))))
  (setq done-sub
        (agent-shell-subscribe-to
         :shell-buffer shell :event 'turn-complete
         :on-event (lambda (event)
                     (agent-shell-unsubscribe :subscription chunk-sub)
                     (agent-shell-unsubscribe :subscription done-sub)
                     (with-temp-file "/tmp/agent-shell.out"
                       (insert (format "stop-reason: %s\n\n"
                                       (map-nested-elt event '(:data :stop-reason))))
                       (apply #'insert (nreverse chunks)))
                     (with-temp-file "/tmp/agent-shell.done"))))
  (agent-shell--insert-to-shell-buffer :shell-buffer shell :text prompt
                                       :submit t :no-focus t))
```

Wait in the terminal; done when the file exists:

```bash
timeout 600 sh -c 'until [ -e /tmp/agent-shell.done ]; do sleep 2; done'
cat /tmp/agent-shell.out
```

A turn waiting on a permission request shows status `blocked` and stays
there until the user answers; when the wait runs long, check the status
and tell the user.

## Interrupt a turn

```elisp
(with-current-buffer (get-buffer "SHELL-BUFFER-NAME")
  (agent-shell-interrupt t))
```

The `t` skips the confirmation prompt. It cancels pending permission
requests and the running turn; the session stays open. Done when the
turn ends with stop reason `cancelled`, which a pending send recipe
writes to its output.

## Quit a session

Killing the shell buffer shuts the agent process down and kills the
session's viewport; the saved session stays resumable. Binding
`kill-buffer-query-functions` to nil skips two questions: saving the
transcript, and discarding prompts still queued for the agent. The
recipe therefore kills only a shell the user is not looking at and with
an empty queue; otherwise it reports why, and the user decides. Done
when the output reads `(:killed t)`.

```elisp
(let* ((shell (get-buffer "SHELL-BUFFER-NAME"))
       (queued (map-elt (buffer-local-value 'agent-shell--state shell)
                        :pending-prompts))
       (shown (or (get-buffer-window shell t)
                  (when-let* ((viewport (agent-shell-viewport--buffer
                                         :shell-buffer shell :existing-only t)))
                    (get-buffer-window viewport t)))))
  (if (or queued shown)
      (with-temp-file "/tmp/agent-shell.out"
        (prin1 (list :not-killed :queued (length queued) :shown (and shown t))
               (current-buffer)))
    (let ((kill-buffer-query-functions nil))
      (kill-buffer shell))
    (with-temp-file "/tmp/agent-shell.out"
      (prin1 (list :killed (not (buffer-live-p shell))) (current-buffer)))))
```
