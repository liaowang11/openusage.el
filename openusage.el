;;; openusage.el --- Live OpenUsage limits and pacing -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Copyright (C) 2026 Bill and contributors

;; Author: Bill
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))
;; Keywords: tools, convenience
;; URL: https://github.com/liaowang11/openusage.el

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; A live view of the `openusage' command line tool from OpenUsage
;; (https://github.com/robinebers/openusage), which reports AI coding
;; plan limits as `openusage.limits.v1' JSON.
;;
;; - `openusage' opens the overview: one card per limit, laid out like
;;   the app's: the pace verdict (running out, cutting it close), a
;;   progress bar, then the amount left and when it resets.
;; - `openusage-provider' opens one provider in detail: reset times,
;;   raw counts, window progress, burn rate and the end-of-window
;;   projection, every balance and the cache age.
;;
;; Both buffers poll while visible and follow `default-directory', so a
;; buffer visiting a TRAMP remote shows that host's usage.  The pace
;; rules, colours and wording port the OpenUsage app's own meter logic.
;;
;; In either buffer: TAB folds the provider at point, S-TAB cycles every
;; provider like `org-shifttab', RET opens the provider at point in its
;; detail buffer (or refreshes with nothing at point), `n' and `p' move
;; between providers, `g' forces a refresh and `q' quits.  `imenu'
;; lists the providers.

;;; Code:

