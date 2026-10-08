;;; openusage-tests.el --- Tests for openusage.el -*- lexical-binding: t; -*-

;;; Commentary:

;; Rendering runs against JSON fixtures captured from the `openusage'
;; command line tool, at a pinned time and time zone.  The golden
;; files hold the text a tty shows; the SVG rail is a `display'
;; property on top of it, checked separately.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'openusage)

(defvar openusage-tests--dir
  (file-name-directory (or load-file-name buffer-file-name)))

(defconst openusage-tests--now
  (openusage--parse-timestamp "2026-09-28T14:30:00Z")
  "The time every rendering test runs at.")

(defun openusage-tests--fixture (name)
  "Return fixture NAME parsed as JSON."
  (with-temp-buffer
    (insert-file-contents (expand-file-name (concat "fixtures/" name) openusage-tests--dir))
    (json-parse-buffer :object-type 'alist :array-type 'list)))

(defun openusage-tests--expected (name)
  "Return golden file NAME without its trailing newline."
  (with-temp-buffer
    (insert-file-contents (expand-file-name (concat "fixtures/" name) openusage-tests--dir))
    (string-trim-right (buffer-string))))

(defmacro openusage-tests--in-zone (&rest body)
  "Run BODY in UTC+8, the zone the golden files were written in.
A POSIX offset, not a zoneinfo name, so it works with no tzdata."
  (declare (indent 0))
  `(let ((zone (getenv "TZ")))
     (set-time-zone-rule "HKT-8")
     (unwind-protect (progn ,@body)
       (set-time-zone-rule zone))))

(defun openusage-tests--render (fixture &optional detail)
  "Render FIXTURE as plain text at the pinned time, optionally in DETAIL."
  (substring-no-properties
   (openusage-render (openusage-tests--fixture fixture) openusage-tests--now
                     (make-hash-table :test 'equal) detail)))

(defun openusage-tests--resource (&rest fields)
  "Return a percent limit resetting in 2h of a 5h window, with FIELDS on top.
FIELDS is a plist of `used' and any other keys to override."
  (let ((resource (copy-tree '((kind . "consumption") (unit . "percent") (limit . 100)
                                (resetsAt . "2026-09-28T16:30:00Z") (windowSeconds . 18000)))))
    (while fields
      (setf (alist-get (pop fields) resource) (pop fields)))
    resource))

;;; Rendering

(ert-deftest openusage-test-overview-golden ()
  (openusage-tests--in-zone
    (let ((openusage-always-show-pacing t))
      (should (equal (openusage-tests--render "combined.json")
                     (openusage-tests--expected "combined-overview.txt"))))))

(ert-deftest openusage-test-detail-golden ()
  (openusage-tests--in-zone
    (let ((openusage-always-show-pacing t))
      (should (equal (openusage-tests--render "combined.json" t)
                     (openusage-tests--expected "combined-detail.txt"))))))

(ert-deftest openusage-test-error-only-provider ()
  (should (equal (openusage-tests--render "error.json") "Codex  ! No current data.")))

(ert-deftest openusage-test-stale-provider-and-its-error ()
  (let ((text (openusage-tests--render "limits.json")))
    (should (string-prefix-p "Claude · Team 5x  ! stale\n  ! Refresh failed; showing cached data.\n" text))))

(ert-deftest openusage-test-healthy-hides-pacing-by-default ()
  "The app shows pacing on healthy limits only with Always Show Pacing."
  (let ((openusage-always-show-pacing nil))
    (openusage-tests--in-zone
      (let ((text (openusage-tests--render "combined.json")))
        (should (string-match-p "^  Session\n  █+┊?█*▌░+\n  92% left " text))
        (should-not (string-match-p "~78% left at reset" text))
        (should (string-match-p "~3% spare" text))))))

(ert-deftest openusage-test-zero-balances-only-in-detail ()
  (openusage-tests--in-zone
    (should-not (string-match-p "Credit Value" (openusage-tests--render "combined.json")))
    (should (string-match-p "Credit Value  *\\$0\\.00" (openusage-tests--render "combined.json" t)))))

