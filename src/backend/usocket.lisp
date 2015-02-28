(in-package :cl-user)
(defpackage dexador.backend.usocket
  (:nicknames :dex.usocket)
  (:use :cl
        :dexador.util)
  (:import-from :usocket
                :socket-connect
                :socket-stream)
  (:import-from :fast-http
                :make-http-response
                :make-parser
                :http-status
                :http-headers)
  (:import-from :fast-io
                :make-output-buffer
                :finish-output-buffer
                :with-fast-output
                :fast-write-sequence
                :fast-write-byte)
  (:import-from :trivial-mimes
                :mime)
  (:import-from :quri
                :uri-p
                :uri-host
                :uri-port
                :uri-scheme
                :url-encode-params)
  (:import-from :chipz
                :decompress
                :make-dstate)
  (:import-from :cl+ssl
                :make-ssl-client-stream)
  (:import-from :alexandria
                :copy-stream
                :if-let)
  (:export :request))
(in-package :dexador.backend.usocket)

(defun-speedy read-until-crlf (stream)
  (with-fast-output (buf)
    (tagbody
     read-cr
       (loop for byte of-type (or (unsigned-byte 8) null) = (read-byte stream nil nil)
             if byte
               do (fast-write-byte byte buf)
             else
               do (go eof)
             until (= byte (char-code #\Return)))

     read-lf
       (let ((next-byte (read-byte stream nil nil)))
         (declare (type (or (unsigned-byte 8) null) next-byte))
         (cond
           ((null next-byte)
            (go eof))
           ((= next-byte (char-code #\Newline))
            (fast-write-byte next-byte buf))
           ((= next-byte (char-code #\Return))
            (fast-write-byte next-byte buf)
            (go read-lf))
           (T
            (fast-write-byte next-byte buf)
            (go read-cr))))
     eof)))

(defun read-response (stream has-body)
  (let* ((http (make-http-response))
         (body (make-output-buffer))
         (header-finished-p nil)
         (finishedp nil)
         (content-length nil)
         (parser (make-parser http
                              :header-callback
                              (lambda (headers)
                                (setq header-finished-p t
                                      content-length (gethash "content-length" headers))
                                (unless (and has-body
                                             (or content-length
                                                 (gethash "transfer-encoding" headers)))
                                  (setq finishedp t)))
                              :body-callback
                              (lambda (data start end)
                                (fast-write-sequence data body start end))
                              :finish-callback
                              (lambda ()
                                (setq finishedp t)))))
    (loop for buf of-type octets = (if (and header-finished-p
                                            content-length)
                                       (let ((buf (make-array content-length :element-type '(unsigned-byte 8))))
                                         (read-sequence buf stream)
                                         buf)
                                       (read-until-crlf stream))
          do (funcall parser buf)
          until (or finishedp
                    (zerop (length buf))))
    (values http (finish-output-buffer body))))

(defun print-verbose-data (&rest data)
  (format t "~&>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>~%")
  (dolist (d data)
    (map nil (lambda (byte)
               (princ (code-char byte)))
         d))
  (format t "~&>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>~%"))

(defun decompress-body (content-encoding body)
  (unless content-encoding
    (return-from decompress-body body))

  (cond
    ((string= content-encoding "gzip")
     (chipz:decompress nil (chipz:make-dstate :gzip) body))
    ((string= content-encoding "deflate")
     (chipz:decompress nil (chipz:make-dstate :deflate) body))
    (T body)))

(defun content-disposition (key val)
  (format nil "Content-Disposition: form-data; name=\"~A\"~:[~;~:*; filename=\"~A\"~]~C~C"
          key
          (and (pathnamep val)
               (file-namestring val))
          #\Return #\Newline))

(defun-speedy multipart-content-length (content boundary)
  (declare (type simple-string boundary))
  (let ((boundary-length (length boundary)))
    (+ (loop for (key . val) in content
             sum (+ 2 boundary-length 2
                    (length (the simple-string (content-disposition key val)))
                    (if (pathnamep val)
                        (+ #.(length "Content-Type: ") (length (the simple-string (mimes:mime val))) 2)
                        0)
                    2
                    (typecase val
                      (pathname (with-open-file (in val)
                                  (file-length in)))
                      (string (length val))
                      (otherwise (length (princ-to-string val))))
                    2))
       2 boundary-length 2 2)))

(defun write-multipart-content (content boundary stream)
  (let ((boundary (ascii-string-to-octets boundary)))
    (labels ((boundary-line (&optional endp)
               (write-sequence #.(ascii-string-to-octets "--") stream)
               (write-sequence boundary stream)
               (when endp
                 (write-sequence #.(ascii-string-to-octets "--") stream))
               (crlf))
             (crlf () (write-sequence +crlf+ stream)))
      (loop for (key . val) in content
            do (boundary-line)
               (write-sequence (ascii-string-to-octets (content-disposition key val)) stream)
               (when (pathnamep val)
                 (write-sequence
                  (ascii-string-to-octets
                   (format nil "Content-Type: ~A~C~C"
                           (mimes:mime val)
                           #\Return #\Newline))
                  stream))
               (crlf)
               (typecase val
                 (pathname (let ((buf (make-array 1024 :element-type '(unsigned-byte 8))))
                             (with-open-file (in val :element-type '(unsigned-byte 8))
                               (loop for n of-type fixnum = (read-sequence buf in)
                                     until (zerop n)
                                     do (write-sequence buf stream :end n)))))
                 (string (write-sequence (babel:string-to-octets val) stream))
                 (otherwise (write-sequence (babel:string-to-octets (princ-to-string val)) stream)))
               (crlf)
            finally
               (boundary-line t)))))

(defun-careful request (uri &key (method :get) (version 1.1)
                            content headers
                            (timeout *default-timeout*) keep-alive
                            (max-redirects 5)
                            ssl-key-file ssl-cert-file ssl-key-password
                            socket verbose)
  (declare (ignorable ssl-key-file ssl-cert-file ssl-key-password))
  (let* ((uri (if (quri:uri-p uri)
                  uri
                  (quri:uri uri)))
         (multipart-p (and (consp content)
                           (find-if #'pathnamep content :key #'cdr)))
         (form-urlencoded-p (and (consp content)
                                 (not multipart-p)))
         (boundary (and multipart-p
                        (make-random-string 12)))
         (content (if form-urlencoded-p
                      (quri:url-encode-params content)
                      content))
         (socket (or socket
                     (usocket:socket-connect (uri-host uri)
                                             (uri-port uri)
                                             :timeout timeout
                                             :element-type '(unsigned-byte 8))))
         (stream (usocket:socket-stream socket))
         (stream (if (string= (uri-scheme uri) "https")
                     #+dexador-no-ssl
                     (error "SSL not supported. Remove :dexador-no-ssl from *features* to enable SSL.")
                     #-dexador-no-ssl
                     (cl+ssl:make-ssl-client-stream stream
                                                    :certificate ssl-cert-file
                                                    :key ssl-key-file
                                                    :password ssl-key-password)
                     stream))
         (first-line-data
           (with-fast-output (buffer)
             (write-first-line method uri version buffer)))
         (headers-data
           (flet ((write-header* (name value)
                    (let ((header (assoc name headers :test #'string-equal)))
                      (if header
                          (when (cdr header)
                            (write-header name (cdr header)))
                          (write-header name value)))))
             (with-header-output (buffer)
               (write-header* :user-agent #.*default-user-agent*)
               (write-header* :host (uri-host uri))
               (write-header* :accept "*/*")
               (when (and keep-alive
                          (= version 1.0))
                 (write-header* :connection "keep-alive"))
               (cond
                 (multipart-p
                  (write-header* :content-type (format nil "multipart/form-data; boundary=~A" boundary))
                  (write-header* :content-length
                                 (multipart-content-length content boundary)))
                 (form-urlencoded-p
                  (write-header* :content-type "application/x-www-form-urlencoded")
                  (write-header* :content-length (length content)))
                 (t
                  (etypecase content
                    (null)
                    (string
                     (write-header* :content-type "text/plain")
                     (write-header* :content-length (length content)))
                    (pathname
                     (write-header* :content-type (mimes:mime content))
                     (if-let ((content-length (assoc :content-length headers :test #'string-equal)))
                       (write-header :content-length (cdr content-length))
                       (with-open-file (in content)
                         (write-header :content-length (file-length in))))))))

               ;; Custom headers
               (loop for (name . value) in headers
                     unless (member name '(:user-agent :host :accept
                                           :connection
                                           :content-type :content-length) :test #'string-equal)
                       do (write-header name value))
               (fast-write-sequence +crlf+ buffer)))))
    (write-sequence first-line-data stream)
    (write-sequence headers-data stream)
    (force-output stream)
    (when verbose
      (print-verbose-data first-line-data headers-data))

    ;; Sending the content
    (etypecase content
      (null)
      (string (write-sequence (babel:string-to-octets content) stream))
      (pathname (with-open-file (in content)
                  (copy-stream in stream)))
      (cons
       (write-multipart-content content boundary stream)))
    (force-output stream)

    (tagbody
     start-reading
       (multiple-value-bind (http body)
           (read-response stream (not (eq method :head)))
         (let ((status (http-status http))
               (response-headers (http-headers http)))
           (when (and (member status '(301 302 303 307) :test #'=)
                      (member method '(:get :head) :test #'eq)
                      (gethash "location" response-headers))
             (let* ((location-uri (quri:uri (gethash "location" response-headers)))
                    (next-first-line-data
                      (with-fast-output (buffer)
                        (write-first-line method location-uri version buffer))))
               (if (or (null (uri-host location-uri))
                       (and (string= (uri-host location-uri)
                                     (uri-host uri))
                            (eql (uri-port location-uri)
                                 (uri-port uri))))
                   (progn
                     (unless (= 0 max-redirects)
                       (when verbose
                         (print-verbose-data next-first-line-data headers-data))
                       (write-sequence next-first-line-data stream)
                       (write-sequence headers-data stream)
                       (force-output stream)
                       (decf max-redirects)
                       (go start-reading)))
                   (progn
                     (usocket:socket-close socket)
                     (return-from request
                       (request location-uri
                                :method method
                                :version version
                                :content content
                                :headers (nconc `((:host . ,(uri-host location-uri))) headers)
                                :timeout timeout
                                :keep-alive keep-alive
                                :max-redirects (1- max-redirects)
                                :verbose verbose))))))
           (unless keep-alive
             (usocket:socket-close socket))
           (return-from request
             (values (decompress-body (gethash "content-encoding" response-headers) body)
                     status
                     response-headers
                     (when keep-alive
                       socket))))))))
