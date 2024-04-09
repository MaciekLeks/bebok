 ; Remap the master PIC
mov al, 00010001b ;init command
out 0x20, al ;send init command to master PIC

mov al, 0x20 ;Interrupt x20 (32) is where the master ISR sgould start
out 0x21, al ;set the master PIC (IRQ 0-7) to start at interrupt 32 (32-39)

mov al, 00000001b ; Set the sequence mode of work and tell that's the end of the initialization
out 0x21, al
; End remap the master PIC