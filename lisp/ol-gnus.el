;;; ol-gnus.el --- Links to Gnus Groups and Messages -*- lexical-binding: t; -*-

;; Copyright (C) 2004-2025 Free Software Foundation, Inc.

;; Author: Carsten Dominik <carsten.dominik@gmail.com>
;;         Tassilo Horn <tassilo at member dot fsf dot org>
;; Keywords: outlines, hypermedia, calendar, text
;; URL: https://orgmode.org
;;
;; This file is part of GNU Emacs.
;;
;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;;; Commentary:

;; This file implements links to Gnus groups and messages from within Org.
;; Org mode loads this module by default - if this is not what you want,
;; configure the variable `org-modules'.

;;; Code:

(require 'org-macs)
(org-assert-version)

(require 'gnus-sum)
(require 'gnus-util)
(require 'nnheader)
(or (require 'nnselect nil t)           ; Emacs >= 28
    (require 'nnir nil t))              ; Emacs < 28
(require 'ol)


;;; Declare external functions and variables

(declare-function gnus-activate-group "gnus-start" (group &optional scan dont-check method dont-sub-check))
(declare-function gnus-find-method-for-group "gnus" (group &optional info))
(declare-function gnus-article-show-summary "gnus-art" ())
(declare-function gnus-group-group-name "gnus-group")
(declare-function gnus-group-jump-to-group "gnus-group" (group &optional prompt))
(declare-function gnus-group-read-group "gnus-group" (&optional all no-article group select-articles))
(declare-function message-fetch-field "message" (header &optional not-all))
(declare-function message-generate-headers "message" (headers))
(declare-function message-narrow-to-headers "message")
(declare-function message-tokenize-header "message" (header &optional separator))
(declare-function message-unquote-tokens "message" (elems))
(declare-function nnvirtual-map-article "nnvirtual" (article))

(defvar gnus-newsgroup-name)
(defvar gnus-summary-buffer)
(defvar gnus-other-frame-object)


;;; Customization variables

(defcustom org-gnus-prefer-web-links nil
  "If non-nil, `org-store-link' creates web links to Google groups.
\\<org-mode-map>When nil, Gnus will be used for such links.
Using a prefix argument to the command `\\[org-store-link]' (`org-store-link')
negates this setting for the duration of the command."
  :group 'org-link-store
  :type 'boolean)

