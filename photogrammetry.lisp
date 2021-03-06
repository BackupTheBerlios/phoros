;;; PHOROS -- Photogrammetric Road Survey
;;; Copyright (C) 2010, 2011 Bert Burgemeister
;;;
;;; This program is free software; you can redistribute it and/or modify
;;; it under the terms of the GNU General Public License as published by
;;; the Free Software Foundation; either version 2 of the License, or
;;; (at your option) any later version.
;;;
;;; This program is distributed in the hope that it will be useful,
;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;; GNU General Public License for more details.
;;;
;;; You should have received a copy of the GNU General Public License along
;;; with this program; if not, write to the Free Software Foundation, Inc.,
;;; 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

(in-package :phoros-photogrammetry)

#-sbcl (defun nan-p (x)
	  (declare (float x))
	  (/= x x))
#+sbcl (defun nan-p (x)
	 (sb-ext:float-nan-p x))

(defgeneric photogrammetry (mode photo-1 &optional photo-2)
  (:documentation "Call to photogrammetry library.  Dispatch on mode."))

(defmethod photogrammetry :around (mode clicked-photo &optional other-photo)
  "Prepare and clean up a run of photogrammetry."
  (declare (ignore other-photo))
  (bt:with-lock-held (*photogrammetry-mutex*)
    (del-all)
    (unwind-protect
         (call-next-method)
      (del-all))))

(defmethod photogrammetry
    ((mode (eql :epipolar-line)) clicked-photo &optional other-photo)
  "Return in an alist an epipolar line in coordinates of other-photo
from m and n in clicked-photo."
  (add-cam* clicked-photo)
  (add-bpoint* clicked-photo)
  (add-global-car-reference-point* clicked-photo t)
  (add-cam* other-photo)
  (add-global-car-reference-point* other-photo t)
  (loop
     with m and n
     for i = 2d0 then (* i 1.4) until (> i 50)
     do (set-distance-for-epipolar-line i)
     when (ignore-errors
            (calculate)
            (setf m (get-m))
            (setf n (get-n))
            (assert (not (nan-p m)))  ;On some systems, PhoML gives us
            (assert (not (nan-p n)))  ; quiet NaN instead of erring.
            t)
     collect (pairlis '(:m :n)
                      (list (flip-m-maybe m other-photo)
                            (flip-n-maybe n other-photo)))))

(defmethod photogrammetry
    ((mode (eql :reprojection)) photo &optional global-point)
  "Calculate reprojection from photo."
  (add-cam* photo)
  (add-global-measurement-point* global-point)
  (add-global-car-reference-point* photo)
  (set-global-reference-frame)
  (calculate)
  (let ((m (get-m))
	(n (get-n)))
    (assert (not (nan-p m)))          ;On some systems, PhoML gives us
    (assert (not (nan-p n)))          ; quiet NaN instead of erring.
    (pairlis '(:m :n)
	     (list (flip-m-maybe m photo) (flip-n-maybe n photo)))))

(defmethod photogrammetry
    ((mode (eql :multi-position-intersection)) photos &optional other-photo)
  "Calculate intersection from photos."
  (declare (ignore other-photo))
  (set-global-reference-frame)
  (loop
     for photo in photos
     do
       (add-cam* photo)
       (add-bpoint* photo)
       (add-global-car-reference-point* photo t))
  (calculate)
  (let ((x-global (get-x-global))
        (y-global (get-y-global))
        (z-global (get-z-global))
        (stdx-global (get-stdx-global))
        (stdy-global (get-stdy-global))
        (stdz-global (get-stdz-global)))
    (assert (not (nan-p x-global)))
    (assert (not (nan-p y-global)))
    (assert (not (nan-p z-global)))
    (assert (not (nan-p stdx-global)))
    (assert (not (nan-p stdy-global)))
    (assert (not (nan-p stdz-global)))
    (pairlis '(:x-global :y-global :z-global
               :stdx-global :stdy-global :stdz-global)
             (list
              x-global y-global z-global
              stdx-global stdy-global stdz-global))))

(defmethod photogrammetry
    ((mode (eql :intersection)) photo &optional other-photo)
  "Calculate intersection from two photos that are taken out of the
same local coordinate system.  (Used for debugging only)."
  (add-cam* photo)
  (add-bpoint* photo)
  (add-cam* other-photo)
  (add-bpoint* other-photo)
  (calculate)
  (pairlis '(:x-local :y-local :z-local
             :stdx-local :stdy-local :stdz-local)
           (list
            (get-x-local) (get-y-local) (get-z-local)
            (get-stdx-local) (get-stdy-local) (get-stdz-local)
            (get-x-global) (get-y-global) (get-z-global))))

(defmethod photogrammetry ((mode (eql :mono)) photo &optional floor)
  "Return in an alist the intersection point of the ray through m and
n in photo, and floor."
  (add-cam* photo)
  (add-bpoint* photo)
  (add-ref-ground-surface* floor)
  (add-global-car-reference-point* photo)
  (set-global-reference-frame)
  (calculate)
  (pairlis '(:x-global :y-global :z-global)
          (list
           (get-x-global) (get-y-global) (get-z-global))))

