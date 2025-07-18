;;; ghub-graphql.el --- Access Github API using GraphQL  -*- lexical-binding:t -*-

;; Copyright (C) 2016-2025 Jonas Bernoulli

;; Author: Jonas Bernoulli <emacs.ghub@jonas.bernoulli.dev>
;; Homepage: https://github.com/magit/ghub
;; Keywords: tools

;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published
;; by the Free Software Foundation, either version 3 of the License,
;; or (at your option) any later version.
;;
;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this file.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This library implements GraphQL queries for Github.

;;; Code:

(require 'ghub)
(require 'gsexp)
(require 'treepy)

(eval-when-compile (require 'subr-x))

(define-error 'ghub-graphql-error "GraphQL Error" 'ghub-error)

(defvar ghub-graphql-message-progress nil
  "Whether to show \"Fetching page N...\" in echo area during requests.
By default this information is only shown in the mode-line of the buffer
from which the request was initiated, and if you kill that buffer, then
nowhere.  That may make it desirable to display the same message in the
echo area as well.")

(defvar ghub-graphql-items-per-request 50
  "Number of GraphQL items to query for entities that return a collection.

Adjust this value if you're hitting query timeouts against larger
repositories.")

(cl-defun ghub-graphql-rate-limit (&key username auth host)
  "Return rate limit information."
  (let-alist (ghub-query
              '(query (rateLimit limit cost remaining resetAt)) nil
              :synchronous t :username username :auth auth :host host)
    .data.rateLimit))

(cl-defstruct (ghub--graphql-req
               (:include ghub--req)
               (:constructor ghub--make-graphql-req)
               (:copier nil))
  (query     nil :read-only t)
  (query-str nil :read-only nil)
  (variables nil :read-only t)
  (until     nil :read-only t)
  (pages     0   :read-only nil)
  (paginate  nil :read-only nil)
  (narrow    nil :read-only t))

(cl-defun ghub-query
    (query &optional variables
           &key until narrow headers paginate
           callback errorback noerror synchronous
           username auth host forge)
  (declare (indent defun))
  (unless forge
    (setq forge 'github))
  (unless host
    (setq host (ghub--host forge)))
  (unless (or username (stringp auth) (eq auth 'none))
    (setq username (ghub--username host forge)))
  (when (eq callback 'pp)
    (setq callback #'ghub--graphql-pp-response)
    (setq noerror t))
  (ghub--graphql-retrieve
   (ghub--make-graphql-req
    :url         (ghub--encode-url
                  host (if (eq forge 'gitlab) "/api/graphql" "/graphql"))
    :method      "POST"
    :headers     (ghub--headers headers host auth username forge)
    :handler     #'ghub--graphql-handle-response
    :query       query
    :variables   variables
    :until       until
    :buffer      (current-buffer)
    :narrow      narrow
    :paginate    (or paginate
                     (and-let* ((p (and (eq auth 'forge)
                                        (fboundp 'magit-get)
                                        (magit-get "forge.graphqlItemLimit"))))
                       (string-to-number p)))
    :noerror     noerror
    :synchronous synchronous
    :callback    callback
    :errorback   errorback)))

(cl-defun ghub--graphql-retrieve (req &optional lineage cursor)
  (let ((p (cl-incf (ghub--graphql-req-pages req))))
    (when (> p 1)
      (when ghub-graphql-message-progress
        (let ((message-log-max nil))
          (message "Fetching page %s..." p)))
      (ghub--graphql-set-mode-line req "Fetching page %s" p)))
  (setf (ghub--graphql-req-query-str req)
        (gsexp-encode
         (ghub--graphql-prepare-query
          (ghub--graphql-req-query req)
          lineage cursor)))
  (when ghub-debug
    (with-current-buffer (get-buffer-create " *gsexp-encode*")
      (erase-buffer)
      (insert (ghub--graphql-req-query-str req) "\n\n")
      (let ((pos (point)))
        (insert (ghub--encode-payload (ghub--graphql-req-variables req)) "\n")
        (ignore-errors (json-pretty-print pos (point))))))
  (ghub--retrieve
   (ghub--encode-payload
    `((query . ,(ghub--graphql-req-query-str req))
      ,@(and-let* ((variables (ghub--graphql-req-variables req)))
          `((variables . ,variables)))))
   req)
  (ghub--req-value req))

(defun ghub--graphql-prepare-query (query &optional lineage cursor paginate)
  (when lineage
    (setq query (ghub--graphql-narrow-query query lineage cursor)))
  (let ((loc (ghub--alist-zip query))
        variables)
    (catch :done
      (while t
        (let ((node (treepy-node loc)))
          (when (and (vectorp node)
                     (listp (aref node 0)))
            (let ((alist (append node ()))
                  (vars nil))
              (when-let ((edges (cadr (assq :edges alist))))
                (push (list 'first
                            (apply
                             #'min
                             (delq nil (list (and (numberp edges) edges)
                                             paginate
                                             ghub-graphql-items-per-request))))
                      vars)
                (setq loc  (treepy-up loc))
                (setq node (treepy-node loc))
                (setq loc  (treepy-replace
                            loc `(,(car  node)
                                  ,(cadr node)
                                  (pageInfo endCursor hasNextPage)
                                  (edges (node ,@(cddr node))))))
                (setq loc  (treepy-down loc))
                (setq loc  (treepy-next loc)))
              (dolist (elt alist)
                (cond ((keywordp (car elt)))
                      ((length= elt 3)
                       (push (list (nth 0 elt) (nth 1 elt)) vars)
                       (push (list (nth 1 elt) (nth 2 elt)) variables))
                      ((length= elt 2)
                       (push elt vars))))
              (setq loc (treepy-replace loc (vconcat (nreverse vars)))))))
        (if (treepy-end-p loc)
            (let ((node (copy-sequence (treepy-node loc))))
              (when variables
                (push (vconcat (nreverse variables))
                      (cdr node)))
              (throw :done node))
          (setq loc (treepy-next loc)))))))

(defun ghub--graphql-handle-response (status req)
  (let ((buf (current-buffer)))
    (unwind-protect
        (progn
          (set-buffer-multibyte t)
          (let* ((headers (ghub--handle-response-headers status req))
                 (payload (ghub--handle-response-payload req))
                 (err     (plist-get status :error))
                 (errors  (and (not (and (ghub--req-noerror req)
                                         (assq 'data payload)))
                               (assq 'errors payload))))
            (cond ((or err errors)
                   (when (and (not err) ghub-debug)
                     (ignore-errors (json-pretty-print (point) (point-max)))
                     (pop-to-buffer buf))
                   (ghub--graphql-handle-failure
                    req (or err errors) headers status))
                  ((ghub--graphql-walk-response req (assq 'data payload))))))
      (when (and (buffer-live-p buf)
                 (not (buffer-local-value 'ghub-debug buf)))
        (kill-buffer buf)))))

(defun ghub--graphql-handle-failure (req errors headers status)
  (ghub--graphql-set-mode-line req)
  (setf (ghub--req-value req) errors)
  (if-let ((errorback (ghub--req-errorback req)))
      (ghub--graphql-run-callback req errorback errors headers status req)
    (if (ghub--req-noerror req)
        (when-let ((callback (ghub--req-callback req)))
          (ghub--graphql-run-callback req callback errors))
      (ghub--signal-error (if (eq (car errors) 'errors)
                              (cons 'ghub-graphql-error (cdr errors))
                            errors)))))

(defun ghub--graphql-handle-success (req data)
  (ghub--graphql-set-mode-line req)
  (when-let ((narrow (ghub--graphql-req-narrow req)))
    (while-let ((key (pop narrow)))
      (setq data (cdr (assq key data)))))
  (setf (ghub--req-value req) data)
  (when-let ((callback (ghub--req-callback req)))
    (ghub--graphql-run-callback req callback data)))

(defun ghub--graphql-run-callback (req callback &rest args)
  (let ((buffer (ghub--req-buffer req)))
    (if (buffer-live-p buffer)
        (with-current-buffer buffer
          (apply callback args))
      (apply callback args))))

(defun ghub--graphql-set-mode-line (req &optional format &rest args)
  (let ((buffer (ghub--graphql-req-buffer req)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (setq mode-line-process
              (and format (concat " " (apply #'format format args))))
        (force-mode-line-update t)))))

(defun ghub--graphql-pp-response (data)
  (pp-display-expression data "*Pp Eval Output*"))

(defun ghub--graphql-walk-response (req data)
  (let* ((loc (ghub--req-value req))
         (loc (if (not loc)
                  (ghub--alist-zip data)
                (setq data (ghub--graphql-narrow-data
                            data (ghub--graphql-lineage loc)))
                (setf (alist-get 'edges data)
                      (append (alist-get 'edges (treepy-node loc))
                              (or (alist-get 'edges data)
                                  (error "BUG: Expected new nodes"))))
                (treepy-replace loc data))))
    (catch :done
      (while t
        (when (eq (car-safe (treepy-node loc)) 'edges)
          (setq loc (treepy-up loc))
          (pcase-let ((`(,key . ,val) (treepy-node loc)))
            (let-alist val
              (let* ((cursor (and .pageInfo.hasNextPage
                                  .pageInfo.endCursor))
                     (until  (cdr (assq (intern (format "%s-until" key))
                                        (ghub--graphql-req-until req))))
                     (nodes  (mapcar #'cdar .edges))
                     (nodes  (if until
                                 (seq-take-while
                                  (lambda (node)
                                    (or (string> (cdr (assq 'updatedAt node))
                                                 until)
                                        (setq cursor nil)))
                                  nodes)
                               nodes)))
                (cond (cursor
                       (setf (ghub--req-value req) loc)
                       (ghub--graphql-retrieve req
                                               (ghub--graphql-lineage loc)
                                               cursor)
                       (throw :done nil))
                      ((setq loc (treepy-replace loc (cons key nodes)))))))))
        (if (treepy-end-p loc)
            (progn (ghub--graphql-handle-success req (treepy-root loc))
                   (throw :done nil))
          (setq loc (treepy-next loc)))))))

(defun ghub--graphql-lineage (loc)
  (let (lineage)
    (while (treepy-up loc)
      (push (car (treepy-node loc)) lineage)
      (setq loc (treepy-up loc)))
    lineage))

(defun ghub--graphql-narrow-data (data lineage)
  (while-let ((key (pop lineage)))
    (if (consp (car lineage))
        (progn (pop lineage)
               (setf data (cadr data)))
      (setq data (assq key (cdr data)))))
  data)

(defun ghub--graphql-narrow-query (query lineage &optional cursor)
  (if (consp (car lineage))
      (let* ((child  (cddr query))
             (alist  (append (cadr query) ()))
             (single (cdr (assq :singular alist))))
        `(,(car single)
          ,(vector (list (cadr single) (cdr (car lineage))))
          ,@(if (cdr lineage)
                (ghub--graphql-narrow-query child (cdr lineage) cursor)
              child)))
    (let* ((child  (or (assq (car lineage) (cdr query))
                       ;; Alias
                       (cl-find-if (lambda (c)
                                     (eq (car-safe (car-safe c))
                                         (car lineage)))
                                   query)
                       ;; Edges
                       (cl-find-if (lambda (c)
                                     (and (listp c)
                                          (vectorp (cadr c))
                                          (eq (cadr (assq :singular
                                                          (append (cadr c) ())))
                                              (car lineage))))
                                   (cdr query))
                       (error "BUG: Failed to narrow query")))
           (object (car query))
           (args   (and (vectorp (cadr query))
                        (cadr query))))
      `(,object
        ,@(and args (list args))
        ,(cond ((cdr lineage)
                (ghub--graphql-narrow-query child (cdr lineage) cursor))
               (cursor
                `(,(car child)
                  ,(vconcat `((after ,cursor))
                            (cadr child))
                  ,@(cddr child)))
               (t
                child))))))

(defun ghub--alist-zip (root)
  (let ((branchp (##and (listp %) (listp (cdr %))))
        (make-node (lambda (_ children) children)))
    (treepy-zipper branchp #'identity make-node root)))

;;; _
(provide 'ghub-graphql)
;;; ghub-graphql.el ends here
