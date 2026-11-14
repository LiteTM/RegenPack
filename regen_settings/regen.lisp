; =============================================================================
;  Regen Settings  -  throttle-release regenerative braking for VESC
; =============================================================================
;
;  Applies a regenerative brake current when the ADC1 throttle is fully
;  released and the vehicle is above a minimum speed. Regen stops at once when
;  the throttle is applied, the speed falls below the minimum, a fault occurs
;  or the throttle signal leaves its valid range.
;
;  Anti-jitter design
;    * Throttle hysteresis : release below R %, re-apply above R + 3 %
;    * Release debounce    : throttle must stay released for N ms
;    * Speed hysteresis    : enter above (min + H) km/h, exit below min km/h
;    * Soft ramp-in        : brake current ramps 0 -> target, exits instantly
;
;  Requirements: VESC firmware 6.05+, ADC app (ADC / ADC+UART / ADC+PAS) with
;  a standard (non-center) throttle on ADC1, and wheel diameter, motor poles
;  and gear ratio set so that (get-speed) is correct.
;
;  Settings live in the LispBM emulated EEPROM (slots 100..107).
; =============================================================================

(def rg-version "1.0.0")

; ---- Persistent storage layout ------------------------------------------
(def ee-magic    100)  ; i  magic / layout version
(def ee-enabled  101)  ; f  0.0 / 1.0
(def ee-current  102)  ; f  A
(def ee-minspd   103)  ; f  km/h
(def ee-relth    104)  ; f  % throttle
(def ee-reldly   105)  ; f  ms
(def ee-hyst     106)  ; f  km/h
(def ee-ramp     107)  ; f  ms
(def rg-magic 1380271873) ; 0x52454701 = "REG" v1

