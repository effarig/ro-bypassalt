    GET     hdr.include

    AREA    |!!!Module$$Header|, CODE, READONLY, PIC

    IMPORT  |__RelocCode|

    ENTRY

;----------------------------------------------------------------------------
; Module Header
;----------------------------------------------------------------------------
module_base
    DCD     0                               ; Start address
    DCD     module_init     - module_base   ; Initialise code
    DCD     module_die      - module_base   ; Finalise code
    DCD     module_service  - module_base   ; Service call handler
    DCD     module_title    - module_base   ; Title
    DCD     module_help_str - module_base   ; Infomation string
    DCD     module_commands - module_base   ; CLI command table
    DCD     &58680                          ; SWI base
    DCD     module_swi      - module_base   ; SWI handler
    DCD     module_swi_name - module_base   ; SWI names table
    DCD     0                               ; SWI decoding code
    DCD     0                               ; Messages filename
    DCD     module_flags    - module_base   ; Module flags

module_title
    DCB     "BypassAlt",0

module_help_str
    DCB     "BypassAlt",9,"1.00"
    DCB     " (":CC:("$BUILDDATE":RIGHT:11):CC:")"
    DCB     " © James Peacock",0
    ALIGN

module_flags
    DCD     1               ; 32-bit compatible

;----------------------------------------------------------------------------
; Module initialisation
;----------------------------------------------------------------------------
; => r10 => Environment string
;    r11 =  0 or Instantiation No. or I/O base address
;    r12 => Private word
;    r13 =  Supervisor sp.
;
; <= Preserve Mode, Interrupt state, r7-r11,r13.
;    Can corrupt r0-r6,r12,r14, flags.
;    Return V set/R0=>Error block to stop module loading.

