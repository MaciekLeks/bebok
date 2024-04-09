ORG 0x7e00

%define FREE_SPACE 0x9000 ; for PML4T, PDPT, PDT, PT

%define PAGE_PRESENT    (1 << 0)
%define PAGE_WRITE      (1 << 1)

%define CODE_SEG     0x0008
%define DATA_SEG     0x0010

; GDT Access bits
%define PRESENT (1 << 7)
%define NOT_SYS (1 << 4)
%define EXEC (1 << 3)
%define DC (1 << 2)
%define RW (1 << 1)
%define ACCESSED (1 << 0)

; GDT Flags bits
%define GRAN_4K     1 << 7
%define SZ_32       1 << 6
%define LONG_MODE  1 << 5

Main:
    jmp short SwitchToLongMode

ALIGN 4
IDT:
    .Length      dw 0
    .Base         dd 0

; Function to switch directly to long mode from real mode.
; Identity maps the first 2MiB.
; Uses Intel syntax.

; es:edi    Should point to a valid page-aligned 16KiB buffer, for the PML4, PDPT, PD and a PT.
; ss:esp    Should point to memory that can be used as a small (1 uint32_t) stack
SwitchToLongMode:
    ; Point edi to a free space bracket.
    mov edi, FREE_SPACE
    ; Zero out the 16KiB buffer (4KB * 4B(32 bits) - stosd).
    ; Since we are doing a rep stosd, count should be bytes/4.
    push di                           ; REP STOSD alters DI.
    mov ecx, 0x1000
    xor eax, eax
    cld ;inc ES:DI not dec DI ECX times
    rep stosd ; ES:[DI]
    pop di                            ; Get DI back.


    ; Each table is 4KiB in size PML4T - 512 entries, PDPT - 512 entries, PDT - 512 entries, PT - 512 entries 8 bytes each.
    ; Build the Page Map Level 4.
    ; es:di points to the Page Map Level 4 table.
    ; PML4[0]@0x9000 -> PDPT[0]@0xA000 (0x9000 + 0x1000)
    lea eax, [es:di + 0x1000]         ; Put the address of the Page Directory Pointer Table in to EAX.
    or eax, PAGE_PRESENT | PAGE_WRITE ; Or EAX with the flags - present flag, writable flag.
    mov [es:di], eax                  ; Store the value of EAX as the first PML4E.


    ; Build the Page Directory Pointer Table.
    lea eax, [es:di + 0x2000]         ; Put the address of the Page Directory in to EAX.
    or eax, PAGE_PRESENT | PAGE_WRITE ; Or EAX with the flags - present flag, writable flag.
    mov [es:di + 0x1000], eax         ; Store the value of EAX as the first PDPTE.


    ; Build the Page Directory.
    lea eax, [es:di + 0x3000]         ; Put the address of the Page Table in to EAX.
    or eax, PAGE_PRESENT | PAGE_WRITE ; Or EAX with the flags - present flag, writeable flag.
    mov [es:di + 0x2000], eax         ; Store to value of EAX as the first PDE.


    push di                           ; Save DI for the time being.
    lea di, [di + 0x3000]             ; Point DI to the page table.
    mov eax, PAGE_PRESENT | PAGE_WRITE    ; Move the flags into EAX - and point it to 0x0000.


    ; Build the Page Table.
.LoopPageTable:
    mov [es:di], eax
    add eax, 0x1000
    add di, 8
    cmp eax, 0x200000                 ; If we did all 2MiB, end.
    jb .LoopPageTable

    pop di                            ; Restore DI.

    ; Disable IRQs
    mov al, 0xFF                      ; Out 0xFF to 0xA1 and 0x21 to disable all IRQs.
    out 0xA1, al
    out 0x21, al

    nop
    nop

    lidt [IDT]                        ; Load a zero length IDT so that any NMI causes a triple fault.

    ; Enter long mode.
    mov eax, 10100000b                ; Set the PAE and PGE bit.
    mov cr4, eax

    mov edx, edi                      ; Point CR3 at the PML4 (0x9000).
    mov cr3, edx

    mov ecx, 0xC0000080               ; Read from the EFER MSR.
    rdmsr

    or eax, 0x00000100                ; Set the LME bit.
    wrmsr

    ; paging
    mov ebx, cr0                      ; Activate long mode -
    or ebx,0x80000001                 ; - by enabling paging and protection simultaneousl
    mov cr0, ebx