(defun point-radians-to-degrees (point)
  "Convert (the first and second element of) point from radians to
degrees."
  (setf (first point) (proj:radians-to-degrees (first point)))
  (setf (second point) (proj:radians-to-degrees (second point)))
  point)

(defmethod photogrammetry ((mode (eql :footprint)) photo
                           &optional (floor photo))
  "Return image footprint as a list of five polygon points, wrapped in
an alist."
  (set-global-reference-frame)
  (add-cam* photo)
  (add-global-car-reference-point* photo t)
  (add-ref-ground-surface* floor)
  (set-distance-for-epipolar-line 20d0) ;how far ahead we look
  (calculate)
  (let ((source-cs
         (car (photogrammetry-arglist photo :cartesian-system))))
    (acons
     :footprint
     (loop
        for i in '(0 1 2 3 0) collect
          (point-radians-to-degrees
           (proj:cs2cs (list (get-fp-easting i)
                             (get-fp-northing i)
                             (get-fp-e-height i))
                       :source-cs source-cs)))
     nil)))

(defun flip-m-maybe (m photo)
  "Flip coordinate m when :mounting-angle in photo suggests it
necessary."
  (if (= 180 (cdr (assoc :mounting-angle photo)))
      (- (cdr (assoc :sensor-width-pix photo)) m)
      m))
(defun flip-n-maybe (n photo)
  "Flip coordinate n when :mounting-angle in photo suggests it
necessary."
  (if (zerop (cdr (assoc :mounting-angle photo)))
      (- (cdr (assoc :sensor-height-pix photo)) n)
      n))

(defun photogrammetry-arglist (alist &rest keys)
  "Construct an arglist from alist values corresponding to keys."
  (mapcar #'(lambda (x) (cdr (assoc x alist))) keys))

(defun add-cam* (photo-alist)
  "Call add-cam with arguments taken from photo-alist."
  (let ((integer-args
         (photogrammetry-arglist
          photo-alist :sensor-height-pix :sensor-width-pix))
        (double-float-args
         (mapcar #'(lambda (x) (coerce x 'double-float))
                 (photogrammetry-arglist photo-alist
                                         :pix-size
                                         :dx :dy :dz :omega :phi :kappa
                                         :c :xh :yh
                                         :a-1 :a-2 :a-3 :b-1 :b-2
					 :c-1 :c-2 :r-0
                                         :b-dx :b-dy :b-dz :b-ddx :b-ddy :b-ddz
                                         :b-rotx :b-roty :b-rotz
                                         :b-drotx :b-droty :b-drotz))))
    (apply #'add-cam (nconc integer-args double-float-args))))

(defun add-bpoint* (photo-alist)
  "Call add-bpoint with arguments taken from photo-alist."
    (add-bpoint
     (coerce (flip-m-maybe (cdr (assoc :m photo-alist)) photo-alist)
	     'double-float)
     (coerce (flip-n-maybe (cdr (assoc :n photo-alist)) photo-alist)
	     'double-float)))

(defun add-ref-ground-surface* (floor-alist)
  "Call add-ref-ground-surface with arguments taken from floor-alist."
  (let ((double-float-args
         (mapcar #'(lambda (x) (coerce x 'double-float))
                 (photogrammetry-arglist floor-alist
                                         :nx :ny :nz :d))))
    (apply #'add-ref-ground-surface double-float-args)))

(defun add-global-car-reference-point* (photo-alist
                                        &optional cam-set-global-p)
  "Call add-global-car-reference-point with arguments taken from
photo-alist.  When cam-set-global-p is t, call
add-global-car-reference-point-cam-set-global instead."
  (let* ((longitude-radians
	  (proj:degrees-to-radians
	   (car (photogrammetry-arglist photo-alist :longitude))))
         (latitude-radians
	  (proj:degrees-to-radians
	   (car (photogrammetry-arglist photo-alist :latitude))))
         (ellipsoid-height
	  (car (photogrammetry-arglist photo-alist :ellipsoid-height)))
         (destination-cs
	  (car (photogrammetry-arglist photo-alist :cartesian-system)))
         (cartesian-coordinates
          (proj:cs2cs
	   (list longitude-radians latitude-radians ellipsoid-height)
	   :destination-cs destination-cs))
         (other-args
          (mapcar #'(lambda (x) (coerce x 'double-float))
                  (photogrammetry-arglist photo-alist
                                          :roll :pitch :heading
                                          :latitude :longitude)))
         (double-float-args
          (nconc cartesian-coordinates other-args)))
    (apply (if cam-set-global-p
               #'add-global-car-reference-point-cam-set-global
               #'add-global-car-reference-point)
           double-float-args)))

(defun add-global-measurement-point* (point)
  "Call add-global-measurement-point with arguments taken from point."
  (let ((double-float-args
         (mapcar #'(lambda (x) (coerce x 'double-float))
                 (photogrammetry-arglist point
                                         :x-global :y-global :z-global))))
    (apply #'add-global-measurement-point double-float-args)))
