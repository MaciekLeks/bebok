LoadSectors:
    mov rbx, rax ;back up LBA

    ; Send the highest 8 bits (24-31) of LBA to the controller
    mov rax, rbx ;restore LBA
    shr rax, 24
    or rax, 0xE0 ;select the master drive
    mov dx, 0x1f6 ;port 0x1f6 is the high 8 bits of LBA
    out dx, al
    ; Finished sending the highest 8 bitf of LBA

    ; Send the total number of sectors to read
    mov rax, rcx ;set total number of sectors
    mov dx, 0x1f2 ;port 0x1f2 is the number of sectors to read
    out dx, al
    ; Finished sending the total number of sectors to read

    ; Send more bits of LBA - the low 8 bits (0-7) of LBA
    mov rax, rbx ;restore LBA
    mov dx, 0x1f3 ;port 0x1f3 is the low 8 bits of LBA
    out dx, al
    ; Finished sending more bits of LBA

    ; more bits of LBA - the second lowest 8 bits (8-15) of LBA
    mov rax, rbx ;restore LBA - we do not need this but it's good to have it for the future
    mov dx, 0x1f4 ;port 0x1f4 is the next 8 bits of LBA
    shr eax, 8
    out dx, al
    ; Finished sending more bits of LBA

    ; Sending upper 16 bits (16-23) of LBA
    mov rax, rbx ;restore LBA
    mov dx, 0x1f5 ;port 0x1f5 is the next 8 bits of LBA
    shr rax, 16
    out dx, al
    ; Finished sending upper 16 bits of LBA


    ; Send the read command
    mov dx, 0x1f7 ;port 0x1f7 is the command port
    mov al, 0x20 ;command 0x20 is read sector with retry
    out dx, al ;send the command
    ; Finished sending the read command

.NextSector:
    push rcx ;save ecx, because we will use by rep insw

; checking if the drive is ready
.TryAgain:
    mov dx, 0x1f7 ;port 0x1f7 is the command port
    in al, dx ;read the status port
    test al, 0x08 ;check if the drive is ready
    jz .TryAgain ;if not ready, try again

; We need to read 256 words (512 bytes) from the data port
    mov rcx, 128 ;128 double words
    mov dx, 0x1f0 ;port 0x1f0 is the data port
    rep insd ;read 256 words (taken out from ecx) from the data port (0x1f0) into the memory pointed to by es:edi
    pop rcx ;restore ecx
    loop .NextSector ;loop back to .next_sector (decrementing ecx) if ecx is not zero

    ; end of reading sectors
    ret
