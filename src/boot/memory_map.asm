; detect memory
; use the INT 0x15, eax= 0xE820 BIOS function to get a memory map
; note: initially di is 0, be sure to set it to a value so that the BIOS code will not be overwritten.
;       The consequence of overwriting the BIOS code will lead to problems like getting stuck in `int 0x15`
; inputs: es:di -> destination buffer for 24 byte entries
;   si -> pointer to a 16-bit word where the entry count will be stored
; outputs: bp = entry count, trashes all registers except esi
MemoryMap:
    push bp
    ;mov di, 0x8004          ; Set di to 0x8004. Otherwise this code will get stuck in `int 0x15` after some entries are fetched
	xor ebx, ebx		; ebx must be 0 to start
	xor bp, bp		; keep an entry count in bp
	mov edx, 0x0534D4150	; Place "SMAP" into edx
	mov eax, 0xe820
	mov [es:di + 20], dword 1	; force a valid ACPI 3.X entry
	mov ecx, 24		; ask for 24 bytes
	int 0x15
	jc short .Failed	; carry set on first call means "unsupported function"
	mov edx, 0x0534D4150	; Some BIOSes apparently trash this register?
	cmp eax, edx		; on success, eax must have been reset to "SMAP"
	jne short .Failed
	test ebx, ebx		; ebx = 0 implies list is only 1 entry long (worthless)
	je short .Failed
	jmp short .JmpIn
.E820Lp:
	mov eax, 0xe820		; eax, ecx get trashed on every int 0x15 call
	mov [es:di + 20], dword 1	; force a valid ACPI 3.X entry
	mov ecx, 24		; ask for 24 bytes again
	int 0x15
	jc short .E820F		; carry set means "end of list already reached"
	mov edx, 0x0534D4150	; repair potentially trashed register
.JmpIn:
	jcxz .SkipEnt		; skip any 0 length entries
	cmp cl, 20		; got a 24 byte ACPI 3.X response?
	jbe short .NoText
	test byte [es:di + 20], 1	; if so: is the "ignore this data" bit clear?
	je short .SkipEnt
.NoText:
	mov ecx, [es:di + 8]	; get lower uint32_t of memory region length
	or ecx, [es:di + 12]	; "or" it with upper uint32_t to test for zero
	jz .SkipEnt		; if length uint64_t is 0, skip entry
	inc bp			; got a good entry: ++count, move to next storage spot
	add di, 24
.SkipEnt:
	test ebx, ebx		; if ebx resets to 0, list is complete
	jne short .E820Lp
.E820F:
	mov [si], bp	; store the entry count
	clc			; there is "jc" on end of list to this point, so the carry must be cleared
    pop bp
	ret
.Failed:
	stc			; "function unsupported" error exit
	pop bp
	ret