module_init
    mov     r6,r12
    ldr     ws,[r6]
    teq     ws,#0
    movne   pc,lr

    stmfd   sp!,{lr}
    bl      |__RelocCode|


    mov     r0,#6
    mov     r3,#ws_size
    swi     XOS_Module
    bvs     module_init_exit
    str     r2,[r6]
    mov     ws,r2

    mvn     r0,#0
    str     r0,[ws,#ws_alt_keys]
    str     r0,[ws,#ws_left_alt_keys]
    str     r0,[ws,#ws_right_alt_keys]
    str     r0,[ws,#ws_alt_state]
    str     r0,[ws,#ws_left_alt_state]
    str     r0,[ws,#ws_right_alt_state]
    mov     r0,#0
    str     r0,[ws,#ws_enabled]
    strb    r0,[ws,#ws_claimed_key_v]
    strb    r0,[ws,#ws_claimed_byte_v]

    mov     r0,#KeyV
    adr     r1,key_v
    swi     XOS_Claim
    bvs     module_init_failed
    mov     r0,#1
    strb    r0,[ws,#ws_claimed_key_v]

    mov     r0,#ByteV
    adr     r1,byte_v
    swi     XOS_Claim
    bvs     module_init_failed
    mov     r0,#1
    strb    r0,[ws,#ws_claimed_byte_v]

    bl      find_low_level_alt_codes

module_init_exit
    ldmfd   sp!,{pc}

module_init_failed
    stmfd   sp!,{r0}
    mov     r12,r6
    bl      module_die
    bvs     module_buggered
    ldmfd   sp!,{r0}
    SetErr
    ldmfd   sp!,{pc}

module_buggered
    ; Half inititalised module, but unable to cleanly uninit registered
    ; stuff, so can't exit. This should never happen unless the OS is
    ; shafted.
    ClrErr
    ldmfd   sp!,{pc}

;----------------------------------------------------------------------------
; Module finalisation
;----------------------------------------------------------------------------
; => r10 =  Fatality: 0=>Non-fatal; 1=>Fatal
;    r11 =  Instantiation No.
;    r12 => Private word
;    r13 =  Supervisor sp.
;
; <= Preserve Mode, Interrupt state, r7-r11,r13.
;    Can corrupt r0-r6,r12,r14, flags.
;    Return V set/R0=>Error block to stop module being removed.

module_die
    mov     r6,r12
    ldr     ws,[r6]
    teq     ws,#0
    moveq   pc,lr

    stmfd   sp!,{lr}

    ldrb    r0,[ws,#ws_claimed_byte_v]
    teq     r0,#0
    movne   r0,#ByteV
    adrne   r1,byte_v
    movne   r2,ws
    swine   XOS_Release
    ldmvsfd sp!,{pc}
    mov     r0,#0
    strb    r0,[ws,#ws_claimed_byte_v]

    ldrb    r0,[ws,#ws_claimed_key_v]
    teq     r0,#0
    movne   r0,#KeyV
    adrne   r1,key_v
    movne   r2,ws
    swine   XOS_Release
    ldmvsfd sp!,{pc}
    mov     r0,#0
    strb    r0,[ws,#ws_claimed_key_v]

    mov     r0,#7
    mov     r2,ws
    swi     XOS_Module

    ClrErr
    mov     r0,#0
    str     r0,[r6]
    ldmfd   sp!,{pc}

;----------------------------------------------------------------------------
; Module service call handler
;----------------------------------------------------------------------------
; => r1     =  Service call number
;    r12    => Private word
;    r13    =  Supervisor/IRQ stack pointer depending on call number.
;
; <= r0     :  Depends on call number.
;    r1     =  0 to claim service, preserved otherwise.
;    r2-r8  :  Depend on call number.
;    r12    :  Can be corrupted.
;
; Service call code MUST be reentrant and fast.

module_service_table_ptr
    DCD     module_service_table - module_base
module_service
    mov     r0,r0                       ; Magic word for table.
    teq     r1,#Service_KeyHandler
    movne   pc,lr
module_service_dispatch
    b       find_low_level_alt_codes    ; Only possibility.

module_service_table
    DCD     0
    DCD     module_service_dispatch - module_base
    DCD     Service_KeyHandler
    DCD     0

;----------------------------------------------------------------------------
; KeyV interception
;----------------------------------------------------------------------------
; => r0 = Reason code (only interested in KeyUp/KeyDown)
;    r1 = Internal Key Number
;
; If enabled, always intercept Alt presses so they don't reach the Key
; hander. Always pass on Alt releases on.
; Need to hook into resets as these mean the kernel has cleared its list
; of depressed keys.
key_v
    teq     r0,#KeyV_KeyPressed
    teqne   r0,#KeyV_KeyReleased
    teqne   r0,#KeyV_Enable
    movne   pc,lr

    teq     r0,#KeyV_Enable
    beq     key_v_reset

    stmfd   sp!,{r2-r6,lr}
    ldr     r2,[ws,#ws_enabled]
    teq     r2,#0
    teqeq   r0,#KeyV_KeyPressed
    beq     key_v_pass_on

    mov     r6,#0

    ldr     r2,[ws,#ws_alt_keys]
    mov     r3,#ws_alt_state
    bl      key_v_update_alt_states

    ldr     r2,[ws,#ws_left_alt_keys]
    mov     r3,#ws_left_alt_state
    bl      key_v_update_alt_states

    ldr     r2,[ws,#ws_right_alt_keys]
    mov     r3,#ws_right_alt_state
    bl      key_v_update_alt_states

    teq     r6,#0
    teqne   r0,#KeyV_KeyReleased
    ldmfd   sp!,{r2-r6,lr}
    moveq   pc,lr
    ldmfd   sp!,{pc}

key_v_reset
    stmfd   sp!,{lr}
    mvn     r14,#0
    str     r14,[ws,#ws_alt_state]
    str     r14,[ws,#ws_left_alt_state]
    str     r14,[ws,#ws_right_alt_state]
    ldmfd   sp!,{pc}

key_v_pass_on
    ldmfd   sp!,{r2-r6,pc}


key_v_update_alt_states
    ; => r0 = Key press/Key release from keyboard
    ;    r1 = Low level internal key number from keyboard
    ;    r2 = Low level internal key numbers to check
    ;    r3 = Storage offset.
    ;
    ; <= r0-r3 preserved, r4,r5 corrupt. r6=1 if alt.
    mov     r5,#255<<0
    and     r4,r2,#255<<0
    teq     r4,r1

    movne   r5,#255<<8
    andne   r4,r2,#255<<8
    teqne   r4,r1,LSL #8

    movne   r5,#255<<16
    andne   r4,r2,#255<<16
    teqne   r4,r1,LSL #16

    movne   r5,#255<<24
    andne   r4,r2,#255<<24
    teqne   r4,r1,LSL #24

    movne   pc,lr
    mov     r6,#1

    ldr     r2,[ws,r3]
    bic     r2,r2,r5
    teq     r0,#KeyV_KeyPressed
    orreq   r2,r2,r4
    orrne   r2,r2,r5
    str     r2,[ws,r3]

    mov     pc,lr

;----------------------------------------------------------------------------
; ByteV interception
;----------------------------------------------------------------------------
; Intercept Keyboard scan OS_Bytes. Don't need to intercept keyboard scan
; from 16 decimal as Alt codes are below this.
;
; OS_Byte 121:
;   Check a single key or scan a range of keys with a lower bound.
;     => r0 = 121
;        r1 = Key to start at, key EOR &80 for a single key.
;     <= r1 = Range: Key pressed, &FF if none; single key: &FF if pressed.
;        r2   Undefined.
;
; OS_Byte 129
;   Read key within time limit - reads ASCII codes, so don't intercept.
;     => r0 = 129
;        r1 = 0-255 (Low byte of time limit).
;        r2 = 0-127 (high byte of time limit).
;    <=  r1 = ASCII code of character read.
;        r0 = 0 (char read), 27 (escape condition), 255 (timeout)
;
;   Read OS version ID.
;     => r0 = 129
;        r1 = 0
;        r2 = &FF
;     <= r1 = OS ID value.
;        r2 = 0
;
;   Scan keyboard for a range of keys.
;     => r0 = 129
;    r1 = 1-127 (lowest inkey number to start at EOR &7f).
;        r2 = 255
;     <= r1 = Inkey number of key pressed, 255 if none.
;        r2   Undefined
;
;   Scan keyboard for a single key.
;     => r0 = 129
;        r1 = Inkey number EOR &FF.
;        r2 = 255
;     <= r1 = 0 if not pressed, 255 if pressed.
;        r2 = 0 if not pressed, 255 if pressed.
;
byte_v
    teq     r0,#121
    teqne   r0,#129
    movne   pc,lr

    stmfd   sp!,{r0,r3,lr}
    ldr     r3,[ws,#ws_enabled]
    teq     r3,#0
    beq     byte_v_pass_on

    teq     r0,#121
    beq     byte_v_121

byte_v_129
    teq     r2,#255
    bne     byte_v_pass_on
    tst     r1,#&80
    bne     byte_v_129_single
    teq     r1,#0
    bne     byte_v_129_scan

byte_v_pass_on
    ClrErr
    ldmfd   sp!,{r0,r3,pc}

byte_v_intercept
    ClrErr
    ldmfd   sp!,{r0,r3,lr}
    ldmfd   sp!,{pc}

byte_v_121
    tst     r1,#&80
    beq     byte_v_121_scan
    ; fall through to byte_v_121_single

byte_v_121_single
    teq     r1,#&80:EOR:Inkey_Alt
    teqne   r1,#&80:EOR:Inkey_Left_Alt
    teqne   r1,#&80:EOR:Inkey_Right_Alt
    bne     byte_v_pass_on

    teq     r1,#Inkey_Left_Alt:EOR:&80
    ldreq   r0,[ws,#ws_left_alt_state]
    teq     r1,#Inkey_Right_Alt:EOR:&80
    ldreq   r0,[ws,#ws_right_alt_state]
    teq     r1,#Inkey_Alt:EOR:&80
    ldreq   r0,[ws,#ws_alt_state]

    cmn     r0,#1
    movne   r1,#&ff
    movne   r2,#&ff
    moveq   r1,#0
    moveq   r2,#0
    b       byte_v_intercept


byte_v_129_single
    teq     r1,#&ff:EOR:Inkey_Alt
    teqne   r1,#&ff:EOR:Inkey_Left_Alt
    teqne   r1,#&ff:EOR:Inkey_Right_Alt
    bne     byte_v_pass_on

    teq     r1,#Inkey_Left_Alt:EOR:&ff
    ldreq   r0,[ws,#ws_left_alt_state]
    teq     r1,#Inkey_Right_Alt:EOR:&ff
    ldreq   r0,[ws,#ws_right_alt_state]
    teq     r1,#Inkey_Alt:EOR:&ff
    ldreq   r0,[ws,#ws_alt_state]

    cmn     r0,#1
    movne   r1,#&ff
    movne   r2,#&ff
    moveq   r1,#0
    moveq   r2,#0
    b       byte_v_intercept


byte_v_121_scan
    cmp     r1,#Inkey_Alt
    bhs     byte_v_121_scan2
    ldr     r0,[ws,#ws_alt_state]
    cmn     r0,#1
    movne   r1,#Inkey_Alt
    movne   r2,#&80000000
    bne     byte_v_intercept
byte_v_121_scan2
    cmp     r1,#Inkey_Right_Alt
    bhs     byte_v_121_scan3
    ldr     r0,[ws,#ws_right_alt_state]
    cmn     r0,#1
    movne   r1,#Inkey_Right_Alt
    movne   r2,#&80000000
    bne     byte_v_intercept
byte_v_121_scan3
    cmp     r1,#Inkey_Left_Alt
    bhs     byte_v_pass_on
    ldr     r0,[ws,#ws_left_alt_state]
    cmn     r0,#1
    movne   r1,#Inkey_Left_Alt
    movne   r2,#&80000000
    bne     byte_v_intercept
    b       byte_v_pass_on


byte_v_129_scan
    eor     r14,r1,#&7f
    cmp     r14,#Inkey_Alt
    bhs     byte_v_129_scan2
    ldr     r0,[ws,#ws_alt_state]
    cmn     r0,#1
    movne   r1,#Inkey_Alt
    movne   r2,#&80000000
    bne     byte_v_intercept
byte_v_129_scan2
    cmp     r14,#Inkey_Right_Alt
    bhs     byte_v_129_scan3
    ldr     r0,[ws,#ws_right_alt_state]
    cmn     r0,#1
    movne   r1,#Inkey_Right_Alt
    movne   r2,#&80000000
    bne     byte_v_intercept
byte_v_129_scan3
    cmp     r14,#Inkey_Left_Alt
    bhs     byte_v_pass_on
    ldr     r0,[ws,#ws_left_alt_state]
    cmn     r0,#1
    movne   r1,#Inkey_Left_Alt
    movne   r2,#&80000000
    bne     byte_v_intercept
    b       byte_v_pass_on


;----------------------------------------------------------------------------
; Discover low-level internal (i.e. KeyV) key numbers of alt keys. The only
; place it appears this is available from is the KeyboardHandler which is
; somewhat low-level.
;----------------------------------------------------------------------------
find_low_level_alt_codes
    stmfd   sp!,{r0-r3,lr}
    mov     r0,#0
    swi     XOS_InstallKeyHandler
    mvnvs   r0,#0
    mvnvs   r1,#0
    mvnvs   r2,#0
    ldrvc   r3,[r0,#8]          ; Offset to -ve INKEY table
    addvc   r3,r3,r0            ; r3 => -ve INKEY table
    ldrvc   r0,[r3,#4*(Inkey_Alt:EOR:&7f)]
    ldrvc   r1,[r3,#4*(Inkey_Left_Alt:EOR:&7f)]
    ldrvc   r2,[r3,#4*(Inkey_Right_Alt:EOR:&7f)]
    str     r0,[ws,#ws_alt_keys]
    str     r1,[ws,#ws_left_alt_keys]
    str     r2,[ws,#ws_right_alt_keys]
    ClrErr
    ldmfd   sp!,{r0-r3,pc}

;----------------------------------------------------------------------------
; SWI Dispatcher
; => r0-r8   :  Passed from caller.
;    r11     =  SWI Number AND 63.
;    r12     => Private word.
;    r13     =  SVC stack pointer.
;    r14     =  Return address.
;
; <= r0-r9   :  Returned to caller.
;    r10-r12 : May be corrupted.
;
;----------------------------------------------------------------------------
module_swi
    ldr     ws,[r12]
    cmp     r11,#(module_swi_list_start - module_swi_list_end)/4
    addlo   pc,pc,r11,LSL #2
    b       module_swi_unknown
module_swi_list_start
    b       swi_enable
    b       swi_disable
module_swi_list_end

module_swi_name
    DCB     "BypassAlt",0
    DCB     "Enable",0
    DCB     "Disable",0
    DCB     0
    ALIGN

module_swi_unknown
    stmfd   sp!,{r1-r4,lr}
    adr     r0,module_swi_unknown_error
    mov     r1,#0
    mov     r2,#0
    adrl    r4,module_title
    swi     XMessageTrans_ErrorLookup
    adrvs   r0,module_swi_unknown_error
    SetErr
    ldmfd   sp!,{r1-r4,pc}

module_swi_unknown_error
    DCD     &1e6
    DCB     "BadSWI:Unknown SWI",0
    ALIGN

;----------------------------------------------------------------------------
; SWI BypassAlt_Enable
;----------------------------------------------------------------------------
swi_enable
    ldr     r11,[ws,#ws_enabled]
    adds    r11,r11,#1
    strne   r11,[ws,#ws_enabled]
    ClrErr
    mov     pc,lr

;----------------------------------------------------------------------------
; SWI BypassAlt_Disable
;----------------------------------------------------------------------------
swi_disable
    ldr     r11,[ws,#ws_enabled]
    subs    r11,r11,#1
    strhs   r11,[ws,#ws_enabled]
    ClrErr
    mov     pc,lr

;----------------------------------------------------------------------------
; *Command Table
;----------------------------------------------------------------------------
module_commands
    DCB     "BypassAltInfo",0
    ALIGN
    DCD     command_info - module_base
    DCD     &00000300
    DCD     command_info_syntax - module_base
    DCD     command_info_help - module_base
    DCD     0

;----------------------------------------------------------------------------
; Writes a string:hex number pair to stdout
; => r0 => String
;    r1 =  Hex value
;----------------------------------------------------------------------------
output_name_hex
    stmfd   sp!,{r0-r3,lr}
    mov     r3,#Table_Width
    mov     r2,r0
output_name_hex_loop
    ldrb    r0,[r2]
    teq     r0,#0
    moveq   r0,#32
    addne   r2,r2,#1
    swi     XOS_WriteC
    subs    r3,r3,#1
    bne     output_name_hex_loop
    mov     r0,r1
    mov     r2,#20
    sub     r13,r13,#20
    mov     r1,r13
    swi     XOS_ConvertHex8
    swi     XOS_WriteI + ' '
    swi     XOS_WriteI + '&'
    swivc   XOS_Write0
    swi     XOS_NewLine
    add     r13,r13,#20
    ClrErr
    ldmfd   sp!,{r0-r3,pc}

;----------------------------------------------------------------------------
; *BypassAltStatus
;----------------------------------------------------------------------------
; => r0  => Command tail
;    r1  =  Number of parameters
;    r12 => Private word
;    r13 =  SVC stack pointer
;    r14 =  Return address
;
; <= r0  => Error block, if V set.
;    r0-r6,r12,r14, flags corruptable.

command_info
    stmfd   sp!,{lr}
    ldr     ws,[ws]

    adr     r0,banner_alt_keys
    ldr     r1,[ws,#ws_alt_keys]
    bl      output_name_hex

    adr     r0,banner_left_alt_keys
    ldr     r1,[ws,#ws_left_alt_keys]
    bl      output_name_hex

    adr     r0,banner_right_alt_keys
    ldr     r1,[ws,#ws_right_alt_keys]
    bl      output_name_hex

    adr     r0,banner_alt_state
    ldr     r1,[ws,#ws_alt_state]
    bl      output_name_hex

    adr     r0,banner_left_alt_state
    ldr     r1,[ws,#ws_left_alt_state]
    bl      output_name_hex

    adr     r0,banner_right_alt_state
    ldr     r1,[ws,#ws_right_alt_state]
    bl      output_name_hex

    adr     r0,banner_usage_count
    ldr     r1,[ws,#ws_enabled]
    bl      output_name_hex

    ldmfd   sp!,{pc}

command_info_help
    DCB     "*",27,0," shows the status of the BypassAlt module",13,10
command_info_syntax
    DCB     27,1,0
banner_alt_keys
    DCB     "Alt physical key codes:",0
banner_left_alt_keys
    DCB     "L-Alt physical key codes:",0
banner_right_alt_keys
    DCB     "R-Alt physical key codes:",0
banner_alt_state
    DCB     "Alt state:",0
banner_left_alt_state
    DCB     "L-Alt state:",0
banner_right_alt_state
    DCB     "R-Alt state:",0
banner_usage_count
    DCB     "Usage count",0
    ALIGN

    END
