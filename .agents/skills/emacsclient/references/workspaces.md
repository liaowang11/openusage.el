# Doom workspaces from emacsclient

Requires Doom's `:ui workspaces` module, which runs on `persp-mode`.
Workspaces are per frame. `emacsclient --eval` acts on the server's
selected frame, which is normally the user's GUI frame, so a switch is
visible to the user. Switch only when the user wants to be taken there.

## Functions

Use these functions. The `+workspace/...` commands report errors as a
message, which a script never sees.

| Function | Effect |
| --- | --- |
| `(+workspace-list-names)` | Names of open workspaces. |
| `(+workspace-new NAME)` | Create NAME without switching to it. Signals when NAME exists. |
| `(+workspace-switch NAME t)` | Switch to NAME, creating it first when missing. Returns t on success. |
| `(+workspace-get NAME t)` | The workspace object, or nil. |

## Create a project workspace

Doom's project switching reuses a workspace whose `+workspace-project`
parameter names the same root. Set it so a later project switch finds
this workspace instead of creating a second one. The recipe names the
workspace after the directory and errors when a workspace of that name
belongs to another root.

By default the recipe works in the background: it creates the workspace
and files a Dired buffer for the root in it, without touching the user's
windows or current workspace. Set `switch` to t only when the user wants
to be taken there; it then opens Magit (or Dired) in the new workspace.

```bash
cat >/tmp/ws-new.el <<'EOF'
(let* ((root (file-truename "/path/to/repo/"))
       (switch nil)
       (name (file-name-nondirectory (directory-file-name root))))
  (when-let* ((existing (+workspace-get name t))
              (other (persp-parameter '+workspace-project existing))
              ((not (file-equal-p other root))))
    (error "Workspace %s belongs to %s" name other))
  (let ((persp (or (+workspace-get name t) (+workspace-new name))))
    (unless (persp-parameter '+workspace-project persp)
      (set-persp-parameter '+workspace-project root persp))
    (if (not switch)
        (persp-add-buffer (dired-noselect root) persp nil nil)
      (+workspace-switch name)
      (with-current-buffer (window-buffer (selected-window))
        (if (file-exists-p (expand-file-name ".git" root))
            (magit-status-setup-buffer root)
          (dired root)))))
  (with-temp-file "/tmp/ws-new.out"
    (insert name)))
EOF
emacsclient --eval '(load "/tmp/ws-new.el" nil t)'
cat /tmp/ws-new.out
```

Other operations:

- Rename the current workspace: `(+workspace-rename (+workspace-current-name) "new")`.
- Close a workspace: `(+workspace-kill "name")`. It also kills the
  workspace's buffers that no other workspace holds, unless the second
  argument is non-nil, so ask first. Switch away before closing the
  current workspace.