(defcustom org-gnus-no-server nil
  "Should Gnus be started using `gnus-no-server'?"
  :group 'org-link-follow
  :version "24.4"
  :package-version '(Org . "8.0")
  :type 'boolean)


;;; Install the link type

(org-link-set-parameters "gnus"
			 :follow #'org-gnus-open
			 :store #'org-gnus-store-link)

;;; Implementation

(defun org-gnus-group-link (group)
  "Create a link to the Gnus group GROUP.
If GROUP is a newsgroup and `org-gnus-prefer-web-links' is
non-nil, create a link to groups.google.com.  Otherwise create a
link to the group inside Gnus.

If `org-store-link' was called with a prefix arg the meaning of
`org-gnus-prefer-web-links' is reversed."
  (let ((unprefixed-group (replace-regexp-in-string "^[^:]+:" "" group)))
    (if (and (string-prefix-p "nntp" group) ;; Only for nntp groups
	     (org-xor current-prefix-arg
		      org-gnus-prefer-web-links))
	(concat "https://groups.google.com/group/" unprefixed-group)
      (concat "gnus:" group))))

(defun org-gnus-article-link (group newsgroups message-id x-no-archive)
  "Create a link to a Gnus article.

The article is specified by its MESSAGE-ID.  Additional
parameters are the Gnus GROUP, the NEWSGROUPS the article was
posted to and the X-NO-ARCHIVE header value of that article.

If GROUP is a newsgroup and `org-gnus-prefer-web-links' is
non-nil, create a link to groups.google.com.
Otherwise create a link to the article inside Gnus.

If `org-store-link' was called with a prefix arg the meaning of
`org-gnus-prefer-web-links' is reversed."
  (if (and (org-xor current-prefix-arg org-gnus-prefer-web-links)
	   newsgroups		  ;make web links only for nntp groups
	   (not x-no-archive))	  ;and if X-No-Archive isn't set
      (format "https://groups.google.com/groups/search?as_umsgid=%s"
	      (url-encode-url message-id))
    (concat "gnus:" group "#" message-id)))

(defun org-gnus-store-link (&optional _interactive?)
  "Store a link to a Gnus folder or message."
  (pcase major-mode
    (`gnus-group-mode
     (let ((group (gnus-group-group-name)))
       (when group
	 (org-link-store-props :type "gnus" :group group)
	 (let ((description (org-gnus-group-link group)))
	   (org-link-add-props :link description :description description)
	   description))))
    ((or `gnus-summary-mode `gnus-article-mode)
     (let* ((group
	     (pcase (gnus-find-method-for-group gnus-newsgroup-name)
	       (`(nnvirtual . ,_)
		(with-current-buffer gnus-summary-buffer
		  (save-excursion
		    (car (nnvirtual-map-article (gnus-summary-article-number))))))
	       (`(,(or `nnselect `nnir) . ,_)  ; nnir is for Emacs < 28.
		(with-current-buffer gnus-summary-buffer
		  (save-excursion
		    (cond
		     ((fboundp 'nnselect-article-group)
		      (nnselect-article-group (gnus-summary-article-number)))
		     ((fboundp 'nnir-article-group)
		      (nnir-article-group (gnus-summary-article-number)))
		     (t
		      (error "No article-group variant bound"))))))
	       (_ gnus-newsgroup-name)))
	    (header (with-current-buffer gnus-summary-buffer
		      (save-excursion
			(gnus-summary-article-header))))
	    (from (mail-header-from header))
	    (message-id (org-unbracket-string "<" ">" (mail-header-id header)))
	    (date (org-trim (mail-header-date header)))
	    ;; Remove text properties of subject string to avoid Emacs
	    ;; bug #3506.
	    (subject (org-no-properties
		      (copy-sequence (mail-header-subject header))))
	    (to (cdr (assq 'To (mail-header-extra header))))
	    newsgroups x-no-archive)
       ;; Fetching an article is an expensive operation; newsgroup and
       ;; x-no-archive are only needed for web links.
       (when (org-xor current-prefix-arg org-gnus-prefer-web-links)
	 ;; Make sure the original article buffer is up-to-date.
	 (save-window-excursion (gnus-summary-select-article))
	 (setq to (or to (gnus-fetch-original-field "To")))
	 (setq newsgroups (gnus-fetch-original-field "Newsgroups"))
	 (setq x-no-archive (gnus-fetch-original-field "x-no-archive")))
       (org-link-store-props :type "gnus" :from from :date date :subject subject
			     :message-id message-id :group group :to to)
       (let ((link (org-gnus-article-link
		    group newsgroups message-id x-no-archive))
	     (description (org-link-email-description)))
	 (org-link-add-props :link link :description description)
	 link)))
    (`message-mode
     (setq org-store-link-plist nil)	;reset
     (save-excursion
       (save-restriction
	 (message-narrow-to-headers)
	 (unless (message-fetch-field "Message-ID")
	   (message-generate-headers '(Message-ID)))
	 (goto-char (point-min))
	 (re-search-forward "^Message-ID:" nil t)
	 (put-text-property (line-beginning-position) (line-end-position)
			    'message-deletable nil)
	 (let ((gcc (org-last (message-unquote-tokens
			       (message-tokenize-header
				(mail-fetch-field "gcc" nil t) " ,"))))
	       (id (org-unbracket-string "<" ">"
		     (mail-fetch-field "Message-ID")))
	       (to (mail-fetch-field "To"))
	       (from (mail-fetch-field "From"))
	       (subject (mail-fetch-field "Subject"))
	       ) ;; newsgroup xarchive	;those are always nil for gcc
	   (unless gcc (error "Can not create link: No Gcc header found"))
	   (org-link-store-props :type "gnus" :from from :subject subject
				 :message-id id :group gcc :to to)
	   (let ((link (org-gnus-article-link gcc nil id nil)) ;;newsgroup xarchive
		 (description (org-link-email-description)))
	     (org-link-add-props :link link :description description)
	     link)))))))

(defun org-gnus-open-nntp (path)
  "Follow the nntp: link specified by PATH."
  (let* ((spec (split-string path "/"))
	 (server (split-string (nth 2 spec) "@"))
	 (group (nth 3 spec))
	 (article (nth 4 spec)))
    (org-gnus-follow-link
     (format "nntp+%s:%s" (or (cdr server) (car server)) group)
     article)))

(defun org-gnus-open (path _)
  "Follow the Gnus message or folder link specified by PATH."
  (unless (string-match "\\`\\([^#]+\\)\\(#\\(.*\\)\\)?" path)
    (error "Error in Gnus link %S" path))
  (let ((group (match-string-no-properties 1 path))
	(article (match-string-no-properties 3 path)))
    (org-gnus-follow-link group article)))

(defun org-gnus-follow-link (&optional group article)
  "Follow a Gnus link to GROUP and ARTICLE."
  (require 'gnus)
  (funcall (org-link-frame-setup-function 'gnus))
  (when gnus-other-frame-object
    (if (not (frame-live-p gnus-other-frame-object))
        ;; Error out in case org-link-frame-setup did not take care of setting up
        ;; the gnus frame if was activate previously.
        (error "Couldn't select \'gnus-other-frame-object\', make sure it is active"))
    (select-frame gnus-other-frame-object))
  (let ((group (org-no-properties group))
	(article (org-no-properties article)))
    (cond
     ((and group article)
      (gnus-activate-group group)
      (condition-case nil
	  (let ((msg "Couldn't follow Gnus link.  Summary couldn't be opened."))
	    (pcase (gnus-find-method-for-group group)
	      (`(nndoc . ,_)
	       (if (gnus-group-read-group t nil group)
		   (gnus-summary-goto-article article nil t)
		 (message msg)))
	      (_
	       (let ((articles 1)
		     group-opened)
		 (while (and (not group-opened)
			     ;; Stop on integer overflows.  Note: We
			     ;; can drop this once we require at least
			     ;; Emacs 27, which supports bignums.
			     (> articles 0))
		   (setq group-opened (gnus-group-read-group articles t group))
		   (setq articles (if (< articles 16)
				      (1+ articles)
				    (* articles 2))))
		 (if group-opened
		     (gnus-summary-goto-article article nil t)
		   (message msg))))))
	(quit
	 (message "Couldn't follow Gnus link.  The linked group is empty."))))
     (group (gnus-group-jump-to-group group)))))

(defun org-gnus-no-new-news (&optional other-frame)
  "Like `\\[gnus]' but doesn't check for new news.
In case of OTHER-FRAME or `gnus-other-frame-object' call `gnus-other-frame'.

Ensures that `gnus-other-frame' is activated correctly if dead."
  (let ((action (cond  (org-gnus-no-server #'gnus-no-server)
	               (t #'gnus))))
    (cond ((or other-frame gnus-other-frame-object)
           (let ((gnus-other-frame-function action)
                 (gnus-other-frame-resume-function action))
             (gnus-other-frame)))
          (t (if (not (gnus-alive-p))
                 (funcall action))))))

(defun org-gnus-no-new-news-other-frame ()
  "Like `org-gnus-no-new-news' but always in another frame."
    (org-gnus-no-new-news t))


(provide 'ol-gnus)

;;; ol-gnus.el ends here