;    mov ebx, cr0 ;Enable protected mode
;    or ebx, 0x1 ; set PE bit
;    mov cr0, ebx

    lgdt [GDT.Pointer]                ; Load GDT.Pointer defined below.

    jmp CODE_SEG:LongMode             ; Load CS with 64 bit segment and flush the instruction cache


    ; Global Descriptor Table
GDT:
;.Null:
;    dq 0x0000000000000000             ; Null Descriptor - should be present.
;
;.Code: ; 0x08
;    dq 0x00209A0000000000             ; 64-bit code descriptor (exec/read).
;    dq 0x0000920000000000             ; 64-bit data descriptor (read/write).
;
;ALIGN 4
;    dw 0                              ; Padding to make the "address of the GDT" field aligned on a 4-byte boundary
;
;.Pointer:
;    dw $ - GDT - 1                    ; 16-bit Size (Limit) of GDT.
;    dd GDT                            ; 32-bit Base Address of GDT. (CPU will zero extend to 64-bit)
 .Null: equ $ - GDT
    dq 0
 .Code: equ $ - GDT
    dd 0xFFFF                                   ; Limit & Base (low, bits 0-15)
    db 0                                        ; Base (mid, bits 16-23)
    db PRESENT | NOT_SYS | EXEC | RW            ; Access
    db GRAN_4K | LONG_MODE | 0xF                ; Flags & Limit (high, bits 16-19)
    db 0                                        ; Base (high, bits 24-31)
.Data: equ $ - GDT
    dd 0xFFFF                                   ; Limit & Base (low, bits 0-15)
    db 0                                        ; Base (mid, bits 16-23)
    db PRESENT | NOT_SYS | RW                   ; Access
    db GRAN_4K | SZ_32 | 0xF                    ; Flags & Limit (high, bits 16-19)
    db 0                                        ; Base (high, bits 24-31)
.TSS: equ $ - GDT
    dd 0x00000068
     dd 0x00CF8900
.Pointer:
    dw $ - GDT - 1
    dq GDT

[BITS 64]
LongMode:
    cli
    mov ax, DATA_SEG
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax

    mov rbp, 0x200000 ;stack pointer - 0x0020 * 0x04 = 0x00200000
    mov rsp, rbp ;stack pointer - 0x0020 * 0x04 = 0x00200000

    ; Blank out the screen to a blue color.
    mov edi, 0xB8000
    mov rcx, 500                      ; Since we are clearing uint64_t over here, we put the count as Count/4.
    mov rax, 0x1F201F201F201F20      ; Set the value to set the screen to: Blue background, white foreground, blank spaces.
    rep stosq                         ; Clear the entire screen.

    ; Display "Hello World!"
;    mov edi, 0x00b8000
;
;    mov rax, 0x1F6C1F6C1F651F48
;    mov [edi],rax
;
;    mov rax, 0x1F6F1F571F201F6F
;    mov [edi + 8], rax
;
;    mov rax, 0x1F211F641F6C1F72
;    mov [edi + 16], rax

    %include "src/boot/pic_irq_remap.asm"

   ; jmp Main.Long                     ; You should replace this jump to wherever you want to jump to.
    mov rax,2 ;LBA value: we load from sector 2, 0 and 1 are our boot sector (the code above that we've just executed)
    mov rcx, 255  ;total number of sectors we want to load (see that number in Makefile) - max 2048 of sectors -
    ; - we have mapped only 0-2MB, and now we are going to load the rest of the kernel at the 1MB
    mov rdi, 0x0100000 ;load code at 1MB
    call LoadSectors ;call the function to load the sectors
    jmp 0x0100000 ;jump to the code we've just loaded
    ;jmp $ ;infinite loop

%include "src/boot/ata_lba_read.asm"

times 512 - ($-$$) db 0