(ert-deftest openusage-test-resources-follow-app-order ()
  "The tool sorts keys alphabetically; the app lists Session first."
  (let* ((text (openusage-tests--render "combined.json"))
         (claude (substring text 0 (string-search "\n\n" text))))
    (should (< (string-search "Session" claude) (string-search "Weekly" claude)
               (string-search "Fable" claude) (string-search "Extra Usage" claude)))))

(ert-deftest openusage-test-used-display ()
  (let ((openusage-usage-display 'used))
    (openusage-tests--in-zone
      (let ((text (openusage-tests--render "combined.json")))
        (should (string-match-p "\n  8% used " text))
        ;; An 8% used bar fills 3.52 cells: 3 full and a half.
        (should (string-match-p (concat "\n  " (regexp-quote "███▌░")) text))))))

(ert-deftest openusage-test-collapsed-provider ()
  (let ((expanded (make-hash-table :test 'equal)))
    (puthash '(provider . "zai") nil expanded)
    (let ((text (substring-no-properties
                 (openusage-render (openusage-tests--fixture "combined.json")
                                   openusage-tests--now expanded))))
      (should (string-suffix-p "Z.ai · GLM Coding Lite …" text)))))

(ert-deftest openusage-test-keys-on-every-row ()
  (let ((text (openusage-render (openusage-tests--fixture "combined.json")
                                openusage-tests--now (make-hash-table :test 'equal))))
    (should (equal (get-text-property 0 'openusage-key text) '(provider . "claude")))
    (let ((bar (string-search "\n  █" text)))
      (should (equal (get-text-property (1+ bar) 'openusage-key text)
                     '(resource "claude" "session"))))))

;;; Field selection

(ert-deftest openusage-test-overview-shows-resets-by-default ()
  "Like the app's card: label and verdict, the bar, then amount and reset."
  (openusage-tests--in-zone
    (let ((text (openusage-tests--render "combined.json")))
      (should (string-match-p "^  Session\n  █+┊?█*▌░+\n  92% left +Resets in 3h 10m$"
                              text))
      (should (string-match-p "^  Session +! Limit in 3h 15m\n  [^\n]+\n  81% left +Resets in 4h 15m$"
                              text)))))

(ert-deftest openusage-test-reset-exact-with-countdown-echo ()
  "The reset reads in `openusage-reset-display'; hovering shows the other format."
  (openusage-tests--in-zone
    (let* ((openusage-reset-display 'exact)
           (openusage--fields '(resets))
           (text (openusage--card "Session" (openusage-tests--resource 'used 30) openusage-tests--now))
           (start (string-search "Resets" text)))
      (should (string-match-p "\n  70% left +Resets tomorrow at 00:30\\'" (substring-no-properties text)))
      (should (equal (get-text-property start 'help-echo text) "Resets in 2h")))))

(ert-deftest openusage-test-card-context-without-reset ()
  "With no reset time, the app shows the window, a dollar limit, or the unit."
  (let ((openusage--fields '(resets))
        (card (lambda (&rest fields)
                (car (last (split-string
                            (substring-no-properties
                             (openusage--card "X" (apply #'openusage-tests--resource fields)
                                              openusage-tests--now))
                            "\n"))))))
    (should (equal (funcall card 'used 30 'resetsAt nil 'windowSeconds nil) "  70% left"))
    (should (string-match-p "  70% left +Resets in 5h\\'" (funcall card 'used 30 'resetsAt nil)))
    (should (string-match-p "  \\$5\\.00 left +\\$20 limit\\'"
                            (funcall card 'used 15 'limit 20 'unit "usd" 'resetsAt nil 'windowSeconds nil)))
    (should (string-match-p "  \\$5\\.00 left +\\$20\\.50 limit\\'"
                            (funcall card 'used 15.5 'limit 20.5 'unit "usd" 'resetsAt nil 'windowSeconds nil)))
    (should (string-match-p "  14 left +searches\\'"
                            (funcall card 'used 86 'unit "searches" 'resetsAt nil 'windowSeconds nil)))))

(ert-deftest openusage-test-overview-fields-add-detail-lines ()
  "Detail lines and zero balances move into the overview when listed."
  (openusage-tests--in-zone
    (let* ((openusage-overview-fields '(bar window zero-balances))
           (text (openusage-tests--render "combined.json")))
      (should (string-match-p "^  Session\n  █+┊?█*▌░+\n  92% left\n      window     1h 50m of 5h" text))
      (should (string-match-p "Credit Value" text))
      (should-not (string-match-p "~78% left at reset\\|Resets in\\|pace " text)))))

(ert-deftest openusage-test-overview-without-bar ()
  (openusage-tests--in-zone
    (let* ((openusage-overview-fields '(verdict resets))
           (text (openusage-tests--render "combined.json")))
      (should-not (string-match-p "█\\|░" text))
      (should (string-match-p "^  Weekly\n  56% left +Resets in 1d 9h\n  Fable$" text)))))

(ert-deftest openusage-test-detail-fields-drop-lines ()
  (openusage-tests--in-zone
    (let* ((openusage-detail-fields '(verdict bar resets))
           (text (openusage-tests--render "combined.json" t)))
      (should (string-match-p "92% left +Resets in 3h 10m" text))
      (should-not (string-match-p "resets  \\|pace \\|window \\|at reset   \\|fetched \\|expires \\|Credit Value"
                                  text)))))

;;; Formatting

(ert-deftest openusage-test-compact-duration ()
  (should (equal (openusage--compact-duration 65) "2m"))
  (should (equal (openusage--compact-duration 3600) "1h"))
  (should (equal (openusage--compact-duration 3660) "1h 1m"))
  (should (equal (openusage--compact-duration 90000) "1d 1h"))
  (should (equal (openusage--compact-duration (+ (* 4 86400) (* 52 60))) "4d 0h")))

(ert-deftest openusage-test-deadline-labels ()
  (openusage-tests--in-zone
    (let ((now openusage-tests--now))   ; 22:30 local
      (should (equal (openusage--deadline-label "Resets" (+ now 7500) now 'countdown) "Resets in 2h 5m"))
      (should (equal (openusage--deadline-label "Resets" (+ now 200) now 'countdown) "Resets soon"))
      (should (equal (openusage--deadline-label "Resets" (+ now 3600) now 'exact) "Resets today at 23:30"))
      (should (equal (openusage--deadline-label "Resets" (+ now 7200) now 'exact) "Resets tomorrow at 00:30"))
      (should (equal (openusage--deadline-label "Resets" (+ now (* 5 86400)) now 'exact) "Resets Oct 3 at 22:30"))
      (should (equal (openusage--deadline-label nil (+ now 7500) now 'countdown) "in 2h 5m")))))

(ert-deftest openusage-test-labels ()
  (should (equal (openusage--label "zai" "webSearches") "Web Searches"))
  (should (equal (openusage--label "codex" "rateLimitResets") "Rate Limit Resets"))
  (should (equal (openusage--label "antigravity" "nonGeminiWeekly") "Claude Weekly"))
  (should (equal (openusage--label "cursor" "credits") "Extra Usage"))
  (should (equal (openusage--label "codex" "credits") "Credits")))

(ert-deftest openusage-test-amounts ()
  (should (equal (openusage--amount 52 "percent") "52%"))
  (should (equal (openusage--amount 1234.5 "usd") "$1,234.50"))
  (should (equal (openusage--amount 821 "credits") "821 credits"))
  (should (equal (openusage--short-amount 14 "searches") "14")))

;;; Pacing, mirroring the app's Pace and meterState cases

(defun openusage-tests--state (&rest fields)
  "Return the meter state of a test resource with FIELDS, at 3h into 5h."
  (openusage--meter (apply #'openusage-tests--resource fields) openusage-tests--now))

(ert-deftest openusage-test-meter-healthy ()
  ;; 30% used 60% of the way through projects 50%: ahead.
  (let ((meter (openusage-tests--state 'used 30)))
    (should (eq (plist-get meter :state) 'healthy))
    (should (= (plist-get meter :projected) 0.5))))

(ert-deftest openusage-test-meter-close ()
  ;; 57% used at 60% projects 95%: inside the last 10%.
  (let ((meter (openusage-tests--state 'used 57)))
    (should (eq (plist-get meter :state) 'close))
    (should (eq (plist-get meter :severity) 'warning))
    (should (equal (openusage--verdict meter openusage-tests--now) "~5% spare"))))

(ert-deftest openusage-test-meter-running-out ()
  ;; 90% used at 60% runs out after 10 / (90 / 3h) = 20 minutes.
  (let ((meter (openusage-tests--state 'used 90)))
    (should (eq (plist-get meter :state) 'running-out))
    (should (= (round (- (plist-get meter :eta) openusage-tests--now)) 1200))
    (should (equal (openusage--verdict meter openusage-tests--now) "! Limit in 20m"))
    (should (equal (openusage--projection meter) "~50% over limit at reset"))))

(ert-deftest openusage-test-meter-spent-outranks-pace ()
  (let ((meter (openusage-tests--state 'used 99.6)))
    (should (eq (plist-get meter :state) 'spent))
    (should (equal (openusage--verdict meter openusage-tests--now) "! Limit reached"))))

(ert-deftest openusage-test-meter-distrusts-early-tiny-usage ()
  "Under 5% used, a projected blow-out falls back to plain levels.
4% used 10 minutes into 5h projects 120%."
  (let ((meter (openusage--meter (openusage-tests--resource 'used 4 'resetsAt "2026-09-28T19:20:00Z")
                                 openusage-tests--now)))
    (should (eq (plist-get meter :state) 'level))
    (should (eq (plist-get meter :severity) 'normal))))

(ert-deftest openusage-test-meter-too-early-in-window ()
  "Under 1% of the window (and a minute) there is no pace yet."
  (should-not (openusage--pace (openusage-tests--resource 'used 10 'resetsAt "2026-09-28T19:29:30Z")
                               openusage-tests--now)))

(ert-deftest openusage-test-meter-levels-without-window ()
  (let ((resource '((kind . "consumption") (unit . "percent") (limit . 100))))
    (should (eq (plist-get (openusage--meter `((used . 79) ,@resource) 0) :severity) 'normal))
    (should (eq (plist-get (openusage--meter `((used . 80) ,@resource) 0) :severity) 'warning))
    (should (eq (plist-get (openusage--meter `((used . 90) ,@resource) 0) :severity) 'critical))))

(ert-deftest openusage-test-tick-visibility-and-framing ()
  (let* ((healthy (openusage-tests--resource 'used 30))
         (close (openusage-tests--resource 'used 57))
         (now openusage-tests--now))
    (let ((openusage-always-show-pacing nil))
      (should-not (openusage--tick (openusage--meter healthy now) healthy now))
      (should (= (openusage--tick (openusage--meter close now) close now) 0.4)))
    (let ((openusage-always-show-pacing t) (openusage-usage-display 'used))
      (should (= (openusage--tick (openusage--meter healthy now) healthy now) 0.6)))))

;;; Bars

(ert-deftest openusage-test-glyph-bar-eighths ()
  "0.97 of 20 cells is 155 eighths: 19 full cells and a 3/8 cell."
  (should (equal (openusage--glyph-bar 0.97 nil 20) (concat (make-string 19 ?█) "▍")))
  (should (equal (openusage--glyph-bar 0.5 0.25 8) "██┊█░░░░")))

(ert-deftest openusage-test-bar-without-frame-is-text ()
  (let ((openusage--render-frame nil))
    (should-not (get-text-property 0 'display (openusage--bar 0.5 nil 'normal)))))

(ert-deftest openusage-test-svg-bar ()
  (skip-unless (image-type-available-p 'svg))
  (let ((image (openusage--svg-bar 0.5 0.25 '("#00ff00" "#333333" "#ffffff") 352 18)))
    (should (eq (car image) 'image))
    (should (eq (plist-get (cdr image) :type) 'svg))))

;;; Buffer behaviour

(defmacro openusage-tests--with-buffer (&rest body)
  "Run BODY in a buffer holding the combined fixture, without a timer."
  (declare (indent 0))
  `(with-temp-buffer
     (setq-local openusage--expanded (make-hash-table :test 'equal)
                 openusage--document (openusage-tests--fixture "combined.json"))
     (openusage--repaint)
     ,@body))

(ert-deftest openusage-test-cycle-like-org-shifttab ()
  (openusage-tests--with-buffer
    (puthash '(provider . "codex") nil openusage--expanded)
    (openusage-cycle)
    (should (equal (buffer-string)
                   "Claude · Team 5x …\n\nAntigravity …\n\nCodex · Plus …\n\nZ.ai · GLM Coding Lite …"))
    (openusage-cycle)
    (should (string-match-p "Web Searches" (buffer-string)))))

(ert-deftest openusage-test-toggle-provider-only ()
  (openusage-tests--with-buffer
    (goto-char (point-min))
    (openusage-toggle)
    (should (string-prefix-p "Claude · Team 5x …\n\nAntigravity" (buffer-string)))
    (goto-char (point-max))
    (should-error (openusage-toggle) :type 'user-error)))

(ert-deftest openusage-test-visit-opens-provider ()
  (openusage-tests--with-buffer
    (let (opened)
      (cl-letf (((symbol-function 'openusage-provider) (lambda (provider &rest _) (setq opened provider))))
        (goto-char (point-max))
        (openusage-visit)
        (should (equal opened "zai"))
        (goto-char (point-min))
        (openusage-visit)
        (should (equal opened "claude"))))))

(ert-deftest openusage-test-provider-motion-without-wrapping ()
  (openusage-tests--with-buffer
    (goto-char (point-min))
    (should-error (openusage-previous-provider) :type 'user-error)
    (should (= (point) (point-min)))
    (forward-line 2)
    (openusage-next-provider)
    (should (equal (openusage--key-at-point) '(provider . "antigravity")))
    (should (bolp))
    (openusage-next-provider)
    (openusage-next-provider)
    (should (equal (openusage--key-at-point) '(provider . "zai")))
    (goto-char (point-max))
    (should-error (openusage-next-provider) :type 'user-error)
    (should (= (point) (point-max)))
    (openusage-previous-provider)
    (should (equal (openusage--key-at-point) '(provider . "zai")))
    (openusage-previous-provider)
    (should (equal (openusage--key-at-point) '(provider . "codex")))))

(ert-deftest openusage-test-imenu-lists-providers ()
  (openusage-tests--with-buffer
    (let ((index (openusage--imenu-index)))
      (should (equal (mapcar #'car index) '("Claude" "Antigravity" "Codex" "Z.ai")))
      (goto-char (cdr (nth 2 index)))
      (should (equal (openusage--key-at-point) '(provider . "codex"))))))

(ert-deftest openusage-test-repaint-keeps-point-entry ()
  (openusage-tests--with-buffer
    (goto-char (point-max))
    (openusage--repaint)
    (should (equal (openusage--key-at-point) '(resource "zai" "webSearches")))))

(ert-deftest openusage-test-display-refreshes-at-once ()
  "A window showing the buffer again repaints and fetches immediately,
not at the next poll tick."
  (let ((previous (window-buffer))
        (fetches nil))
    (unwind-protect
        (with-temp-buffer
          (openusage-mode)
          (setq openusage--document (openusage-tests--fixture "combined.json"))
          (openusage--repaint)
          (let ((inhibit-read-only t))
            (erase-buffer)
            (insert "stale paint"))
          (set-window-buffer nil (current-buffer))
          (cl-letf (((symbol-function 'openusage--fetch)
                     (lambda (&rest _args) (push (current-buffer) fetches))))
            (openusage--on-shown (selected-window))
            (should (equal fetches (list (current-buffer))))
            (should (string-match-p "Claude · Team 5x" (buffer-string)))
            ;; The hook also runs for the buffer a window stopped showing.
            (set-window-buffer nil previous)
            (let ((inhibit-read-only t))
              (erase-buffer)
              (insert "buried paint"))
            (openusage--on-shown (selected-window))
            (should (equal fetches (list (current-buffer))))
            (should (equal (buffer-string) "buried paint")))
          ;; The mode wires the hook so real redisplay triggers it, and only
          ;; when a window starts showing the buffer, not on any layout change.
          (should (memq #'openusage--on-shown window-buffer-change-functions))
          (should-not (memq #'openusage--on-shown window-configuration-change-hook)))
      (set-window-buffer nil previous))))

(ert-deftest openusage-test-mode-change-stops-timer ()
  "Leaving `openusage-mode' cancels the poll timer instead of orphaning it."
  (let ((previous (window-buffer))
        (buffer nil))
    (cl-flet ((polls ()
                (seq-filter (lambda (timer)
                              (and (eq (timer--function timer) #'openusage--poll)
                                   (memq buffer (timer--args timer))))
                            timer-list)))
      (unwind-protect
          (cl-letf (((symbol-function 'openusage--fetch) #'ignore))
            (setq buffer (openusage--open default-directory "openusage-test"))
            (openusage--open default-directory "openusage-test")
            (should (= (length (polls)) 1))
            (with-current-buffer buffer (text-mode))
            (should-not (polls)))
        (mapc #'cancel-timer (polls))
        (when (buffer-live-p buffer) (kill-buffer buffer))
        (set-window-buffer nil previous)))))

(ert-deftest openusage-test-signature-ignores-jitter ()
  (let* ((document (openusage-tests--fixture "combined.json"))
         (touched (copy-tree document)))
    (setf (alist-get 'generatedAt touched) "2099-01-01T00:00:00.000Z")
    (setf (alist-get 'fetchedAt (alist-get 'zai (alist-get 'providers touched))) "2026-09-28T14:22:25.123Z")
    (should (equal (openusage--document-signature document) (openusage--document-signature touched)))
    (setf (alist-get 'used (alist-get 'session (alist-get 'resources (alist-get 'zai (alist-get 'providers touched))))) 20)
    (should-not (equal (openusage--document-signature document) (openusage--document-signature touched)))))

;;; Fetching

(ert-deftest openusage-test-fetch-parses-program-output ()
  (let* ((dir (make-temp-file "openusage-bin-" t))
         (script (expand-file-name "openusage" dir)))
    (unwind-protect
        (progn
          (with-temp-file script
            (insert (format "#!/bin/sh\necho \"$@\" > %s/args\ncat %s\nexit 4\n"
                            (shell-quote-argument dir)
                            (shell-quote-argument
                             (expand-file-name "fixtures/combined.json" openusage-tests--dir)))))
          (set-file-modes script #o755)
          (let ((openusage-program script) result)
            (openusage--fetch "zai" dir t (lambda (document err) (setq result (list document err))))
            (with-timeout (5 (ert-fail "fetch timed out"))
              (while (not result) (accept-process-output nil 0.05)))
            (should (null (nth 1 result)))
            (should (equal (alist-get 'schema (car result)) openusage--schema))
            (should (equal (with-temp-buffer
                             (insert-file-contents (expand-file-name "args" dir))
                             (string-trim (buffer-string)))
                           "zai --force"))))
      (delete-directory dir t))))

(ert-deftest openusage-test-fetch-missing-program ()
  (let ((openusage-program "openusage-not-installed-anywhere") result)
    (openusage--fetch nil default-directory nil (lambda (document err) (setq result (list document err))))
    (should (equal result '(nil "openusage-not-installed-anywhere is not on PATH")))))

(provide 'openusage-tests)

;;; openusage-tests.el ends here