; ---- Limits: (min max default) ------------------------------------------
(def lim-current '(0.0  150.0  10.0))
(def lim-minspd  '(1.0   60.0   8.0))
(def lim-relth   '(1.0   20.0   5.0))
(def lim-reldly  '(50.0 2000.0 300.0))
(def lim-hyst    '(0.5   10.0   1.5))
(def lim-ramp    '(0.0  2000.0 400.0))

(def thr-hyst 0.03)   ; throttle re-apply band above the release threshold
(def dt       0.01)   ; control period (s) -> 100 Hz

; ---- Settings (RAM copy) ------------------------------------------------
(def s-enabled 1)
(def s-current (ix lim-current 2))
(def s-minspd  (ix lim-minspd 2))
(def s-relth   (ix lim-relth 2))
(def s-reldly  (ix lim-reldly 2))
(def s-hyst    (ix lim-hyst 2))
(def s-ramp    (ix lim-ramp 2))

; ---- Runtime state ------------------------------------------------------
; Status codes reported to the UI
;   0 disabled  1 waiting  2 arming  3 active
;   4 no ADC app  5 throttle out of range  6 motor fault
(def st        0)
(def active    nil)
(def rel-timer 0.0)   ; s the throttle has been continuously released
(def out       0.0)   ; A brake current currently commanded
(def thr       0.0)
(def spd       0.0)
(def hw-max    60.0)  ; |l-current-min| of the motor config
(def app-ok    nil)
(def save-pending nil)
(def slow-cnt  0)

; ---- Helpers ------------------------------------------------------------
(defun clamp (x lo hi) (if (< x lo) lo (if (> x hi) hi x)))
(defun lower (a b) (if (< a b) a b))

; Validate a value against a limit list. nil / NaN fall back to the default.
(defun valid (x lim)
    (if (and x (= x x))
        (clamp (to-float x) (ix lim 0) (ix lim 1))
        (ix lim 2)))

(defun eff-current () (clamp s-current 0.0 hw-max))

(defun refresh-hw () {
        (setq hw-max (abs (conf-get 'l-current-min)))
        (var app (conf-get 'app-to-use))
        (setq app-ok (or (= app 2) (= app 5) (= app 10)))
})

; app-adc-range-ok exists from FW 6.05. Treat a missing function as "ok".
; (trap expr) -> (exit-ok value) or (exit-error reason)
(defun range-ok ()
    (let ((r (trap (app-adc-range-ok))))
        (if (eq (car r) 'exit-ok) (ix r 1) t)))

; ---- Persistence --------------------------------------------------------
(defun ee-put (addr val)
    (if (not (eq (eeprom-read-f addr) val)) (eeprom-store-f addr val)))

(defun save-now () {
        (ee-put ee-enabled (to-float s-enabled))
        (ee-put ee-current s-current)
        (ee-put ee-minspd  s-minspd)
        (ee-put ee-relth   s-relth)
        (ee-put ee-reldly  s-reldly)
        (ee-put ee-hyst    s-hyst)
        (ee-put ee-ramp    s-ramp)
        (if (not (eq (eeprom-read-i ee-magic) rg-magic))
            (eeprom-store-i ee-magic rg-magic)) ; magic last = commit
        (setq save-pending nil)
        (send-data "msg Settings saved")
})

(defun load () {
        (var m (eeprom-read-i ee-magic))
        (if (and m (= m rg-magic))
            {
                (var en (eeprom-read-f ee-enabled))
                (setq s-enabled (if (and en (> en 0.5)) 1 0))
                (setq s-current (valid (eeprom-read-f ee-current) lim-current))
                (setq s-minspd  (valid (eeprom-read-f ee-minspd)  lim-minspd))
                (setq s-relth   (valid (eeprom-read-f ee-relth)   lim-relth))
                (setq s-reldly  (valid (eeprom-read-f ee-reldly)  lim-reldly))
                (setq s-hyst    (valid (eeprom-read-f ee-hyst)    lim-hyst))
                (setq s-ramp    (valid (eeprom-read-f ee-ramp)    lim-ramp))
            }
            (save-now))
})

(defun set-defaults () {
        (setq s-enabled 1)
        (setq s-current (ix lim-current 2))
        (setq s-minspd  (ix lim-minspd 2))
        (setq s-relth   (ix lim-relth 2))
        (setq s-reldly  (ix lim-reldly 2))
        (setq s-hyst    (ix lim-hyst 2))
        (setq s-ramp    (ix lim-ramp 2))
})

; ---- Motor hand-over ----------------------------------------------------
(defun regen-stop () {
        (if active {
                (set-current 0.0)
                (app-disable-output 0) ; hand control back to the ADC app now
        })
        (setq active nil)
        (setq out 0.0)
})

; ---- Control loop (100 Hz) ----------------------------------------------
(defun control-step () {
        (setq slow-cnt (+ slow-cnt 1))
        (if (>= slow-cnt 50) { (setq slow-cnt 0) (refresh-hw) })

        (setq thr (clamp (get-adc-decoded 0) 0.0 1.0))
        (setq spd (* (abs (get-speed)) 3.6))

        (var rel-lim  (/ s-relth 100.0))
        (var released (<= thr rel-lim))
        (var applied  (> thr (+ rel-lim thr-hyst)))

        ; Highest-priority inhibit reason (status code), or -1 when clear
        (var inhibit
            (cond
                ((= s-enabled 0) 0)
                ((not app-ok) 4)
                ((not (range-ok)) 5)
                ((not (= (get-fault) 0)) 6)
                (t -1)))

        ; Debounce: count continuous release time, reset on any throttle
        (setq rel-timer (if released (lower (+ rel-timer dt) 10.0) 0.0))

        (if active
            ; ---------------- ACTIVE ----------------
            (if (or applied (< spd s-minspd) (>= inhibit 0))
                { (regen-stop) (setq st (if (>= inhibit 0) inhibit 1)) }
                {
                    (var target (eff-current))
                    (var step (if (< s-ramp 1.0) target (/ (* target dt 1000.0) s-ramp)))
                    (setq out (lower target (+ out step)))
                    (app-disable-output 100)
                    (set-brake out)
                    (setq st 3)
                })
            ; ---------------- IDLE ------------------
            (cond
                ((>= inhibit 0) (setq st inhibit))
                ((and (>= rel-timer (/ s-reldly 1000.0))
                      (>= spd (+ s-minspd s-hyst))
                      (> (eff-current) 0.0))
                    {
                        (setq active t)
                        (setq out 0.0)
                        (app-disable-output 100)
                        (set-brake 0.0)
                        (setq st 3)
                    })
                ((and released (>= spd (+ s-minspd s-hyst))) (setq st 2))
                (t (setq st 1))))

        ; Deferred flash write: only while stopped and not braking, because
        ; writing the emulated EEPROM briefly stops the motor.
        (if (and save-pending (not active) (< spd 1.0)) (save-now))
})

; Any runtime error releases the motor and the loop keeps running.
(defun control-loop ()
    (loopwhile t {
            (if (eq (car (trap (control-step))) 'exit-error) (regen-stop))
            (sleep dt)
    }))

; ---- VESC Tool communication (custom app data) --------------------------
;  UI -> device (binary, big endian)
;    [u8 1]                                   request config
;    [u8 2][u8 en][f32 cur][f32 minspd][f32 relth]
;          [f32 reldly][f32 hyst][f32 ramp]   apply + save (26 bytes)
;    [u8 3]                                   restore defaults + save
;    [u8 4]                                   request live data
;  device -> UI (text)
;    "conf en cur minspd relth reldly hyst ramp hwmax pending"
;    "rt status speed throttle brakeA motorA"
;    "msg <text>"

(defun send-conf ()
    (send-data (str-merge "conf "
            (str-from-n s-enabled "%d ")
            (str-from-n s-current "%.1f ")
            (str-from-n s-minspd  "%.1f ")
            (str-from-n s-relth   "%.1f ")
            (str-from-n s-reldly  "%.0f ")
            (str-from-n s-hyst    "%.1f ")
            (str-from-n s-ramp    "%.0f ")
            (str-from-n hw-max    "%.1f ")
            (if save-pending "1" "0"))))

(defun send-rt ()
    (send-data (str-merge "rt "
            (str-from-n st "%d ")
            (str-from-n spd "%.1f ")
            (str-from-n (* thr 100.0) "%.0f ")
            (str-from-n out "%.1f ")
            (str-from-n (get-current) "%.1f"))))

(defun request-save () {
        (setq save-pending t)
        (if (>= spd 1.0) (send-data "msg Applied. Will be saved when the vehicle stops."))
})

(defun apply-conf (d) {
        (setq s-enabled (if (> (bufget-u8 d 1) 0) 1 0))
        (setq s-current (valid (bufget-f32 d 2)  lim-current))
        (setq s-minspd  (valid (bufget-f32 d 6)  lim-minspd))
        (setq s-relth   (valid (bufget-f32 d 10) lim-relth))
        (setq s-reldly  (valid (bufget-f32 d 14) lim-reldly))
        (setq s-hyst    (valid (bufget-f32 d 18) lim-hyst))
        (setq s-ramp    (valid (bufget-f32 d 22) lim-ramp))
        (request-save)
        (send-conf)
})

(defun handle-rx (d)
    (if (> (buflen d) 0)
        (let ((cmd (bufget-u8 d 0)))
            (cond
                ((= cmd 1) (send-conf))
                ((and (= cmd 2) (>= (buflen d) 26)) (apply-conf d))
                ((= cmd 3) { (set-defaults) (request-save) (send-conf) })
                ((= cmd 4) (send-rt))
                (t nil)))))

(defun event-loop ()
    (loopwhile t
        (recv
            ((event-data-rx . (? d)) (handle-rx d))
            (_ nil))))

; ---- Boot ---------------------------------------------------------------
(refresh-hw)
(load)
(event-register-handler (spawn event-loop))
(event-enable 'event-data-rx)
(spawn control-loop)
(print (str-merge "Regen Settings v" rg-version " running"))