(require 'color)
(require 'iso8601)
(require 'seq)
(require 'subr-x)
(require 'svg)
(require 'text-property-search)

(defgroup openusage nil
  "Live OpenUsage limits and pacing."
  :group 'tools
  :prefix "openusage-")

(defcustom openusage-program "openusage"
  "The OpenUsage command line tool, looked up on the target host's PATH."
  :type 'string)

(defcustom openusage-poll-interval 5
  "Seconds between polls of a visible OpenUsage buffer.
Polls read OpenUsage's shared five-minute cache, so they are cheap; a
hidden buffer is not polled."
  :type 'number)

(defcustom openusage-expand-by-default t
  "Whether a provider is expanded the first time a buffer shows it.
Only supplies the default for a provider never folded by hand, so
toggling one provider with `openusage-toggle' never affects another."
  :type 'boolean)

(defcustom openusage-usage-display 'left
  "Whether bounded limits read as what is left or what is used.
Mirrors the app's \"Show Usage As\" setting: `left' shows \"52% left\"
with the bar draining, `used' shows \"48% used\" with the bar filling."
  :type '(choice (const :tag "Left" left) (const :tag "Used" used)))

(defcustom openusage-reset-display 'countdown
  "How reset and run-out times read.
Mirrors the app's \"Reset Times\" setting: `countdown' reads \"Resets in
3h 25m\", `exact' reads \"Resets today at 18:38\"."
  :type '(choice (const :tag "Countdown" countdown) (const :tag "Exact time" exact)))

(defcustom openusage-always-show-pacing nil
  "Whether limits on track show their projection and even-pace tick.
Mirrors the app's \"Always Show Pacing\": when nil, pacing only shows on
a limit cutting it close or running out; when non-nil, on-track limits
also read \"~33% left at reset\" and mark where even use would be now."
  :type 'boolean)

(defcustom openusage-time-format "%H:%M"
  "`format-time-string' format for the time of day in exact times."
  :type 'string)

(defcustom openusage-bar-width 44
  "Columns a limit card spans, its progress bar included."
  :type 'natnum)

(defcustom openusage-labels
  '(("apiUsage" . "Other Models")
    ("autoUsage" . "Cursor Models")
    ("onDemand" . "Extra Usage")
    ("extraUsageBalance" . "Extra Balance")
    ("premiumCredits" . "Credits")
    ("cursor.credits" . "Extra Usage")
    ("antigravity.geminiSession" . "Session")
    ("antigravity.geminiWeekly" . "Weekly")
    ("antigravity.nonGeminiSession" . "Claude")
    ("antigravity.nonGeminiWeekly" . "Claude Weekly"))
  "Display labels for resource ids, matching the OpenUsage app's titles.
A key is either a resource id, or PROVIDER.RESOURCE to override it for
one provider only.  An id with no entry is split from camelCase and
title-cased, so \"webSearches\" reads \"Web Searches\"."
  :type '(alist :key-type string :value-type string))

(defcustom openusage-resource-order
  '("session" "daily" "weekly" "monthly"
    "geminiSession" "geminiWeekly" "nonGeminiSession" "nonGeminiWeekly"
    "sonnet" "fable" "spark" "sparkWeekly"
    "totalUsage" "grokBot" "autoUsage" "apiUsage" "premiumCredits"
    "chat" "completions" "webSearches" "requests" "keyLimit"
    "onDemand" "extraUsage" "orgCredits" "orgSpend"
    "credits" "creditValue" "balance" "extraUsageBalance" "rateLimitResets")
  "Resource ids in the order a provider lists them.
The command line tool sorts resources alphabetically; this puts them
back in the app's order.  Ids not listed follow, in the tool's order."
  :type '(repeat string))

(defconst openusage--field-type
  '(set (const :tag "Pace verdict beside the label" verdict)
        (const :tag "Progress bar" bar)
        (const :tag "Reset time, or the limit with no reset" resets)
        (const :tag "Raw used / limit, for non-percent limits" used)
        (const :tag "Window progress" window)
        (const :tag "Pace and burn rate" pace)
        (const :tag "Projection at reset" projection)
        (const :tag "Balance expiry dates" expiries)
        (const :tag "Balances at zero" zero-balances)
        (const :tag "Cache fetched and expiry times" cache))
  "Customization type of `openusage-overview-fields' and `openusage-detail-fields'.")

(defcustom openusage-overview-fields '(verdict bar resets)
  "What the overview buffer, `openusage', shows.
The label and the amount left or used always show.  Any field listed
in `openusage-detail-fields' can move here too."
  :type openusage--field-type)

(defcustom openusage-detail-fields
  '(verdict bar resets used window pace projection expiries zero-balances cache)
  "What a provider's detail buffer, `openusage-provider', shows.
The label and the amount left or used always show."
  :type openusage--field-type)

(defface openusage-provider
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for a provider's display name.")

(defface openusage-label
  '((t :weight bold))
  "Face for a limit's label.")

(defface openusage-detail
  '((t :inherit shadow))
  "Face for secondary text: plans, reset times and detail lines.")

(defface openusage-normal
  '((t :inherit success))
  "Face for a limit on track or with plenty left.")

(defface openusage-warning
  '((t :inherit warning))
  "Face for a limit cutting it close.")

(defface openusage-critical
  '((t :inherit error))
  "Face for a limit spent or projected to run out before it resets.")

(defconst openusage--schema "openusage.limits.v1"
  "The only JSON schema this package reads.")

;;; Formatting

(defun openusage--parse-timestamp (value)
  "Return ISO 8601 string VALUE as a float time."
  (float-time (encode-time (iso8601-parse value))))

(defun openusage--camel-words (id)
  "Split camelCase ID into title-cased words."
  (let ((case-fold-search nil))
    (mapconcat #'capitalize
               (split-string (replace-regexp-in-string "\\([[:lower:][:digit:]]\\)\\([[:upper:]]\\)"
                                                       "\\1 \\2" id))
               " ")))

(defun openusage--label (provider-id resource-id)
  "Return the display label of RESOURCE-ID under PROVIDER-ID."
  (or (cdr (assoc (format "%s.%s" provider-id resource-id) openusage-labels))
      (cdr (assoc resource-id openusage-labels))
      (openusage--camel-words resource-id)))

(defun openusage--compact-duration (seconds)
  "Format SECONDS like the app: \"2d 6h\", \"4h 22m\", \"4h\" or \"5m\".
Rounds up to whole minutes; at the day scale the hours always show."
  (let* ((total (max 1 (ceiling (/ seconds 60.0))))
         (days (/ total 1440))
         (hours (/ (% total 1440) 60))
         (minutes (% total 60)))
    (cond ((> days 0) (format "%dd %dh" days hours))
          ((> hours 0) (if (> minutes 0) (format "%dh %dm" hours minutes) (format "%dh" hours)))
          (t (format "%dm" minutes)))))

(defun openusage--when-label (time now &optional mode)
  "Return when TIME falls relative to NOW, in MODE.
MODE defaults to `openusage-reset-display'.  `countdown' gives \"2d 6h\",
`exact' gives \"today at 18:38\", \"tomorrow at 09:00\" or \"Oct 3 at
18:38\".  A time past or within five minutes reads \"soon\"."
  (let ((seconds (- time now)))
    (pcase (or mode openusage-reset-display)
      ('countdown (if (<= seconds 300) "soon" (openusage--compact-duration seconds)))
      (_ (if (<= seconds 0)
             "soon"
           (let ((days (- (time-to-days time) (time-to-days now)))
                 (clock (format-time-string openusage-time-format time)))
             (cond ((<= days 0) (format "today at %s" clock))
                   ((= days 1) (format "tomorrow at %s" clock))
                   (t (format "%s at %s" (format-time-string "%b %-d" time) clock)))))))))

(defun openusage--deadline-label (prefix time now &optional mode)
  "Return PREFIX and when TIME falls relative to NOW, in MODE.
Reads \"Resets in 2h 5m\", \"Resets today at 18:38\" or \"Resets soon\";
a nil PREFIX leaves just \"in 2h 5m\"."
  (let ((phrase (openusage--when-label time now mode)))
    (string-join (delq nil (list prefix
                                 (and (eq (or mode openusage-reset-display) 'countdown)
                                      (not (equal phrase "soon"))
                                      "in")
                                 phrase))
                 " ")))

(defun openusage--thousands (value)
  "Format VALUE with comma thousands and two decimals."
  (let* ((text (format "%.2f" (abs value)))
         (dot (string-search "." text))
         (digits (substring text 0 dot))
         (groups nil))
    (while (> (length digits) 3)
      (push (substring digits -3) groups)
      (setq digits (substring digits 0 -3)))
    (push digits groups)
    (concat (if (< value 0) "-" "") (string-join groups ",") (substring text dot))))

(defun openusage--number (value)
  "Format VALUE with no trailing zeros."
  (format "%g" (float value)))

(defun openusage--amount (value unit)
  "Format VALUE in UNIT: \"52%\", \"$12.50\" or \"821 credits\"."
  (pcase unit
    ("percent" (format "%d%%" (round value)))
    ("usd" (concat "$" (openusage--thousands value)))
    ((or 'nil "") (openusage--number value))
    (_ (format "%s %s" (openusage--number value) unit))))

(defun openusage--short-amount (value unit)
  "Format VALUE in UNIT without a count unit: \"52%\", \"$12.50\" or \"14\"."
  (if (member unit '("percent" "usd"))
      (openusage--amount value unit)
    (openusage--number value)))

(defun openusage--display-round (value unit)
  "Round VALUE to the precision the headline shows it at in UNIT."
  (if (equal unit "usd")
      (/ (round (* value 100)) 100.0)
    (round value)))

;;; Pacing, ported from the app's Pace.swift and WidgetData.meterState

(defun openusage--window (resource now)
  "Return (ELAPSED . WINDOW) seconds of RESOURCE's reset window at NOW.
Nil when RESOURCE has no reset window."
  (let ((resets-at (alist-get 'resetsAt resource))
        (window (alist-get 'windowSeconds resource)))
    (when (and resets-at window (> window 0))
      (cons (- now (- (openusage--parse-timestamp resets-at) window)) (float window)))))

(defun openusage--settled-p (window)
  "Return non-nil when enough of WINDOW has passed to project from.
WINDOW is (ELAPSED . PERIOD) from `openusage--window'.  Settled from a
minute or 1% in, whichever is later, until the window ends."
  (and (>= (car window) (max 60 (* (cdr window) 0.01)))
       (< (car window) (cdr window))))

(defun openusage--pace (resource now)
  "Return the pace of RESOURCE at NOW as (STATUS . PROJECTED), or nil.
STATUS is `ahead' (projected to finish with 10% or more to spare),
`on-track' (inside the last 10%) or `behind' (past the limit).
PROJECTED is the end-of-window usage at the current burn rate.  Nil
when nothing is used yet, or too little of the window has passed for
a stable projection."
  (let ((used (alist-get 'used resource))
        (limit (alist-get 'limit resource))
        (window (openusage--window resource now)))
    (when (and used limit window (> limit 0) (> used 0) (openusage--settled-p window))
      (let ((projected (* (/ used (car window)) (cdr window))))
        (cons (cond ((>= used limit) 'behind)
                    ((<= projected (* limit 0.9)) 'ahead)
                    ((<= projected limit) 'on-track)
                    (t 'behind))
              projected)))))

(defun openusage--level (used limit)
  "Return the severity of USED against LIMIT with no pace to go on.
Warning from 80% used, critical from 90%, rounded to whole percent."
  (let ((percent (round (* 100 (min 1.0 (max 0.0 (/ (float used) limit)))))))
    (cond ((>= percent 90) 'critical)
          ((>= percent 80) 'warning)
          (t 'normal))))

(defun openusage--meter (resource now)
  "Return the meter state of bounded RESOURCE at NOW as a plist.
:state is `spent', `running-out', `close', `healthy' or `level';
:severity is `normal', `warning' or `critical'.  `running-out' carries
:eta, the float time the limit runs out (nil when it lands right at
the reset); `close' and `healthy' carry :projected, the projected share
used at the reset.  Precedence follows the app: spent, then the pace
verdict, then plain levels."
  (let* ((used (alist-get 'used resource))
         (limit (alist-get 'limit resource))
         (unit (alist-get 'unit resource))
         (pace (openusage--pace resource now)))
    (cond
     ((<= (openusage--display-round (- limit used) unit) 0)
      (list :state 'spent :severity 'critical))
     ((and pace (eq (car pace) 'ahead))
      (list :state 'healthy :severity 'normal :projected (/ (cdr pace) limit)))
     ((and pace (>= (/ (float used) limit) 0.05))
      (let ((projected (/ (cdr pace) limit)))
        (if (and (eq (car pace) 'on-track) (>= (round (* 100 (- 1 projected))) 1))
            (list :state 'close :severity 'warning :projected projected)
          (list :state 'running-out :severity 'critical :projected projected
                :eta (openusage--run-out resource now (cdr pace))))))
     (t (list :state 'level :severity (openusage--level used limit))))))

(defun openusage--run-out (resource now projected)
  "Return the float time bounded RESOURCE runs out at NOW's burn rate.
PROJECTED is its end-of-window usage.  Nil unless that lands before
the reset."
  (let* ((window (cdr (openusage--window resource now)))
         (rate (/ projected window))
         (eta (/ (- (alist-get 'limit resource) (alist-get 'used resource)) rate))
         (left (- (openusage--parse-timestamp (alist-get 'resetsAt resource)) now)))
    (when (and (> eta 0) (< eta left))
      (+ now eta))))

(defun openusage--verdict (meter now)
  "Return the card's pace text for METER at NOW, or the empty string."
  (pcase (plist-get meter :state)
    ('spent "! Limit reached")
    ('running-out
     (if-let* ((eta (plist-get meter :eta)))
         (concat "! " (openusage--deadline-label "Limit" eta now))
       "!"))
    ('close (format "~%d%% spare" (round (* 100 (- 1 (plist-get meter :projected))))))
    ('healthy
     (if openusage-always-show-pacing
         (format "~%d%% left at reset" (round (* 100 (- 1 (plist-get meter :projected)))))
       ""))
    (_ "")))

(defun openusage--projection (meter)
  "Return where METER's pace lands at the reset, or nil with no pace."
  (let ((projected (plist-get meter :projected)))
    (pcase (plist-get meter :state)
      ('healthy (format "~%d%% left at reset" (round (* 100 (- 1 projected)))))
      ('close (format "~%d%% used at reset" (round (* 100 projected))))
      ('running-out
       (if (> projected 1)
           (format "~%d%% over limit at reset" (round (* 100 (- projected 1))))
         "~100% used at reset")))))

(defun openusage--tick (meter resource now)
  "Return the even-pace tick of RESOURCE at NOW as a bar fraction, or nil.
It marks where even use would put the bar right now.  METER decides
whether it shows: on limits cutting it close or running out, and on
healthy ones only with `openusage-always-show-pacing'."
  (let ((window (openusage--window resource now)))
    (when (and window
               (memq (plist-get meter :state)
                     (if openusage-always-show-pacing '(healthy close running-out) '(close running-out)))
               (openusage--settled-p window))
      (let ((elapsed (/ (car window) (cdr window))))
        (if (eq openusage-usage-display 'left) (- 1 elapsed) elapsed)))))

;;; Progress bar: SVG rail in a GUI, eighth-block glyphs on a tty

(defconst openusage--eighths [?▏ ?▎ ?▍ ?▌ ?▋ ?▊ ?▉]
  "Glyphs for a cell N/8 filled, at index N-1.")

(defvar openusage--fields nil
  "Fields the buffer being rendered shows.
Bound by `openusage-render' from `openusage-overview-fields' or
`openusage-detail-fields'.")

(defun openusage--field-p (field)
  "Return non-nil when the buffer being rendered shows FIELD."
  (memq field openusage--fields))

(defvar openusage--render-frame nil
  "Graphic frame the SVG bars are sized and coloured for, or nil.
Bound around a render; nil leaves the glyph bars bare.")

(defun openusage--severity-face (severity)
  "Return the face for SEVERITY."
  (pcase severity
    ('critical 'openusage-critical)
    ('warning 'openusage-warning)
    (_ 'openusage-normal)))

(defun openusage--glyph-bar (fraction tick width)
  "Return a glyph bar WIDTH cells wide, filled to FRACTION, with TICK marked."
  (let* ((eighths (round (* fraction width 8)))
         (full (min width (/ eighths 8)))
         (partial (% eighths 8))
         (cells (make-vector width ?░)))
    (dotimes (index full) (aset cells index ?█))
    (when (and (> partial 0) (< full width))
      (aset cells full (aref openusage--eighths (1- partial))))
    (when tick
      (aset cells (min (1- width) (truncate (* tick width))) ?┊))
    (concat cells)))

(defun openusage--blend (from to alpha)
  "Return colour FROM mixed into TO by ALPHA, as a hex string."
  (apply #'color-rgb-to-hex
         (append (seq-mapn (lambda (a b) (+ (* alpha a) (* (- 1 alpha) b)))
                           (color-name-to-rgb from) (color-name-to-rgb to))
                 '(2))))

(defun openusage--svg-bar (fraction tick colors width height)
  "Return an SVG image of a rail filled to FRACTION, with TICK marked.
COLORS is (FILL TRACK TICK); WIDTH and HEIGHT are in pixels."
  (let* ((rail 6)
         (y (/ (- height rail) 2))
         (svg (svg-create width height)))
    (svg-rectangle svg 0 y width rail :rx 3 :fill (nth 1 colors))
    (when (> fraction 0)
      (svg-rectangle svg 0 y (max rail (* fraction width)) rail :rx 3 :fill (nth 0 colors)))
    (when tick
      (svg-rectangle svg (min (- width 2) (* tick width)) (- y 3) 2 (+ rail 6) :fill (nth 2 colors)))
    (svg-image svg :ascent 'center)))

(defun openusage--bar (fraction tick severity)
  "Return the progress bar for FRACTION with TICK, coloured for SEVERITY.
The text is a glyph bar, which a tty shows; with
`openusage--render-frame' set, a `display' SVG rail covers it in a GUI."
  (let* ((face (openusage--severity-face severity))
         (bar (propertize (openusage--glyph-bar fraction tick openusage-bar-width) 'face face))
         (frame openusage--render-frame))
    (if (not frame)
        bar
      (let ((fg (face-foreground 'default frame t))
            (bg (face-background 'default frame t)))
        (propertize bar 'display
                    (openusage--svg-bar
                     fraction tick
                     (list (face-foreground face frame t) (openusage--blend fg bg 0.15) fg)
                     (* openusage-bar-width (frame-char-width frame))
                     (frame-char-height frame)))))))

(defun openusage--graphic-frame (buffer)
  "Return a graphic frame to draw BUFFER's SVG bars for, or nil."
  (when (image-type-available-p 'svg)
    (or (seq-find #'display-graphic-p
                  (mapcar #'window-frame (get-buffer-window-list buffer nil t)))
        (seq-find #'display-graphic-p (frame-list)))))

;;; Rendering

(defun openusage--spread (left right)
  "Put LEFT flush left and RIGHT flush right across `openusage-bar-width'."
  (if (string-empty-p right)
      left
    (concat left
            (make-string (max 1 (- openusage-bar-width (string-width left) (string-width right))) ?\s)
            right)))

(defvar openusage--label-width 12
  "Width of the widest label in the provider being rendered.")

(defun openusage--label-column (label)
  "Return LABEL in the label face, padded to the value column."
  (concat (propertize label 'face 'openusage-label)
          (make-string (1+ (max 0 (- openusage--label-width (string-width label)))) ?\s)))

(defun openusage--bounded-p (resource)
  "Return non-nil when RESOURCE is a consumption limit with a bound."
  (and (equal (alist-get 'kind resource) "consumption")
       (alist-get 'limit resource) (> (alist-get 'limit resource) 0)
       (alist-get 'used resource)))

(defun openusage--whole-usd (value)
  "Format VALUE in dollars, with cents only when it is not whole."
  (if (= value (round value))
      (concat "$" (string-remove-suffix ".00" (openusage--thousands value)))
    (openusage--amount value "usd")))

(defun openusage--card-context (resource now)
  "Return the text right of bounded RESOURCE's amount at NOW, or nil.
The app's trailing label: when the limit resets, with the other reset
format as its `help-echo'; with no reset time, the window length, a
dollar limit, or the count unit."
  (let ((resets-at (alist-get 'resetsAt resource))
        (window (alist-get 'windowSeconds resource))
        (unit (alist-get 'unit resource)))
    (cond
     (resets-at
      (let ((time (openusage--parse-timestamp resets-at)))
        (propertize (openusage--deadline-label "Resets" time now)
                    'help-echo (openusage--deadline-label
                                "Resets" time now
                                (if (eq openusage-reset-display 'countdown) 'exact 'countdown)))))
     ((and window (> window 0)) (concat "Resets in " (openusage--compact-duration window)))
     ((equal unit "usd") (concat (openusage--whole-usd (alist-get 'limit resource)) " limit"))
     ((and unit (not (member unit '("" "percent")))) unit))))

(defun openusage--card (label resource now)
  "Return the card of bounded RESOURCE under LABEL at NOW.
Laid out like the app's card: the label with the pace verdict, the bar,
then the amount with when it resets.  `openusage--fields' picks the
verdict, bar and reset."
  (let* ((meter (openusage--meter resource now))
         (severity (plist-get meter :severity))
         (face (openusage--severity-face severity))
         (used (alist-get 'used resource))
         (limit (alist-get 'limit resource))
         (unit (alist-get 'unit resource))
         (left-p (eq openusage-usage-display 'left))
         (amount (if left-p (max 0 (- limit used)) used))
         (fraction (min 1.0 (max 0.0 (/ (float amount) limit))))
         (verdict (if (openusage--field-p 'verdict) (openusage--verdict meter now) ""))
         (context (and (openusage--field-p 'resets) (openusage--card-context resource now))))
    (concat
     "  "
     (openusage--spread
      (propertize label 'face 'openusage-label)
      (propertize verdict 'face (if (memq severity '(warning critical)) face 'openusage-detail)))
     (when (openusage--field-p 'bar)
       (concat "\n  " (openusage--bar fraction (openusage--tick meter resource now) severity)))
     "\n  "
     (openusage--spread
      (propertize (format "%s %s" (openusage--short-amount amount unit) (if left-p "left" "used"))
                  'face face)
      (propertize (or context "") 'face 'openusage-detail)))))

(defun openusage--expiries (resource)
  "Return RESOURCE's expiry times as a sorted list of float times."
  (let ((value (alist-get 'expiresAt resource)))
    (sort (mapcar #'openusage--parse-timestamp (delq nil (if (listp value) value (list value))))
          #'<)))

(defun openusage--expiry-severity (time now)
  "Return the severity of an expiry at TIME seen at NOW, as the app does."
  (let ((left (- time now)))
    (cond ((<= left (* 48 3600)) 'critical)
          ((<= left (* 7 86400)) 'warning)
          (t 'normal))))

(defun openusage--balance-line (label resource now)
  "Return the one-line row of balance RESOURCE under LABEL at NOW."
  (let* ((expiries (openusage--expiries resource))
         (value (openusage--amount (alist-get 'available resource) (alist-get 'unit resource))))
    (concat "  " (openusage--label-column label)
            (if expiries
                (propertize value 'face (openusage--severity-face
                                         (openusage--expiry-severity (car expiries) now)))
              value))))

(defun openusage--usage-line (label resource)
  "Return the one-line row of unbounded consumption RESOURCE under LABEL."
  (concat "  " (openusage--label-column label)
          (openusage--amount (alist-get 'used resource) (alist-get 'unit resource)) " used"))

(defun openusage--detail-line (field value)
  "Return a detail line reading FIELD then VALUE."
  (propertize (format "      %-10s %s" field value) 'face 'openusage-detail))

(defun openusage--rate (used elapsed unit)
  "Return the burn rate of USED over ELAPSED seconds in UNIT.
Per hour for windows under a day of use so far, else per day."
  (let* ((per-day (>= elapsed 86400))
         (rate (/ used (/ elapsed (if per-day 86400.0 3600.0))))
         (amount (pcase unit
                   ("percent" (format "%.1f%%" rate))
                   ("usd" (format "$%.2f" rate))
                   ((or 'nil "") (format "%.1f" rate))
                   (_ (format "%.1f %s" rate unit)))))
    (format "%s / %s" amount (if per-day "day" "hour"))))

(defun openusage--card-details (resource now)
  "Return the detail lines `openusage--fields' shows for bounded RESOURCE at NOW."
  (let* ((used (alist-get 'used resource))
         (limit (alist-get 'limit resource))
         (unit (alist-get 'unit resource))
         (window (openusage--window resource now))
         (meter (openusage--meter resource now))
         (projection (openusage--projection meter)))
    (delq nil
          (list
           (when (and (openusage--field-p 'used) (not (equal unit "percent")))
             (openusage--detail-line "used" (format "%s / %s" (openusage--short-amount used unit)
                                                    (openusage--amount limit unit))))
           (when (and (openusage--field-p 'window) window (> (car window) 0) (< (car window) (cdr window)))
             (openusage--detail-line "window" (format "%s of %s elapsed (%d%%)"
                                                      (openusage--compact-duration (car window))
                                                      (openusage--compact-duration (cdr window))
                                                      (round (* 100 (/ (car window) (cdr window)))))))
           (when (and (openusage--field-p 'pace) (openusage--pace resource now))
             (openusage--detail-line "pace" (format "%.2f× even · %s"
                                                    (/ (/ (float used) limit) (/ (car window) (cdr window)))
                                                    (openusage--rate used (car window) unit))))
           (when (and (openusage--field-p 'projection) projection)
             (openusage--detail-line "at reset" projection))))))

(defun openusage--balance-rows (label resource now)
  "Return the rows of balance RESOURCE under LABEL at NOW, or nil to skip it.
`openusage--fields' picks the expiry lines and whether an empty balance shows."
  (when (or (openusage--field-p 'zero-balances)
            (> (openusage--display-round (alist-get 'available resource) (alist-get 'unit resource)) 0))
    (string-join
     (cons (openusage--balance-line label resource now)
           (and (openusage--field-p 'expiries)
                (mapcar (lambda (time)
                          (openusage--detail-line
                           "expires" (format "%s (%s)"
                                             (openusage--when-label time now 'exact)
                                             (openusage--deadline-label nil time now 'countdown))))
                        (openusage--expiries resource))))
     "\n")))

(defun openusage--resource-rows (provider-id resource now)
  "Return the rows of RESOURCE under PROVIDER-ID at NOW, or nil to skip it.
RESOURCE is a (ID . FIELDS) entry; `openusage--fields' picks the rows."
  (let* ((resource-id (symbol-name (car resource)))
         (fields (cdr resource))
         (label (openusage--label provider-id resource-id))
         (kind (alist-get 'kind fields))
         (text
          (cond
           ((openusage--bounded-p fields)
            (string-join (cons (openusage--card label fields now)
                               (openusage--card-details fields now))
                         "\n"))
           ((and (equal kind "balance") (alist-get 'available fields))
            (openusage--balance-rows label fields now))
           ((and (equal kind "consumption") (alist-get 'used fields))
            (openusage--usage-line label fields)))))
    (when text
      (propertize text 'openusage-key (list 'resource provider-id resource-id)))))

(defun openusage--sort-resources (resources)
  "Return RESOURCES ordered by `openusage-resource-order'."
  (let ((rank (lambda (resource)
                (or (seq-position openusage-resource-order (symbol-name (car resource)))
                    (length openusage-resource-order)))))
    (seq-sort-by rank #'< resources)))

(defun openusage--expanded-p (expanded key)
  "Return the fold state of KEY in hash table EXPANDED.
A key never folded by hand falls back to `openusage-expand-by-default';
one folded to nil stays folded."
  (gethash key expanded openusage-expand-by-default))

(defun openusage--provider-section (provider-id provider errors now expanded detail)
  "Return the section of PROVIDER under PROVIDER-ID at NOW.
ERRORS are its refresh errors, EXPANDED the fold table, and DETAIL
non-nil renders the detail buffer's fuller form."
  (let* ((key (cons 'provider provider-id))
         (open (or detail (openusage--expanded-p expanded key)))
         (plan (alist-get 'plan provider))
         (header (propertize (or (alist-get 'displayName provider) provider-id)
                             'face 'openusage-provider))
         (lines nil))
    (when (and plan (not (string-empty-p plan)))
      (setq header (concat header (propertize (format " · %s" plan) 'face 'openusage-detail))))
    (when (eq (alist-get 'stale provider) t)
      (setq header (concat header (propertize "  ! stale" 'face 'openusage-warning))))
    (unless open
      (setq header (concat header (propertize " …" 'face 'openusage-detail))))
    (push (propertize header 'openusage-key key) lines)
    (when open
      (when (and (openusage--field-p 'cache) (alist-get 'fetchedAt provider))
        (push (propertize
               (format "  fetched %s · cache %s %s"
                       (format-time-string "%H:%M:%S" (openusage--parse-timestamp (alist-get 'fetchedAt provider)))
                       (if (eq (alist-get 'stale provider) t) "stale since" "fresh until")
                       (format-time-string "%H:%M:%S" (openusage--parse-timestamp (alist-get 'expiresAt provider))))
               'face 'openusage-detail)
              lines))
      (dolist (err errors)
        (push (propertize (format "  ! %s" (or (alist-get 'message err) "Refresh failed."))
                          'face 'error)
              lines))
      (when-let* ((resources (openusage--sort-resources (alist-get 'resources provider)))
                  (openusage--label-width
                   (apply #'max 12 (mapcar (lambda (resource)
                                             (string-width
                                              (openusage--label provider-id (symbol-name (car resource)))))
                                           resources)))
                  (rows (delq nil (mapcar (lambda (resource)
                                            (openusage--resource-rows provider-id resource now))
                                          resources))))
        (when detail (push "" lines))
        (push (string-join rows (if detail "\n\n" "\n")) lines)))
    (string-join (nreverse lines) "\n")))

(defun openusage-render (document now expanded &optional detail)
  "Render DOCUMENT, parsed `openusage.limits.v1' JSON, at float time NOW.
EXPANDED is a hash table of provider fold states.  DETAIL non-nil
renders as the detail buffer does: every provider open, spaced out, and
showing `openusage-detail-fields' instead of `openusage-overview-fields'."
  (unless (equal (alist-get 'schema document) openusage--schema)
    (error "Unsupported OpenUsage schema: %S" (alist-get 'schema document)))
  (let ((providers (alist-get 'providers document))
        (errors (alist-get 'errors document))
        (openusage--fields (if detail openusage-detail-fields openusage-overview-fields))
        (sections nil))
    (dolist (entry providers)
      (let ((provider-id (symbol-name (car entry))))
        (push (openusage--provider-section
               provider-id (cdr entry)
               (seq-filter (lambda (err) (equal (alist-get 'providerId err) provider-id)) errors)
               now expanded detail)
              sections)))
    (dolist (err errors)
      (let ((provider-id (or (alist-get 'providerId err) "unknown")))
        (unless (assq (intern provider-id) providers)
          (push (concat (propertize (openusage--camel-words provider-id) 'face 'openusage-provider)
                        "  "
                        (propertize (format "! %s" (or (alist-get 'message err) "No current data."))
                                    'face 'error))
                sections))))
    (string-join (nreverse sections) "\n\n")))

;;; Fetching, TRAMP-aware

(defun openusage--parse-output (buffer exit-status callback)
  "Parse BUFFER's JSON and call CALLBACK with (DOCUMENT ERROR).
OpenUsage exits nonzero on a partial refresh failure yet still prints
usable JSON, so only a parse failure counts as an error.  Its message
is the first line of output that is not JSON, else one naming
EXIT-STATUS."
  (let ((document (with-current-buffer buffer
                    (goto-char (point-min))
                    (ignore-errors (json-parse-buffer :object-type 'alist :array-type 'list)))))
    (if (and (consp document) (equal (alist-get 'schema document) openusage--schema))
        (funcall callback document nil)
      (let ((line (car (split-string (with-current-buffer buffer (buffer-string)) "\n" t "[ \t\r]+"))))
        (funcall callback nil
                 (if (and line (not (consp document)))
                     (string-remove-prefix "openusage: " line)
                   (format "%s exited %d with no usable output" openusage-program exit-status)))))))

(defun openusage--fetch (provider directory force callback)
  "Run `openusage-program' for PROVIDER in DIRECTORY, then call CALLBACK.
PROVIDER nil means every enabled provider; FORCE non-nil bypasses the
shared cache.  DIRECTORY selects the host, so a TRAMP directory runs the
tool there.  CALLBACK receives (DOCUMENT ERROR).  Return the process,
or nil when CALLBACK already ran without one.  The process has no
separate stderr, so OpenUsage's warnings and errors land in the same
buffer as its JSON, after it."
  (let* ((default-directory (or directory default-directory))
         (remote (file-remote-p default-directory)))
    (if (not (executable-find openusage-program remote))
        (ignore (funcall callback nil (format "%s is not on PATH" openusage-program)))
      (let ((stdout (generate-new-buffer " *openusage-stdout*")))
        (make-process
         :name "openusage"
         :buffer stdout
         :command (append (list openusage-program) (and provider (list provider)) (and force (list "--force")))
         :file-handler t
         :noquery t
         :sentinel
         (lambda (process _event)
           (unless (process-live-p process)
             (unwind-protect
                 (openusage--parse-output stdout (process-exit-status process) callback)
               (kill-buffer stdout)))))))))

;;; The live buffers

(defvar-local openusage--directory nil "Directory whose host this buffer shows.")
(defvar-local openusage--provider nil "Provider id of a detail buffer, or nil for the overview.")
(defvar-local openusage--timer nil "Poll timer of this buffer.")
(defvar-local openusage--signature nil "Signature of the last painted document and minute.")
(defvar-local openusage--last-error nil "Last fetch error reported, so it is not repeated.")
(defvar-local openusage--process nil "Process of the latest fetch.")
(defvar-local openusage--document nil "Last successfully parsed document.")
(defvar-local openusage--expanded nil "Hash table of provider fold states.")

(defun openusage--truncate-timestamps (value)
  "Return VALUE with fractional seconds dropped from every timestamp."
  (cond
   ((and (consp value) (consp (car value)) (symbolp (caar value)) (caar value))
    (mapcar (lambda (pair) (cons (car pair) (openusage--truncate-timestamps (cdr pair)))) value))
   ((listp value) (mapcar #'openusage--truncate-timestamps value))
   ((and (stringp value) (string-match "\\`\\([0-9-]+T[0-9:]+\\)\\.[0-9]+Z\\'" value))
    (concat (match-string 1 value) "Z"))
   (t value)))

(defun openusage--document-signature (document)
  "Return DOCUMENT's data, ignoring `generatedAt' and sub-second jitter."
  (openusage--truncate-timestamps
   (list (alist-get 'providers document) (alist-get 'errors document))))

(defun openusage--key-at-point ()
  "Return the `openusage-key' of the line at point."
  (get-text-property (pos-bol) 'openusage-key))

(defun openusage--goto-key (key)
  "Move point to the line carrying KEY, compared with `equal'."
  (goto-char (point-min))
  (when-let* ((key)
              (match (text-property-search-forward 'openusage-key key t)))
    (goto-char (prop-match-beginning match))))

(defun openusage--repaint ()
  "Redraw this buffer from its last document, keeping point's entry.
Every window showing the buffer keeps its own entry too, since
`erase-buffer' would move them all to the top."
  (when openusage--document
    (let ((inhibit-read-only t)
          (key (openusage--key-at-point))
          (windows (mapcar (lambda (window)
                             (cons window (save-excursion
                                            (goto-char (window-point window))
                                            (openusage--key-at-point))))
                           (get-buffer-window-list nil nil t)))
          (openusage--render-frame (openusage--graphic-frame (current-buffer))))
      (erase-buffer)
      (insert (openusage-render openusage--document (float-time) openusage--expanded
                                openusage--provider))
      (pcase-dolist (`(,window . ,window-key) windows)
        (openusage--goto-key window-key)
        (set-window-point window (point)))
      (openusage--goto-key key))))

(defun openusage--show (document)
  "Paint DOCUMENT unless its data and the minute are unchanged.
Countdowns and pace move with the clock, so an unchanged document
still repaints once a minute."
  (setq openusage--last-error nil
        openusage--document document)
  (let ((signature (cons (floor (float-time) 60) (openusage--document-signature document))))
    (unless (equal signature openusage--signature)
      (openusage--repaint)
      (setq openusage--signature signature))))

(defun openusage--show-error (message)
  "Report fetch error MESSAGE once, and paint it if nothing else shows."
  (unless (equal message openusage--last-error)
    (setq openusage--last-error message)
    (message "openusage: %s" message))
  (unless openusage--document
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (propertize (format "openusage: %s" message) 'face 'error)))))

(defun openusage--refresh (force)
  "Fetch and repaint, unless a fetch is already in flight.
FORCE non-nil bypasses the shared cache and replaces a fetch in
flight, so a hung one cannot wedge the buffer; only the latest
fetch's result is shown.  A fetch that signals before its process
starts, such as a dead TRAMP connection, is reported like any other
error instead of leaving the buffer stuck."
  (when (and force (process-live-p openusage--process))
    (let ((stale openusage--process))
      (setq openusage--process nil)
      (delete-process stale)))
  (unless (process-live-p openusage--process)
    ;; Cleared first: a fetch that fails at once calls back before it
    ;; returns, and must match.
    (setq openusage--process nil)
    (let ((buffer (current-buffer))
          process)
      (condition-case err
          (setq process
                (openusage--fetch
                 openusage--provider openusage--directory force
                 (lambda (document message)
                   (when (buffer-live-p buffer)
                     (with-current-buffer buffer
                       (when (eq process openusage--process)
                         (if message (openusage--show-error message) (openusage--show document))))))))
        (error
         (openusage--show-error (error-message-string err))))
      (setq openusage--process process))))

(defun openusage--poll (buffer)
  "Refresh BUFFER from the cache while it is visible."
  (when (and (buffer-live-p buffer) (get-buffer-window buffer 'visible))
    (with-current-buffer buffer
      (openusage--refresh nil))))

(defun openusage--on-shown (window)
  "Freshen this buffer the moment WINDOW starts showing it again.
Repaint from the last document so its countdowns are current, and
start fetching at once instead of waiting for the next poll tick.
Run from `window-buffer-change-functions', which also calls it when
WINDOW stops showing the buffer, so that call is skipped; unlike
`window-configuration-change-hook' it ignores resizes and layout
changes that leave each window's buffer as it was."
  (when (eq (window-buffer window) (current-buffer))
    (openusage--repaint)
    (openusage--poll (current-buffer))))

(defun openusage--cancel-timer ()
  "Stop this buffer's poll timer."
  (when (timerp openusage--timer)
    (cancel-timer openusage--timer)))

(defun openusage--revert (&optional _ignore-auto _noconfirm)
  "Force a fresh pull, bypassing the shared cache."
  (setq openusage--signature nil)
  (openusage--refresh t))

(defun openusage-toggle ()
  "Fold or unfold the provider at point."
  (interactive)
  (let ((key (openusage--key-at-point)))
    (unless (eq (car-safe key) 'provider)
      (user-error "Nothing foldable at point"))
    (puthash key (not (openusage--expanded-p openusage--expanded key)) openusage--expanded)
    (openusage--repaint)))

(defun openusage-cycle ()
  "Cycle every provider's fold, the way `org-shifttab' cycles headings.
With any provider open, fold them all; otherwise open them all."
  (interactive)
  (let* ((keys (mapcar (lambda (entry) (cons 'provider (symbol-name (car entry))))
                       (alist-get 'providers openusage--document)))
         (expand (not (seq-some (lambda (key) (openusage--expanded-p openusage--expanded key)) keys))))
    (dolist (key keys)
      (puthash key expand openusage--expanded))
    (openusage--repaint)
    (message (if expand "SHOW ALL" "OVERVIEW"))))

(defun openusage-visit ()
  "Open the provider at point in its detail buffer.
With nothing at point, force a fresh pull instead."
  (interactive)
  (pcase (openusage--key-at-point)
    (`(provider . ,provider-id) (openusage-provider provider-id openusage--directory))
    (`(resource ,provider-id . ,_) (openusage-provider provider-id openusage--directory))
    (_ (openusage--refresh t))))

(defun openusage--provider-line (direction)
  "Return the start of the provider header DIRECTION lines away, or nil.
DIRECTION is 1 to search forward, -1 backward; the search never wraps."
  (save-excursion
    (let (found)
      (while (and (not found) (zerop (forward-line direction)))
        (when (eq (car-safe (openusage--key-at-point)) 'provider)
          (setq found (point))))
      found)))

(defun openusage-next-provider ()
  "Move to the next provider's header, without wrapping."
  (interactive)
  (goto-char (or (openusage--provider-line 1) (user-error "No next provider"))))

(defun openusage-previous-provider ()
  "Move to the previous provider's header, without wrapping."
  (interactive)
  (goto-char (or (openusage--provider-line -1) (user-error "No previous provider"))))

(defun openusage--imenu-index ()
  "Return an `imenu' index of the providers in this buffer."
  (save-excursion
    (goto-char (point-min))
    (let ((providers (alist-get 'providers openusage--document))
          (index nil)
          match)
      (while (setq match (text-property-search-forward
                          'openusage-key 'provider
                          (lambda (kind key) (eq kind (car-safe key)))))
        (let ((provider-id (cdr (prop-match-value match))))
          (push (cons (or (alist-get 'displayName (alist-get (intern provider-id) providers))
                          provider-id)
                      (prop-match-beginning match))
                index)))
      (nreverse index))))

(defvar-keymap openusage-mode-map
  :doc "Keymap for `openusage-mode'."
  "TAB" #'openusage-toggle
  "<backtab>" #'openusage-cycle
  "RET" #'openusage-visit
  "n" #'openusage-next-provider
  "p" #'openusage-previous-provider)

(define-derived-mode openusage-mode special-mode "OpenUsage"
  "Major mode for a live OpenUsage buffer.
The buffer polls OpenUsage's cache every `openusage-poll-interval'
seconds while visible; a window showing it again repaints and fetches
at once.  \\[revert-buffer] forces a fresh pull.

\\{openusage-mode-map}"
  (setq-local revert-buffer-function #'openusage--revert
              imenu-create-index-function #'openusage--imenu-index
              truncate-lines t
              openusage--expanded (make-hash-table :test 'equal))
  (add-hook 'kill-buffer-hook #'openusage--cancel-timer nil t)
  (add-hook 'change-major-mode-hook #'openusage--cancel-timer nil t)
  (add-hook 'window-buffer-change-functions #'openusage--on-shown nil t))

(defun openusage--buffer-name (directory provider)
  "Return the buffer name for PROVIDER on DIRECTORY's host."
  (let ((host (file-remote-p directory 'host)))
    (format "*OpenUsage%s%s*"
            (if host (format ": %s" host) "")
            (if provider (format " (%s)" provider) ""))))

(defun openusage--open (directory provider)
  "Show and refresh the buffer for PROVIDER on DIRECTORY's host."
  (let* ((directory (or directory default-directory))
         (buffer (get-buffer-create (openusage--buffer-name directory provider))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'openusage-mode)
        (openusage-mode))
      (setq openusage--directory directory
            openusage--provider provider)
      (unless (timerp openusage--timer)
        (setq openusage--timer (run-with-timer openusage-poll-interval openusage-poll-interval
                                               #'openusage--poll buffer)))
      (openusage--refresh nil))
    (pop-to-buffer buffer)))

(defun openusage--known-providers (directory)
  "Return provider ids from the overview buffer for DIRECTORY's host."
  (when-let* ((buffer (get-buffer (openusage--buffer-name directory nil))))
    (mapcar (lambda (entry) (symbol-name (car entry)))
            (alist-get 'providers (buffer-local-value 'openusage--document buffer)))))

;;;###autoload
(defun openusage (&optional directory)
  "Open the live OpenUsage overview for DIRECTORY's host.
DIRECTORY defaults to `default-directory', so a buffer visiting a TRAMP
remote shows that host.  With a prefix argument, prompt for it."
  (interactive
   (list (if current-prefix-arg
             (read-directory-name "Host (directory): " default-directory)
           default-directory)))
  (openusage--open directory nil))

;;;###autoload
(defun openusage-provider (provider &optional directory)
  "Open PROVIDER's live OpenUsage detail buffer for DIRECTORY's host.
PROVIDER is a provider id such as \"claude\"; a family id shows every
account of that family.  With a prefix argument, prompt for DIRECTORY."
  (interactive
   (let ((directory (if current-prefix-arg
                        (read-directory-name "Host (directory): " default-directory)
                      default-directory)))
     (list (completing-read "Provider: " (openusage--known-providers directory))
           directory)))
  (openusage--open directory provider))

(provide 'openusage)

;;; openusage.el ends here
