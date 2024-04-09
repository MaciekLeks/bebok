mmap_len equ 0x8000             ; the number of entries will be stored at 0x8000
mmap_array equ 0x8008             ; array of entries will start at 0x8008, 8 to be 64 bit aligned

ORG 0x7C00
BITS 16

; Main entry point where BIOS leaves us.

Main:
    jmp short .Begin
    nop
    times 33 db 0; 33 bytes of padding for the partition table

.Begin:
    jmp 0:.Start ;change cs and ip

.Start:
    cli ;clear interrupts
    mov ax, 0
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7c00 ;stack pointer - 0x7c0 * 0x04 = 0x7c00, czyli na poczarek kodu i danych, ale przy push najpierw jest dekrementacja wiec wchodzimy w niezaalokowany obsar pamięci (0x0000->0x7c00)
    mov bp, sp ;base pointer
    sti ;set interrupts


    ; Switch to Long Mode.
    ;%include "src/boot/load_second_sector.asm"

    ; BIOS interrupt number for reading a sector from a floppy disk
    mov ah, 2

    ; Number of sectors to read
    mov al, 1

    ; ES:BX data destination
    ; Buffer to fill data
    mov bx, ExtendedBoot ; 512 bytes after the start of the bootloader

    ; Drive number set by BIOS
    ;mov dl, _

    ; Cylinder number
    mov ch, 0
    ; Head number
    mov dh, 0
    ; Sector number
    mov cl, 2

    ; BIOS interrupt call
    int 0x13
    ; If the carry flag is set, there was an error
    jc .LoadingError

    call CheckCPU                     ; Check whether we support Long Mode or not.
    jc .NoLongMode                  ; Carry Flag is set, so we don't support Long Mode.

    mov di, mmap_array
    mov si, mmap_len
    push di
    pop di
    call MemoryMap
    jc .MemoryMapError

    ; Enable A20 line
    in al, 0x92
    or al, 2
    out 0x92, al


    ;; jump to the second sector
    jmp 0x0: ExtendedBoot ; jump to the second sector


BITS 16

.MemoryMapError:
    mov si, MemoryMapErrorMsg
    call Print
    jmp .Die

.NoLongMode:
    mov si, NoLongModeMsg
    call Print
    jmp .Die

.LoadingError:
    mov si, LoadingErrorMsg
    call Print

.Die:
    hlt
    jmp .Die


;%include "src/boot/long_mode_directly.asm"
BITS 16


NoLongModeMsg db "ERROR: CPU does not support long mode.", 0x0A,  0
LoadingErrorMsg db "ERROR: Could not load the second sector.", 0x0A,  0
MemoryMapErrorMsg db "ERROR: Could not load memory map.", 0x0A,  0


; Checks whether CPU supports long mode or not.
; Returns with carry set if CPU doesn't support long mode.
CheckCPU:
    ; Check whether CPUID is supported or not.

    ; Copy FLAGS in to EAX via stack
    pushfd
    pop eax

    ; Copy to ECX as well for comparing later on
    mov ecx, eax

    ; Flip the ID bit
    xor eax, 1<<21

    ; Copy EAX to FLAGS via the stack
    push eax
    popfd

    ; Copy FLAGS back to EAX (with the flipped bit if CPUID is supported)
    pushfd
    pop eax

    ; Restore FLAGS from the old version stored in ECX (i.e. flipping the ID bit
    ; back if it was ever flipped).
    push ecx
    popfd

    ; Compare EAX and ECX. If they are equal then that means the bit wasn't
    ; flipped, and CPUID isn't supported.
    xor eax, ecx
    jz .NoLongMode

    ; Check whether the CPU supports extended functions (> 0x80000000).
    mov eax, 0x80000000    ; Set the A-register to 0x80000000.
    cpuid                  ; CPU identification.
    cmp eax, 0x80000001    ; Compare the A-register with 0x80000001.
    jb .NoLongMode         ; It is less, there is no long mode.

    ; Extended CPUID functions are supported, check for long mode support.
    mov eax, 0x80000001    ; Set the A-register to 0x80000001.
    cpuid                  ; CPU identification.
    test edx, 1 << 29      ; Test if the LM-bit, which is bit 29, is set in the D-register.
    jz .NoLongMode         ; They aren't, there is no long mode.

    ret
.NoLongMode:
    stc
    ret


; Prints out a message using the BIOS.
; es:si    Address of ASCIIZ string to print.
Print:
    pushad
.PrintLoop:
    lodsb                             ; Load the value at [@es:@si] in @al.
    test al, al                       ; If AL is the terminator character, stop printing.
    je .PrintDone
    mov ah, 0x0E
    int 0x10
    jmp .PrintLoop                    ; Loop till the null character not found.

.PrintDone:
    popad                             ; Pop all general purpose registers to save them.
    ret

%include "src/boot/memory_map.asm"

; Pad out file.
times 510 - ($-$$) db 0
dw 0xAA55



ExtendedBoot:
    ; Second sector of the bootloader
